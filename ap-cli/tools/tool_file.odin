package aptools

import platform "../../ap-core/platform"
import tool "../../ap-core/tool"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// 参考 pi 的 read/write/edit：read 按 offset/limit 分页并在行数或字节超限时给出续读提示，
// write 原样落盘，edit 一次性匹配全部 edits 并保留 BOM 与换行风格。
MAX_READ_LINES :: 2000
READ_MAX_BYTES :: 50 * 1024
IMAGE_SNIFF_BYTES :: 16
BOM_UTF8 :: "\xEF\xBB\xBF"

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
	res := tool.tool_ok(fmt.tprintf("Read image file [%s]", mime))
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

format_size :: proc(bytes: int) -> string {
	if bytes < 1024 {
		return fmt.tprintf("%dB", bytes)
	}
	if bytes < 1024 * 1024 {
		return fmt.tprintf("%.1fKB", f64(bytes) / 1024.0)
	}
	return fmt.tprintf("%.1fMB", f64(bytes) / (1024.0 * 1024.0))
}

// ---- read ----

Truncated_By :: enum {
	None,
	Lines,
	Bytes,
}

Read_State :: struct {
	lines:              [dynamic]string,
	total:              int,
	start_line:         int,
	user_limit:         int,
	max_lines:          int,
	max_bytes:          int,
	output_bytes:       int,
	truncated_by:       Truncated_By,
	first_line_exceeds: bool,
	first_line_bytes:   int,
	last_terminated:    bool,
	stopped:            bool,
}

consume_read_line :: proc(line_bytes: []byte, terminated: bool, st: ^Read_State, line_cap: int) -> platform.Error {
	line := line_bytes
	if len(line) > 0 && line[len(line) - 1] == '\r' {
		line = line[:len(line) - 1]
	}
	if len(line) > line_cap {
		return platform.errorf("single line exceeds max_capture_bytes (%d)", line_cap)
	}
	if has_nul(line) {
		return platform.errorf("file appears to be binary (contains NUL); use bash instead")
	}
	if !utf8.valid_string(string(line)) {
		return platform.errorf("file is not valid UTF-8; use bash instead")
	}
	st.total += 1
	if st.total < st.start_line || st.stopped {
		return platform.ok_error()
	}

	index := st.total - st.start_line
	// 用户显式 limit 先于行/字节上限生效：超出 limit 的行只计数，不算截断。
	if st.user_limit > 0 && index >= st.user_limit {
		st.stopped = true
		return platform.ok_error()
	}
	if index == 0 && len(line) > st.max_bytes {
		st.first_line_exceeds = true
		st.first_line_bytes = len(line)
		st.stopped = true
		return platform.ok_error()
	}
	if len(st.lines) >= st.max_lines {
		st.truncated_by = .Lines
		st.stopped = true
		return platform.ok_error()
	}
	line_bytes_len := len(line)
	if len(st.lines) > 0 {
		line_bytes_len += 1 // 行间分隔符计入上限，join 后不会多出尾随换行
	}
	if st.output_bytes + line_bytes_len > st.max_bytes {
		st.truncated_by = .Bytes
		st.stopped = true
		return platform.ok_error()
	}
	// pending 缓冲会被反复压缩，必须复制。
	append(&st.lines, strings.clone(string(line), context.allocator))
	st.last_terminated = terminated
	st.output_bytes += line_bytes_len
	return platform.ok_error()
}

scan_read_file :: proc(
	path: string,
	start_line, user_limit, max_lines, max_bytes, line_cap: int,
) -> (Read_State, platform.Error) {
	st := Read_State {
		start_line = start_line,
		user_limit = user_limit,
		max_lines  = max_lines,
		max_bytes  = max_bytes,
	}

	file, ferr := os.open(path)
	if ferr != nil {
		return st, platform.errorf("cannot open %s: %v", path, ferr)
	}
	defer os.close(file)

	pending := make([dynamic]byte, 0, 8192)
	defer delete(pending)
	read_buf: [65536]byte

	for {
		n, rerr := os.read(file, read_buf[:])
		if n > 0 {
			append(&pending, ..read_buf[:n])
		}
		if rerr != nil {
			if rerr != .EOF {
				return st, platform.errorf("cannot read %s: %v", path, rerr)
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
				if len(pending) > line_cap {
					return st, platform.errorf("line exceeds max_capture_bytes (%d)", line_cap)
				}
				break
			}
			err := consume_read_line(pending[:nl], true, &st, line_cap)
			if !platform.is_ok(err) {
				return st, err
			}
			remaining := pending[nl + 1:]
			copy(pending[:], remaining)
			resize(&pending, len(pending) - (nl + 1))
		}
	}

	if len(pending) > 0 {
		err := consume_read_line(pending[:], false, &st, line_cap)
		if !platform.is_ok(err) {
			return st, err
		}
	}
	return st, platform.ok_error()
}

