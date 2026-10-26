package tui

import "../internal"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

MAX_STDERR_BYTES :: 64 * 1024

Line_Reader :: struct {
	buf:      [dynamic]u8,
	start:    int,
	callback: proc(user: rawptr, line: string),
	user:     rawptr,
}

line_reader_feed :: proc(lr: ^Line_Reader, chunk: []byte) {
	if len(chunk) > 0 {
		append(&lr.buf, ..chunk)
	}
	for {
		view := transmute(string)lr.buf[lr.start:]
		idx := strings.index_byte(view, '\n')
		if idx < 0 {
			break
		}
		line := view[:idx]
		lr.callback(lr.user, line)
		lr.start += idx + 1
	}
	if lr.start > 0 {
		remaining := len(lr.buf) - lr.start
		if remaining > 0 {
			copy(lr.buf[:], lr.buf[lr.start:])
		}
		resize(&lr.buf, remaining)
		lr.start = 0
	}
}

line_reader_flush :: proc(lr: ^Line_Reader) {
	if lr.start < len(lr.buf) {
		lr.callback(lr.user, transmute(string)lr.buf[lr.start:])
	}
	resize(&lr.buf, 0)
	lr.start = 0
}

read_stream :: proc(file: ^os.File, buf: []byte) -> (data: []byte, done: bool) {
	has, herr := os.pipe_has_data(file)
	if herr != nil {
		return nil, true
	}
	if !has {
		return nil, false
	}
	n, rerr := os.read(file, buf)
	if rerr == os.General_Error.Broken_Pipe {
		return nil, true
	}
	if rerr != nil {
		return nil, true
	}
	if n <= 0 {
		return nil, true
	}
	return buf[:n], false
}

write_all :: proc(file: ^os.File, data: []byte) -> bool {
	return internal.write_all(file, data)
}

resolve_self_exe :: proc() -> string {
	return internal.resolve_self_exe()
}

// 目录 ap/ 与 Unix 二进制 ap 同名；查找 agent 时必须排除目录。
is_regular_file :: proc(path: string) -> bool {
	info, err := os.stat(path, context.temp_allocator)
	return err == nil && info.type == .Regular
}

find_in_path :: proc(name: string) -> string {
	when ODIN_OS == .Windows {
		separator := ";"
		exts := []string{"", ".exe"}
	} else {
		separator := ":"
		exts := []string{""}
	}
	path_env := os.get_env("PATH", context.allocator)
	if len(path_env) == 0 {
		return ""
	}
	dirs, _ := strings.split(path_env, separator, context.temp_allocator)
	for dir in dirs {
		if len(dir) == 0 {
			continue
		}
		for ext in exts {
			candidate := fmt.tprintf("%s/%s%s", strings.trim_right(dir, `\/`), name, ext)
			if is_regular_file(candidate) {
				return strings.clone(candidate, context.allocator)
			}
		}
	}
	return ""
}

resolve_agent_bin :: proc(configured: Maybe(string)) -> (string, Error) {
	if value, ok := configured.?; ok {
		if os.is_absolute_path(value) || strings.contains_rune(value, '/') || strings.contains_rune(value, '\\') {
			path, err := canonicalize_path(value, false)
			if is_ok(err) && is_regular_file(path) {
				return path, ok_error()
			}
			return "", errorf("agent binary not found: %s", value)
		}
		if found := find_in_path(value); len(found) > 0 {
			return found, ok_error()
		}
		return "", errorf("agent binary not found in PATH: %s", value)
	}

	for env_name in ([2]string{"AP_AGENT_BIN", "AP_BIN"}) {
		if value := os.get_env(env_name, context.allocator); len(value) > 0 {
			return resolve_agent_bin(value)
		}
	}

	exe := resolve_self_exe()
	dir, _ := os.split_path(exe)
	names := []string{"ap.exe"} when ODIN_OS == .Windows else []string{"ap"}
	for name in names {
		joined, _ := os.join_path([]string{dir, name}, context.allocator)
		if is_regular_file(joined) {
			return joined, ok_error()
		}
	}
	for name in names {
		if found := find_in_path(name); len(found) > 0 {
			return found, ok_error()
		}
	}
	return "", errorf("cannot find ap.exe next to ap-tui or in PATH; use --agent-bin")
}

