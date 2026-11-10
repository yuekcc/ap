package aptools

import platform "../../ap-core/platform"
import tool "../../ap-core/tool"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

MAX_READ_LINES :: 2000
DEFAULT_READ_LINES :: 500
IMAGE_SNIFF_BYTES :: 16

// 只接受主流视觉模型都支持的四类格式。SVG 仍是文本，不在这里处理。
image_mime_type :: proc(prefix: []byte) -> string {
	if len(prefix) >= 8 &&
	   prefix[0] == 0x89 &&
	   prefix[1] == 'P' &&
	   prefix[2] == 'N' &&
	   prefix[3] == 'G' &&
	   prefix[4] == 0x0d &&
	   prefix[5] == 0x0a &&
	   prefix[6] == 0x1a &&
	   prefix[7] == 0x0a {
		return "image/png"
	}
	if len(prefix) >= 3 && prefix[0] == 0xff && prefix[1] == 0xd8 && prefix[2] == 0xff {
		return "image/jpeg"
	}
	if len(prefix) >= 6 &&
	   string(prefix[0:3]) == "GIF" &&
	   (string(prefix[3:6]) == "87a" || string(prefix[3:6]) == "89a") {
		return "image/gif"
	}
	if len(prefix) >= 12 && string(prefix[0:4]) == "RIFF" && string(prefix[8:12]) == "WEBP" {
		return "image/webp"
	}
	return ""
}

read_image_mime :: proc(path: string) -> string {
	file, ferr := os.open(path)
	if ferr != nil {
		return ""
	}
	defer os.close(file)
	buf: [IMAGE_SNIFF_BYTES]byte
	n, rerr := os.read(file, buf[:])
	if rerr != nil && rerr != .EOF {
		return ""
	}
	return image_mime_type(buf[:n])
}

read_image_file :: proc(resolved: string, mime: string, cfg: ^Tool_Config, size: i64) -> tool.Tool_Result {
	if !cfg.image_input {
		return tool.tool_fail(
			fmt.tprintf(
				"%s is an image (%s); set image_input=true in settings to read images",
				resolved,
				mime,
			),
		)
	}
	if size > i64(cfg.image_max_bytes) {
		return tool.tool_fail(
			fmt.tprintf(
				"image exceeds image_max_bytes (%d > %d); downscale it first",
				size,
				cfg.image_max_bytes,
			),
		)
	}
	data, derr := os.read_entire_file_from_path(resolved, context.allocator)
	if derr != nil {
		return tool.tool_fail(fmt.tprintf("cannot read %s: %v", resolved, derr))
	}
	if len(data) > cfg.image_max_bytes {
		delete(data)
		return tool.tool_fail(
			fmt.tprintf(
				"image exceeds image_max_bytes (%d > %d); downscale it first",
				len(data),
				cfg.image_max_bytes,
			),
		)
	}
	if len(data) == 0 {
		delete(data)
		return tool.tool_fail(fmt.tprintf("empty image file: %s", resolved))
	}
	images := make([]tool.Tool_Image, 1)
	images[0] = {name = resolved, mime_type = mime, data = data}
	res := tool.tool_ok(fmt.tprintf("[image %s, %s, %d bytes]", resolved, mime, len(data)))
	res.images = images
	return res
}

has_nul :: proc(data: []byte) -> bool {
	for b in data {
		if b == 0 {
			return true
		}
	}
	return false
}