read_file_text :: proc(path: string, offset, limit, max_capture: int) -> (string, platform.Error) {
	max_bytes := READ_MAX_BYTES
	if max_capture < max_bytes {
		max_bytes = max_capture
	}
	st, serr := scan_read_file(path, offset, limit, MAX_READ_LINES, max_bytes, max_capture)
	if !platform.is_ok(serr) {
		return "", serr
	}
	if offset > st.total && offset > 1 {
		return "", platform.errorf("Offset %d is beyond end of file (%d lines total)", offset, st.total)
	}

	b := strings.builder_make()
	if st.first_line_exceeds {
		fmt.sbprintf(
			&b,
			"[Line %d is %s, exceeds %s limit. Use bash: sed -n '%dp' %s | head -c %d]",
			offset,
			format_size(st.first_line_bytes),
			format_size(max_bytes),
			offset,
			path,
			max_bytes,
		)
		return strings.to_string(b), platform.ok_error()
	}

	strings.write_string(&b, strings.join(st.lines[:], "\n"))
	if st.truncated_by != .None {
		end_line := offset + len(st.lines) - 1
		next_offset := end_line + 1
		if st.truncated_by == .Lines {
			fmt.sbprintf(
				&b,
				"\n\n[Showing lines %d-%d of %d. Use offset=%d to continue.]",
				offset,
				end_line,
				st.total,
				next_offset,
			)
		} else {
			fmt.sbprintf(
				&b,
				"\n\n[Showing lines %d-%d of %d (%s limit). Use offset=%d to continue.]",
				offset,
				end_line,
				st.total,
				format_size(max_bytes),
				next_offset,
			)
		}
	} else if st.user_limit > 0 && offset - 1 + len(st.lines) < st.total {
		remaining := st.total - (offset - 1 + len(st.lines))
		next_offset := offset + len(st.lines)
		fmt.sbprintf(&b, "\n\n[%d more lines in file. Use offset=%d to continue.]", remaining, next_offset)
	} else if st.last_terminated {
		// 未截断时按原文件保留末尾换行。
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b), platform.ok_error()
}

tool_read_file :: proc(args: json.Object, cfg: ^Tool_Config, ctx: ^tool.Tool_Context) -> tool.Tool_Result {
	raw_path, perr := tool.tool_arg_string(args, "file_path")
	if !platform.is_ok(perr) {
		return arg_error(perr)
	}
	offset := 1
	if value, err := tool.tool_arg_optional_int(args, "offset"); !platform.is_ok(err) {
		return arg_error(err)
	} else if v, ok := value.?; ok {
		offset = v
	}
	limit := 0
	if value, err := tool.tool_arg_optional_int(args, "limit"); !platform.is_ok(err) {
		return arg_error(err)
	} else if v, ok := value.?; ok {
		limit = v
	}
	if offset < 1 {
		return tool.tool_fail("offset must be >= 1")
	}
	if limit < 0 {
		return tool.tool_fail("limit must be >= 1")
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

	text, lerr := read_file_text(resolved, offset, limit, cfg.max_capture_bytes)
	if !platform.is_ok(lerr) {
		return arg_error(lerr)
	}
	return tool.tool_ok(text)
}

// ---- write ----

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

atomic_write_text :: proc(path, content: string) -> platform.Error {
	data: []byte = transmute([]byte)content
	dir := os.dir(path)
	if len(dir) == 0 {
		dir = "."
	}
	if !os.is_dir(dir) {
		if mkerr := os.make_directory_all(dir); mkerr != nil {
			return platform.errorf("cannot create parent directory %s: %v", dir, mkerr)
		}
	}
	old_mode: os.Permissions
	has_old := false
	if info, serr := os.stat(path, context.allocator); serr == nil {
		defer os.file_info_delete(info, context.allocator)
		if info.type == .Directory {
			return platform.errorf("path is a directory: %s", path)
		}
		old_mode = info.mode
		has_old = true
	}

	tmp := fmt.tprintf("%s/.ap-tmp-%d-%d", dir, os.get_pid(), time.time_to_unix_nano(time.now()))
	perm := os.Permissions_Default_File
	file, ferr := os.open(tmp, {.Write, .Create, .Excl, .Trunc}, perm)
	if ferr != nil {
		return platform.errorf("cannot create temporary file in %s: %v", dir, ferr)
	}
	ok_write := platform.write_all(file, data)
	sync_err := os.sync(file)
	close_err := os.close(file)
	if !ok_write || sync_err != nil || close_err != nil {
		os.remove(tmp)
		return platform.errorf("cannot write temporary file for %s", path)
	}
	if has_old {
		os.change_mode(tmp, old_mode)
	}
	if rerr := os.rename(tmp, path); rerr != nil {
		os.remove(tmp)
		return platform.errorf("cannot replace %s: %v", path, rerr)
	}
	return platform.ok_error()
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
	if werr := atomic_write_text(resolved, content); !platform.is_ok(werr) {
		return arg_error(werr)
	}
	return tool.tool_ok(fmt.tprintf("Successfully wrote to %s", raw_path))
}