build_agent_command :: proc(app: ^App) -> [dynamic]string {
	cmd := make([dynamic]string, 0, 16, context.allocator)
	append(&cmd, app.agent_bin)
	append(&cmd, "--print0")
	append(&cmd, "--output-format", "stream-json")
	if len(app.session_id) > 0 {
		append(&cmd, "-s", app.session_id)
	}
	if value, ok := app.options.model.?; ok {
		append(&cmd, "--model", value)
	}
	if value, ok := app.options.agent.?; ok {
		append(&cmd, "--agent", value)
	}
	if value, ok := app.options.max_steps.?; ok {
		append(&cmd, "--max-steps", fmt.tprintf("%d", value))
	}
	if value, ok := app.options.max_tokens.?; ok {
		append(&cmd, "--max-tokens", fmt.tprintf("%d", value))
	}
	append(&cmd, "--config-dir", app.project.config_dir)
	if app.options.verbose {
		append(&cmd, "--verbose")
	}
	return cmd
}

remember_session :: proc(app: ^App, session_id: string) {
	if len(session_id) == 0 {
		return
	}
	cloned := strings.clone(session_id, context.allocator)
	if len(app.session_id) > 0 {
		delete(app.session_id, context.allocator)
	}
	app.session_id = cloned
}

on_stdout_line :: proc(user: rawptr, line: string) {
	app := (^App)(user)
	ev, ok := parse_event_line(line)
	if !ok {
		free_all(context.temp_allocator)
		return
	}
	if ev.type == "session_start" && len(ev.session_id) > 0 {
		remember_session(app, ev.session_id)
	}
	render_event(&app.renderer, ev, .Live)
	free_all(context.temp_allocator)
}

append_stderr_line :: proc(app: ^App, line: string) {
	append(&app.stderr_log, ..transmute([]byte)line)
	append(&app.stderr_log, '\n')
	if len(app.stderr_log) > MAX_STDERR_BYTES {
		keep := MAX_STDERR_BYTES / 2
		start := len(app.stderr_log) - keep
		if idx := strings.index_byte(transmute(string)app.stderr_log[start:], '\n'); idx >= 0 {
			start += idx + 1
		}
		remaining := len(app.stderr_log) - start
		copy(app.stderr_log[:], app.stderr_log[start:])
		resize(&app.stderr_log, remaining)
	}
}

on_stderr_line :: proc(user: rawptr, line: string) {
	app := (^App)(user)
	if app.options.verbose {
		renderer_note(app, fmt.tprintf("[ap] %s", line))
	} else {
		append_stderr_line(app, line)
	}
	free_all(context.temp_allocator)
}

