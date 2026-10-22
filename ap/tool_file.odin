package ap

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

MAX_READ_LINES :: 2000
DEFAULT_READ_LINES :: 500

has_nul :: proc(data: []byte) -> bool {
	for b in data {
		if b == 0 {
			return true
		}
	}
	return false
}

read_file_stream :: proc(path: string, start_line, end_line, max_capture: int) -> ([]string, int, Error) {
	file, ferr := os.open(path)
	if ferr != nil {
		return nil, 0, make_error(.Tool, "cannot open %s: %v", path, ferr)
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
	) -> Error {
		line := line_bytes
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		if len(line) > max_capture {
			return make_error(.Tool, "single line exceeds max_capture_bytes (%d)", max_capture)
		}
		if has_nul(line) {
			return make_error(.Tool, "file appears to be binary (contains NUL); use bash instead")
		}
		if !utf8.valid_string(string(line)) {
			return make_error(.Tool, "file is not valid UTF-8; use bash instead")
		}
		line_number^ += 1
		if line_number^ >= start_line && line_number^ <= end_line {
			output_bytes^ += len(line) + 1
			if output_bytes^ > max_capture {
				return make_error(.Tool, "read_file output exceeds max_capture_bytes (%d); request a smaller range", max_capture)
			}
			append(lines, strings.clone(string(line)))
		}
		return ok_error()
	}

	for {
		n, rerr := os.read(file, read_buf[:])
		if n > 0 {
			append(&pending, ..read_buf[:n])
		}
		if rerr != nil {
			if rerr != .EOF {
				return nil, 0, make_error(.Tool, "cannot read %s: %v", path, rerr)
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
					return nil, 0, make_error(.Tool, "line exceeds max_capture_bytes (%d)", max_capture)
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
			if !is_ok(err) {
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
		if !is_ok(err) {
			return nil, 0, err
		}
	}
	return lines[:], line_number, ok_error()
}

tool_read_file :: proc(args: json.Object, ctx: ^Tool_Context) -> Tool_Result {
	raw_path, perr := tool_arg_string(args, "file_path")
	if !is_ok(perr) {
		return arg_error(perr)
	}
	start_line := 1
	end_line := 0
	if value, err := tool_arg_optional_int(args, "start_line"); !is_ok(err) {
		return arg_error(err)
	} else if v, ok := value.?; ok {
		start_line = v
	}
	if value, err := tool_arg_optional_int(args, "end_line"); !is_ok(err) {
		return arg_error(err)
	} else if v, ok := value.?; ok {
		end_line = v
	}
	if start_line < 1 {
		return tool_fail("start_line must be >= 1")
	}
	if end_line == 0 {
		end_line = start_line + DEFAULT_READ_LINES - 1
	}
	if end_line < start_line {
		return tool_fail("end_line must be >= start_line")
	}
	truncated := false
	if end_line - start_line + 1 > MAX_READ_LINES {
		end_line = start_line + MAX_READ_LINES - 1
		truncated = true
	}

	resolved, rerr := resolve_tool_path(ctx.cwd, raw_path)
	if !is_ok(rerr) {
		return arg_error(rerr)
	}
	info, serr := os.stat(resolved, context.allocator)
	if serr != nil {
		return tool_fail(fmt.tprintf("cannot stat %s: %v", resolved, serr))
	}
	defer os.file_info_delete(info, context.allocator)
	if info.type == .Directory {
		return tool_fail(fmt.tprintf("not a file (directory): %s", resolved))
	}
	if info.type != .Regular {
		return tool_fail(fmt.tprintf("not a regular file: %s", resolved))
	}

	lines, total, lerr := read_file_stream(resolved, start_line, end_line, ctx.settings.max_capture_bytes)
	if !is_ok(lerr) {
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
	return tool_ok(strings.to_string(b))
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

atomic_write_text :: proc(path, content: string) -> (written: int, lines: int, err: Error) {
	data: []byte = transmute([]byte)content
	dir := os.dir(path)
	if len(dir) == 0 {
		dir = "."
	}
	if !os.is_dir(dir) {
		if mkerr := os.make_directory_all(dir); mkerr != nil {
			return 0, 0, make_error(.Tool, "cannot create parent directory %s: %v", dir, mkerr)
		}
	}
	old_mode: os.Permissions
	has_old := false
	if info, serr := os.stat(path, context.allocator); serr == nil {
		defer os.file_info_delete(info, context.allocator)
		if info.type == .Directory {
			return 0, 0, make_error(.Tool, "path is a directory: %s", path)
		}
		old_mode = info.mode
		has_old = true
	}

	tmp := fmt.tprintf("%s/.ap-tmp-%d-%d", dir, os.get_pid(), time.time_to_unix_nano(time.now()))
	perm := os.Permissions_Default_File
	file, ferr := os.open(tmp, {.Write, .Create, .Excl, .Trunc}, perm)
	if ferr != nil {
		return 0, 0, make_error(.Tool, "cannot create temporary file in %s: %v", dir, ferr)
	}
	ok_write := write_all_file(file, data)
	sync_err := os.sync(file)
	close_err := os.close(file)
	if !ok_write || sync_err != nil || close_err != nil {
		os.remove(tmp)
		return 0, 0, make_error(.Tool, "cannot write temporary file for %s", path)
	}
	if has_old {
		os.change_mode(tmp, old_mode)
	}
	if rerr := os.rename(tmp, path); rerr != nil {
		os.remove(tmp)
		return 0, 0, make_error(.Tool, "cannot replace %s: %v", path, rerr)
	}
	return len(data), count_text_lines(content), ok_error()
}

tool_write_file :: proc(args: json.Object, ctx: ^Tool_Context) -> Tool_Result {
	raw_path, perr := tool_arg_string(args, "file_path")
	if !is_ok(perr) {
		return arg_error(perr)
	}
	content, cerr := tool_arg_string(args, "content")
	if !is_ok(cerr) {
		return arg_error(cerr)
	}
	if len(content) > ctx.settings.max_capture_bytes {
		return tool_fail(fmt.tprintf("content exceeds max_capture_bytes (%d)", ctx.settings.max_capture_bytes))
	}
	resolved, rerr := resolve_tool_path(ctx.cwd, raw_path)
	if !is_ok(rerr) {
		return arg_error(rerr)
	}
	normalized := normalize_crlf(content)
	written, lines, werr := atomic_write_text(resolved, normalized)
	if !is_ok(werr) {
		return arg_error(werr)
	}
	return tool_ok(fmt.tprintf("wrote %d bytes (%d lines) to %s", written, lines, resolved))
}

tool_edit_file :: proc(args: json.Object, ctx: ^Tool_Context) -> Tool_Result {
	raw_path, perr := tool_arg_string(args, "file_path")
	if !is_ok(perr) {
		return arg_error(perr)
	}
	old_string, oerr := tool_arg_string(args, "old_string")
	if !is_ok(oerr) {
		return arg_error(oerr)
	}
	new_string, nerr := tool_arg_string(args, "new_string")
	if !is_ok(nerr) {
		return arg_error(nerr)
	}
	replace_all := false
	if value, err := tool_arg_optional_bool(args, "replace_all"); !is_ok(err) {
		return arg_error(err)
	} else if v, ok := value.?; ok {
		replace_all = v
	}
	if len(old_string) == 0 {
		return tool_fail("old_string must not be empty")
	}
	resolved, rerr := resolve_tool_path(ctx.cwd, raw_path)
	if !is_ok(rerr) {
		return arg_error(rerr)
	}
	info, serr := os.stat(resolved, context.allocator)
	if serr != nil {
		return tool_fail(fmt.tprintf("cannot stat %s: %v", resolved, serr))
	}
	defer os.file_info_delete(info, context.allocator)
	if info.type == .Directory {
		return tool_fail(fmt.tprintf("not a file (directory): %s", resolved))
	}
	if info.size > i64(ctx.settings.max_capture_bytes) {
		return tool_fail("file is larger than max_capture_bytes; edit it with bash instead")
	}
	data, derr := os.read_entire_file_from_path(resolved, context.allocator)
	if derr != nil {
		return tool_fail(fmt.tprintf("cannot read %s: %v", resolved, derr))
	}
	if !valid_utf8(data) {
		return tool_fail("file is not valid UTF-8; use bash instead")
	}
	text := normalize_crlf(string(data))
	matches := strings.count(text, old_string)
	if matches == 0 {
		return tool_fail("old_string not found; use read_file to confirm the file contents")
	}
	if matches > 1 && !replace_all {
		return tool_fail(
			fmt.tprintf("old_string matched %d times; add more context or set replace_all=true", matches),
		)
	}
	replace_count := 1
	if replace_all {
		replace_count = -1
	}
	replaced, _ := strings.replace(text, old_string, new_string, replace_count, context.allocator)
	if replaced == text {
		return tool_fail("replacement produced no change")
	}
	_, lines, werr := atomic_write_text(resolved, replaced)
	if !is_ok(werr) {
		return arg_error(werr)
	}
	actual := matches if replace_all else 1
	return tool_ok(fmt.tprintf("replaced %d occurrence(s) in %s (%d lines)", actual, resolved, lines))
}
