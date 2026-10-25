package main

import "../internal"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

// 把管道里的字节流切成完整行；一行 stdout 就是一个 stream-json 事件。
// 每次 feed 后压实缓冲，避免长 turn 的无界增长。
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

// 进程退出时把最后一截没有换行结尾的内容也交出去。
line_reader_flush :: proc(lr: ^Line_Reader) {
	if lr.start < len(lr.buf) {
		lr.callback(lr.user, transmute(string)lr.buf[lr.start:])
	}
	resize(&lr.buf, 0)
	lr.start = 0
}

MAX_STDERR_BYTES :: 64 * 1024

// stderr 不在正常退出时展示；这里只保留尾部窗口，异常退出时随 turn_done 带给前端。
// 超过 64 KiB 时保留最新约 32 KiB，并对齐到完整行，避免半行。
append_stderr_line :: proc(log: ^[dynamic]u8, line: string) {
	append(log, ..transmute([]byte)line)
	append(log, '\n')
	if len(log) > MAX_STDERR_BYTES {
		keep := MAX_STDERR_BYTES / 2
		start := len(log) - keep
		if idx := strings.index_byte(transmute(string)log[start:], '\n'); idx >= 0 {
			start += idx + 1
		}
		remaining := len(log) - start
		copy(log[:], log[start:])
		resize(log, remaining)
	}
}

// 一个 turn 的启动参数。runner（工单 04）用当前 project 与 session 指针填充，
// 每次 turn 都新建一个 ap 子进程。
Turn_Options :: struct {
	agent_bin:  string,
	session_id: string, // 为空时本轮让 ap 新建 session，之后从 session_start 捕获
	config_dir: string, // ap --config-dir
	cwd:        string, // ap 的工作目录，通常是 project.root
	model:      Maybe(string),
	agent:      Maybe(string),
	max_steps:  Maybe(int),
	max_tokens: Maybe(int),
	verbose:    bool,
	cancel:     ^Agent_Cancel_Token, // 可为 nil；DELETE /api/turn 在另一线程置位
}

// 单飞 turn 的取消信号。泵在每个轮询点检查；置位后终止整棵进程树。
Agent_Cancel_Token :: struct {
	value: i32,
}

agent_cancel_token_cancel :: proc(token: ^Agent_Cancel_Token) {
	if token != nil {
		sync.atomic_store(&token.value, 1)
	}
}

agent_cancel_token_cancelled :: proc(token: ^Agent_Cancel_Token) -> bool {
	if token == nil {
		return false
	}
	return sync.atomic_load(&token.value) != 0
}

// runner 只需要三件事：逐事件转发、可选 stderr 日志、结束信封。
// on_event / on_stderr 的字符串只在回调期间有效（解析用 temp arena）。
Turn_Callbacks :: struct {
	user:      rawptr,
	on_event:  proc(user: rawptr, ev: Event),
	on_stderr: proc(user: rawptr, line: string),
	on_done:   proc(user: rawptr, exit_code: int, stderr_preview: string),
}

// session_id / stderr_preview 归调用方所有，需要 delete。
Turn_Result :: struct {
	exit_code:      int,
	session_id:     string, // 从本轮流里的 session_start 捕获；可能为空
	stderr_preview: string, // 仅异常退出时非空
	cancelled:      bool,   // 由 Agent_Cancel_Token 主动终止
	interrupted:    bool,   // cancelled 或 130/143
}

Pump_State :: struct {
	session_id: string,
	stderr_log: [dynamic]u8,
}

Pump_Context :: struct {
	callbacks: ^Turn_Callbacks,
	state:     ^Pump_State,
}

// 逐行解析 stdout；非 JSON / 缺 type 的行静默跳过（与 ap-tui 一致）。
on_agent_stdout_line :: proc(user: rawptr, line: string) {
	ctx := (^Pump_Context)(user)
	ev, ok := parse_event_line(line)
	if !ok {
		free_all(context.temp_allocator)
		return
	}
	if ev.type == "session_start" && len(ev.session_id) > 0 {
		cloned := strings.clone(ev.session_id, context.allocator)
		if len(ctx.state.session_id) > 0 {
			delete(ctx.state.session_id, context.allocator)
		}
		ctx.state.session_id = cloned
	}
	if ctx.callbacks.on_event != nil {
		ctx.callbacks.on_event(ctx.callbacks.user, ev)
	}
	free_all(context.temp_allocator)
}

on_agent_stderr_line :: proc(user: rawptr, line: string) {
	ctx := (^Pump_Context)(user)
	append_stderr_line(&ctx.state.stderr_log, line)
	if ctx.callbacks.on_stderr != nil {
		ctx.callbacks.on_stderr(ctx.callbacks.user, line)
	}
	free_all(context.temp_allocator)
}

// 非阻塞读：没数据就返回 false；EOF/错误返回 done。
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

// 查找顺序与 ap-tui 一致：
// --agent-bin → AP_AGENT_BIN → AP_BIN → 自身同目录 ap/ag → PATH。
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
	names := [2]string{"ap.exe", "ag.exe"} when ODIN_OS == .Windows else [2]string{"ap", "ag"}
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
	return "", errorf("cannot find ap.exe/ag.exe next to ap-web or in PATH; use --agent-bin")
}