read_file_stream :: proc(path: string, start_line, end_line, max_capture: int) -> ([]string, int, platform.Error) {
	file, ferr := os.open(path)
	if ferr != nil {
		return nil, 0, platform.errorf("cannot open %s: %v", path, ferr)
	}
	defer os.close(file)

	pending := make([dynamic]byte, 0, 8192)
	defer delete(pending)
	lines := make([dynamic]string, 0, end_line - start_line + 1)
	line_number := 0
	output_bytes := 0
	read_buf: [65536]byte

	consume_line :: proc(
		line_bytes: []byte,
		line_number: ^int,
		start_line, end_line, max_capture: int,
		output_bytes: ^int,
		lines: ^[dynamic]string,
	) -> platform.Error {
		line := line_bytes
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		if len(line) > max_capture {
			return platform.errorf("single line exceeds max_capture_bytes (%d)", max_capture)
		}
		if has_nul(line) {
			return platform.errorf("file appears to be binary (contains NUL); use bash instead")
		}
		if !utf8.valid_string(string(line)) {
			return platform.errorf("file is not valid UTF-8; use bash instead")
		}
		line_number^ += 1
		if line_number^ >= start_line && line_number^ <= end_line {
			// 行号前缀让模型可以直接引用行，也方便 edit_file 定位；计入输出上限。
			numbered := fmt.aprintf("%d\t%s", line_number^, string(line))
			output_bytes^ += len(numbered) + 1
			if output_bytes^ > max_capture {
				return platform.errorf("read_file output exceeds max_capture_bytes (%d); request a smaller range", max_capture)
			}
			append(lines, numbered)
		}
		return platform.ok_error()
	}

	for {
		n, rerr := os.read(file, read_buf[:])
		if n > 0 {
			append(&pending, ..read_buf[:n])
		}
		if rerr != nil {
			if rerr != .EOF {
				return nil, 0, platform.errorf("cannot read %s: %v", path, rerr)
			}
			break
		}
		if n == 0 {
			break
		}
		for {
			nl := -1
			for i in 0 ..< len(pending) {
				if pending[i] == '\n' {
					nl = i
					break
				}
			}
			if nl < 0 {
				if len(pending) > max_capture {
					return nil, 0, platform.errorf("line exceeds max_capture_bytes (%d)", max_capture)
				}
				break
			}
			line := pending[:nl]
			err := consume_line(
				line,
				&line_number,
				start_line,
				end_line,
				max_capture,
				&output_bytes,
				&lines,
			)
			if !platform.is_ok(err) {
				return nil, 0, err
			}
			remaining := pending[nl + 1:]
			copy(pending[:], remaining)
			resize(&pending, len(pending) - (nl + 1))
		}
	}

	if len(pending) > 0 {
		err := consume_line(
			pending[:],
			&line_number,
			start_line,
			end_line,
			max_capture,
			&output_bytes,
			&lines,
		)
		if !platform.is_ok(err) {
			return nil, 0, err
		}
	}
	return lines[:], line_number, platform.ok_error()
}