// 执行一个 turn：每轮都启动一个新的 ap 进程，stdout 读 stream-json，stderr 收集后按需展示。
run_agent_turn :: proc(app: ^App, prompt: string) -> int {
	had_session := len(app.session_id) > 0
	command := build_agent_command(app)
	defer delete(command)

	stdin_r, stdin_w, e1 := os.pipe()
	if e1 != nil {
		render_error(&app.renderer, "agent", fmt.tprintf("cannot create stdin pipe: %v", e1), false)
		return 1
	}
	stdout_r, stdout_w, e2 := os.pipe()
	if e2 != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		render_error(&app.renderer, "agent", fmt.tprintf("cannot create stdout pipe: %v", e2), false)
		return 1
	}
	stderr_r, stderr_w, e3 := os.pipe()
	if e3 != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		os.close(stdout_r)
		os.close(stdout_w)
		render_error(&app.renderer, "agent", fmt.tprintf("cannot create stderr pipe: %v", e3), false)
		return 1
	}

	desc := os.Process_Desc {
		working_dir = app.project.root,
		command = command[:],
		stdin = stdin_r,
		stdout = stdout_w,
		stderr = stderr_w,
	}
	mark_non_inheritable(stdin_w)
	mark_non_inheritable(stdout_r)
	mark_non_inheritable(stderr_r)
	process, perr := os.process_start(desc)
	if perr != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		os.close(stdout_r)
		os.close(stdout_w)
		os.close(stderr_r)
		os.close(stderr_w)
		render_error(&app.renderer, "agent", fmt.tprintf("cannot start %s: %v", app.agent_bin, perr), false)
		return 1
	}

	os.close(stdin_r)
	os.close(stdout_w)
	os.close(stderr_w)

	if !write_all(stdin_w, transmute([]byte)prompt) {
		render_error(&app.renderer, "agent", "cannot write prompt to agent stdin", false)
	}
	os.close(stdin_w)

	out_reader: Line_Reader
	out_reader.callback = on_stdout_line
	out_reader.user = app
	err_reader: Line_Reader
	err_reader.callback = on_stderr_line
	err_reader.user = app

	stdout_open := true
	stderr_open := true
	exited := false
	exit_code := -1
	read_buf: [65536]byte

	for {
		if stdout_open {
			data, done := read_stream(stdout_r, read_buf[:])
			if len(data) > 0 {
				line_reader_feed(&out_reader, data)
			}
			if done {
				os.close(stdout_r)
				stdout_open = false
			}
		}
		if stderr_open {
			data, done := read_stream(stderr_r, read_buf[:])
			if len(data) > 0 {
				line_reader_feed(&err_reader, data)
			}
			if done {
				os.close(stderr_r)
				stderr_open = false
			}
		}

		if !exited {
			state, werr := os.process_wait(process, 10 * time.Millisecond)
			if werr == nil && state.exited {
				exit_code = state.exit_code
				exited = true
			} else if werr != nil && werr != os.General_Error.Timeout {
				exited = true
				exit_code = -1
			}
		}

		if exited {
			// 直接子进程已退出，只排空当前可读数据，不等后台后代释放管道。
			for {
				any := false
				if stdout_open {
					data, done := read_stream(stdout_r, read_buf[:])
					if len(data) > 0 {
						line_reader_feed(&out_reader, data)
						any = true
					}
					if done {
						os.close(stdout_r)
						stdout_open = false
					}
				}
				if stderr_open {
					data, done := read_stream(stderr_r, read_buf[:])
					if len(data) > 0 {
						line_reader_feed(&err_reader, data)
						any = true
					}
					if done {
						os.close(stderr_r)
						stderr_open = false
					}
				}
				if !any {
					break
				}
			}
			break
		}

		time.sleep(5 * time.Millisecond)
	}

	line_reader_flush(&out_reader)
	line_reader_flush(&err_reader)
	if stdout_open {
		os.close(stdout_r)
	}
	if stderr_open {
		os.close(stderr_r)
	}
	delete(out_reader.buf)
	delete(err_reader.buf)

	finish_assistant(&app.renderer)
	ensure_line_start(&app.renderer)

	if !had_session && len(app.session_id) > 0 {
		renderer_note(app, fmt.tprintf("session: %s", app.session_id))
	}

	if exit_code != 0 {
		if exit_code == 130 || exit_code == 143 {
			renderer_note(app, "agent interrupted")
		} else {
			renderer_note(app, fmt.tprintf("agent exited with code %d", exit_code))
		}
	}
	if !app.options.verbose && len(app.stderr_log) > 0 && exit_code != 0 {
		renderer_note(app, "── agent stderr ──")
		for line in strings.split_lines(transmute(string)app.stderr_log[:], context.temp_allocator) {
			if len(strings.trim_space(line)) > 0 {
				renderer_note(app, line)
			}
		}
	}
	clear(&app.stderr_log)
	return exit_code
}

// 启动时重放已有 transcript；只展示历史，不重新执行工具或调用模型。
replay_session :: proc(app: ^App, session_id: string) -> Error {
	data, err := read_transcript(app.project, session_id)
	if !is_ok(err) {
		return err
	}
	defer delete(data)

	renderer_note(app, fmt.tprintf("── resumed %s ──", session_id))
	it := Line_Iterator{data = string(data)}
	for {
		line, more := next_line(&it)
		if !more {
			break
		}
		ev, ok := parse_event_line(line)
		if ok {
			render_event(&app.renderer, ev, .History)
		}
		free_all(context.temp_allocator)
	}
	finish_assistant(&app.renderer)
	ensure_line_start(&app.renderer)
	return ok_error()
}