// 与 ap-tui 完全一致：提示词走 stdin，stdout 输出 stream-json。
// 服务端白名单映射，不拼接 shell。
build_agent_command :: proc(options: ^Turn_Options) -> [dynamic]string {
	cmd := make([dynamic]string, 0, 16, context.allocator)
	append(&cmd, options.agent_bin)
	append(&cmd, "--print0")
	append(&cmd, "--output-format", "stream-json")
	if len(options.session_id) > 0 {
		append(&cmd, "-s", options.session_id)
	}
	if value, ok := options.model.?; ok {
		append(&cmd, "--model", value)
	}
	if value, ok := options.agent.?; ok {
		append(&cmd, "--agent", value)
	}
	if value, ok := options.max_steps.?; ok {
		append(&cmd, "--max-steps", fmt.tprintf("%d", value))
	}
	if value, ok := options.max_tokens.?; ok {
		append(&cmd, "--max-tokens", fmt.tprintf("%d", value))
	}
	append(&cmd, "--config-dir", options.config_dir)
	if options.verbose {
		append(&cmd, "--verbose")
	}
	return cmd
}

// 启动 ap 子进程并泵事件。只有直接子进程退出后才排空管道，
// 不等待后台后代释放写端（否则可能永远不返回）。
pump_agent :: proc(options: ^Turn_Options, prompt: string, callbacks: Turn_Callbacks) -> (result: Turn_Result) {
	result.exit_code = -1
	state: Pump_State
	cb := callbacks
	defer {
		if len(state.session_id) > 0 {
			result.session_id = state.session_id
			state.session_id = ""
		}
		if len(state.stderr_log) > 0 && result.exit_code != 0 && len(result.stderr_preview) == 0 {
			result.stderr_preview = strings.clone(string(state.stderr_log[:]), context.allocator)
		}
		delete(state.stderr_log)
	}

	// 取消请求在 spawn 之前到达：不启动新进程。
	if agent_cancel_token_cancelled(options.cancel) {
		result.exit_code = 130
		result.cancelled = true
		result.interrupted = true
		return
	}

	command := build_agent_command(options)
	defer delete(command)

	stdin_r, stdin_w, e1 := os.pipe()
	if e1 != nil {
		result.exit_code = 1
		result.stderr_preview = fmt.aprintf("cannot create stdin pipe: %v", e1)
		return
	}
	stdout_r, stdout_w, e2 := os.pipe()
	if e2 != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		result.exit_code = 1
		result.stderr_preview = fmt.aprintf("cannot create stdout pipe: %v", e2)
		return
	}
	stderr_r, stderr_w, e3 := os.pipe()
	if e3 != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		os.close(stdout_r)
		os.close(stdout_w)
		result.exit_code = 1
		result.stderr_preview = fmt.aprintf("cannot create stderr pipe: %v", e3)
		return
	}

	desc := os.Process_Desc {
		working_dir = options.cwd,
		command     = command[:],
		stdin       = stdin_r,
		stdout      = stdout_w,
		stderr      = stderr_w,
	}
	// Windows 上管道两端默认可继承：必须清掉这三端，否则 ap 等不到 stdin EOF。
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
		result.exit_code = 1
		result.stderr_preview = fmt.aprintf("cannot start %s: %v", options.agent_bin, perr)
		return
	}

	job := attach_process_job(process)
	register_job(job)
	defer release_job(job)

	os.close(stdin_r)
	os.close(stdout_w)
	os.close(stderr_w)

	// 提示词走 stdin；关写端就是 --print0 的 EOF 信号。
	if !internal.write_all(stdin_w, transmute([]byte)prompt) {
		append_stderr_line(&state.stderr_log, "cannot write prompt to agent stdin")
	}
	os.close(stdin_w)

	ctx := Pump_Context {
		callbacks = &cb,
		state     = &state,
	}
	out_reader := Line_Reader {
		callback = on_agent_stdout_line,
		user     = &ctx,
	}
	err_reader := Line_Reader {
		callback = on_agent_stderr_line,
		user     = &ctx,
	}
	defer {
		delete(out_reader.buf)
		delete(err_reader.buf)
	}

	stdout_open := true
	stderr_open := true
	exited := false
	exit_code := -1
	cancelled := false
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

		if !cancelled && agent_cancel_token_cancelled(options.cancel) {
			cancelled = true
			kill_process_tree(job, process)
			// 给 ap 一点时间自己写 session_end(reason=signal) 并退出。
			wait_state, werr := os.process_wait(process, 3000 * time.Millisecond)
			if werr == os.General_Error.Timeout {
				_ = os.process_kill(process)
				wait_state, werr = os.process_wait(process, 3000 * time.Millisecond)
			}
			exit_code = wait_state.exit_code if werr == nil else -1
			exited = true
		}

		if !exited {
			wait_state, werr := os.process_wait(process, 10 * time.Millisecond)
			if werr == nil && wait_state.exited {
				exit_code = wait_state.exit_code
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

	result.exit_code = exit_code
	result.cancelled = cancelled
	result.interrupted = cancelled || exit_code == 130 || exit_code == 143
	return
}

// 执行一个 turn：每轮启动一个新的 ap 子进程，逐事件回调，结束时回调 on_done。
run_agent_turn :: proc(options: Turn_Options, prompt: string, callbacks: Turn_Callbacks) -> Turn_Result {
	opts := options
	result := pump_agent(&opts, prompt, callbacks)
	if callbacks.on_done != nil {
		callbacks.on_done(callbacks.user, result.exit_code, result.stderr_preview)
	}
	return result
}