tool_read_file :: proc(args: json.Object, cfg: ^Tool_Config, ctx: ^tool.Tool_Context) -> tool.Tool_Result {
	raw_path, perr := tool.tool_arg_string(args, "file_path")
	if !platform.is_ok(perr) {
		return arg_error(perr)
	}
	start_line := 1
	end_line := 0
	if value, err := tool.tool_arg_optional_int(args, "start_line"); !platform.is_ok(err) {
		return arg_error(err)
	} else if v, ok := value.?; ok {
		start_line = v
	}
	if value, err := tool.tool_arg_optional_int(args, "end_line"); !platform.is_ok(err) {
		return arg_error(err)
	} else if v, ok := value.?; ok {
		end_line = v
	}
	if start_line < 1 {
		return tool.tool_fail("start_line must be >= 1")
	}
	if end_line == 0 {
		end_line = start_line + DEFAULT_READ_LINES - 1
	}
	if end_line < start_line {
		return tool.tool_fail("end_line must be >= start_line")
	}
	truncated := false
	if end_line - start_line + 1 > MAX_READ_LINES {
		end_line = start_line + MAX_READ_LINES - 1
		truncated = true
	}

	resolved, rerr := platform.resolve_tool_path(ctx.cwd, raw_path)
	if !platform.is_ok(rerr) {
		return arg_error(rerr)
	}
	info, serr := os.stat(resolved, context.allocator)
	if serr != nil {
		return tool.tool_fail(fmt.tprintf("cannot stat %s: %v", resolved, serr))
	}
	defer os.file_info_delete(info, context.allocator)
	if info.type == .Directory {
		return tool.tool_fail(fmt.tprintf("not a file (directory): %s", resolved))
	}
	if info.type != .Regular {
		return tool.tool_fail(fmt.tprintf("not a regular file: %s", resolved))
	}

	mime := read_image_mime(resolved)
	if len(mime) > 0 {
		return read_image_file(resolved, mime, cfg, info.size)
	}

	lines, total, lerr := read_file_stream(resolved, start_line, end_line, cfg.max_capture_bytes)
	if !platform.is_ok(lerr) {
		return arg_error(lerr)
	}
	last := end_line
	if total < last {
		last = total
	}
	if start_line > total {
		last = start_line - 1
	}

	b := strings.builder_make()
	fmt.sbprintf(&b, "[%s lines %d-%d of %d]", resolved, start_line, last, total)
	if len(lines) > 0 {
		strings.write_byte(&b, '\n')
		strings.write_string(&b, strings.join(lines[:], "\n"))
	}
	if truncated {
		fmt.sbprintf(&b, "\n[请求跨度超过 %d 行，已截断到 %d 行]", MAX_READ_LINES, MAX_READ_LINES)
	}
	if last < total {
		fmt.sbprintf(&b, "\n[共 %d 行，已返回 %d-%d；继续请用 start_line=%d]", total, start_line, last, last + 1)
	}
	return tool.tool_ok(strings.to_string(b))
}

normalize_crlf :: proc(content: string) -> string {
	result, _ := strings.replace_all(content, "\r\n", "\n", context.allocator)
	return result
}

count_text_lines :: proc(text: string) -> int {
	if len(text) == 0 {
		return 0
	}
	count := 0
	for ch in text {
		if ch == '\n' {
			count += 1
		}
	}
	if text[len(text) - 1] != '\n' {
		count += 1
	}
	return count
}

atomic_write_text :: proc(path, content: string) -> (written: int, lines: int, err: platform.Error) {
	data: []byte = transmute([]byte)content
	dir := os.dir(path)
	if len(dir) == 0 {
		dir = "."
	}
	if !os.is_dir(dir) {
		if mkerr := os.make_directory_all(dir); mkerr != nil {
			return 0, 0, platform.errorf("cannot create parent directory %s: %v", dir, mkerr)
		}
	}
	old_mode: os.Permissions
	has_old := false
	if info, serr := os.stat(path, context.allocator); serr == nil {
		defer os.file_info_delete(info, context.allocator)
		if info.type == .Directory {
			return 0, 0, platform.errorf("path is a directory: %s", path)
		}
		old_mode = info.mode
		has_old = true
	}

	tmp := fmt.tprintf("%s/.ap-tmp-%d-%d", dir, os.get_pid(), time.time_to_unix_nano(time.now()))
	perm := os.Permissions_Default_File
	file, ferr := os.open(tmp, {.Write, .Create, .Excl, .Trunc}, perm)
	if ferr != nil {
		return 0, 0, platform.errorf("cannot create temporary file in %s: %v", dir, ferr)
	}
	ok_write := platform.write_all(file, data)
	sync_err := os.sync(file)
	close_err := os.close(file)
	if !ok_write || sync_err != nil || close_err != nil {
		os.remove(tmp)
		return 0, 0, platform.errorf("cannot write temporary file for %s", path)
	}
	if has_old {
		os.change_mode(tmp, old_mode)
	}
	if rerr := os.rename(tmp, path); rerr != nil {
		os.remove(tmp)
		return 0, 0, platform.errorf("cannot replace %s: %v", path, rerr)
	}
	return len(data), count_text_lines(content), platform.ok_error()
}

tool_write_file :: proc(args: json.Object, cfg: ^Tool_Config, ctx: ^tool.Tool_Context) -> tool.Tool_Result {
	raw_path, perr := tool.tool_arg_string(args, "file_path")
	if !platform.is_ok(perr) {
		return arg_error(perr)
	}
	content, cerr := tool.tool_arg_string(args, "content")
	if !platform.is_ok(cerr) {
		return arg_error(cerr)
	}
	if len(content) > cfg.max_capture_bytes {
		return tool.tool_fail(fmt.tprintf("content exceeds max_capture_bytes (%d)", cfg.max_capture_bytes))
	}
	resolved, rerr := platform.resolve_tool_path(ctx.cwd, raw_path)
	if !platform.is_ok(rerr) {
		return arg_error(rerr)
	}
	normalized := normalize_crlf(content)
	written, lines, werr := atomic_write_text(resolved, normalized)
	if !platform.is_ok(werr) {
		return arg_error(werr)
	}
	return tool.tool_ok(fmt.tprintf("wrote %d bytes (%d lines) to %s", written, lines, resolved))
}

tool_edit_file :: proc(args: json.Object, cfg: ^Tool_Config, ctx: ^tool.Tool_Context) -> tool.Tool_Result {
	raw_path, perr := tool.tool_arg_string(args, "file_path")
	if !platform.is_ok(perr) {
		return arg_error(perr)
	}
	old_string, oerr := tool.tool_arg_string(args, "old_string")
	if !platform.is_ok(oerr) {
		return arg_error(oerr)
	}
	new_string, nerr := tool.tool_arg_string(args, "new_string")
	if !platform.is_ok(nerr) {
		return arg_error(nerr)
	}
	replace_all := false
	if value, err := tool.tool_arg_optional_bool(args, "replace_all"); !platform.is_ok(err) {
		return arg_error(err)
	} else if v, ok := value.?; ok {
		replace_all = v
	}
	if len(old_string) == 0 {
		return tool.tool_fail("old_string must not be empty")
	}
	resolved, rerr := platform.resolve_tool_path(ctx.cwd, raw_path)
	if !platform.is_ok(rerr) {
		return arg_error(rerr)
	}
	info, serr := os.stat(resolved, context.allocator)
	if serr != nil {
		return tool.tool_fail(fmt.tprintf("cannot stat %s: %v", resolved, serr))
	}
	defer os.file_info_delete(info, context.allocator)
	if info.type == .Directory {
		return tool.tool_fail(fmt.tprintf("not a file (directory): %s", resolved))
	}
	if info.size > i64(cfg.max_capture_bytes) {
		return tool.tool_fail("file is larger than max_capture_bytes; edit it with bash instead")
	}
	data, derr := os.read_entire_file_from_path(resolved, context.allocator)
	if derr != nil {
		return tool.tool_fail(fmt.tprintf("cannot read %s: %v", resolved, derr))
	}
	if !platform.valid_utf8(data) {
		return tool.tool_fail("file is not valid UTF-8; use bash instead")
	}
	text := normalize_crlf(string(data))
	matches := strings.count(text, old_string)
	if matches == 0 {
		return tool.tool_fail("old_string not found; use read_file to confirm the file contents")
	}
	if matches > 1 && !replace_all {
		return tool.tool_fail(
			fmt.tprintf("old_string matched %d times; add more context or set replace_all=true", matches),
		)
	}
	replace_count := 1
	if replace_all {
		replace_count = -1
	}
	replaced, _ := strings.replace(text, old_string, new_string, replace_count, context.allocator)
	if replaced == text {
		return tool.tool_fail("replacement produced no change")
	}
	_, lines, werr := atomic_write_text(resolved, replaced)
	if !platform.is_ok(werr) {
		return arg_error(werr)
	}
	actual := matches if replace_all else 1
	return tool.tool_ok(fmt.tprintf("replaced %d occurrence(s) in %s (%d lines)", actual, resolved, lines))
}
