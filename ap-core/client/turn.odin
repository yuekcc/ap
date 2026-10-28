package client

import "../platform"
import "../protocol"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

MAX_STDERR_BYTES :: 64 * 1024

// 一个 turn 的启动参数。每次 turn 都新建一个 ap 子进程。
Turn_Options :: struct {
	agent_bin:   string,
	config_dir:  string, // ap --config-dir
	cwd:         string, // ap 的工作目录，通常是 project.root
	session_id:  string, // 为空时本轮让 ap 新建 session，之后从 session_start 捕获
	fork_session: bool,
	model:       Maybe(string),
	agent:       Maybe(string),
	max_steps:   Maybe(int),
	max_tokens:  Maybe(int),
	verbose:     bool,
	cancel:      ^platform.Cancel_Token, // 可为 nil
	// 本轮回调与结果（session_id/stderr_preview）用的分配器；空 = context.allocator。
	// runner 在 turn 线程里分配、在另一线程释放，所以显式传 heap_allocator()。
	allocator:   runtime.Allocator,
}

allocator_or_default :: proc(allocator: runtime.Allocator) -> runtime.Allocator {
	if allocator.procedure == nil {
		return context.allocator
	}
	return allocator
}

turn_allocator :: proc(options: ^Turn_Options) -> runtime.Allocator {
	return allocator_or_default(options.allocator)
}

// 逐事件转发、可选 stderr 日志、结束信封。
// on_event_line 额外带 stdout 的原始 JSON 行：SSE 要求「原样直转发」，
// 用结构体重新序列化会丢掉 ap 新增/未知字段。字符串只在回调期间有效。
Turn_Callbacks :: struct {
	user:          rawptr,
	on_event:      proc(user: rawptr, ev: protocol.Stream_Event),
	on_event_line: proc(user: rawptr, ev: protocol.Stream_Event, line: string),
	on_stderr:     proc(user: rawptr, line: string),
}

// session_id / stderr_preview 归调用方所有，按 Turn_Options.allocator 释放。
Turn_Result :: struct {
	exit_code:      int,
	session_id:     string, // 从本轮流里的 session_start 捕获；可能为空
	stderr_preview: string, // 仅异常退出时非空
	cancelled:      bool,   // 由 cancel token 主动终止
}

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

Pump_State :: struct {
	session_id: string,
	stderr_log: [dynamic]u8,
	allocator:  runtime.Allocator,
}

pump_allocator :: proc(state: ^Pump_State) -> runtime.Allocator {
	return allocator_or_default(state.allocator)
}

Pump_Context :: struct {
	callbacks: ^Turn_Callbacks,
	state:     ^Pump_State,
}

// 逐行解析 stdout；非 JSON / 缺 type 的行静默跳过。
on_agent_stdout_line :: proc(user: rawptr, line: string) {
	ctx := (^Pump_Context)(user)
	ev, ok := protocol.parse_stream_event(line)
	if !ok {
		free_all(context.temp_allocator)
		return
	}
	if ev.type == "session_start" && len(ev.session_id) > 0 {
		alloc := pump_allocator(ctx.state)
		cloned := strings.clone(ev.session_id, alloc)
		if len(ctx.state.session_id) > 0 {
			delete(ctx.state.session_id, alloc)
		}
		ctx.state.session_id = cloned
	}
	if ctx.callbacks.on_event != nil {
		ctx.callbacks.on_event(ctx.callbacks.user, ev)
	}
	if ctx.callbacks.on_event_line != nil {
		ctx.callbacks.on_event_line(ctx.callbacks.user, ev, line)
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

// 启动 ap 子进程并泵事件。只有直接子进程退出后才排空管道，
// 不等待后台后代释放写端（否则可能永远不返回）。阻塞调用。
turn_run :: proc(options: ^Turn_Options, prompt: string, callbacks: Turn_Callbacks) -> (result: Turn_Result) {
	result.exit_code = -1
	alloc := turn_allocator(options)
	state: Pump_State
	state.allocator = alloc
	cb := callbacks
	defer {
		// 若在 return 前没有转交所有权，session_id 仍归本函数，需要释放。
		if len(state.session_id) > 0 {
			delete(state.session_id, alloc)
		}
		delete(state.stderr_log)
	}

	// 取消请求在 spawn 之前到达：不启动新进程。
	if platform.cancel_token_cancelled(options.cancel) {
		result.exit_code = 130
		result.cancelled = true
		return
	}

	command := build_agent_command(options)
	defer delete(command)

	stdin_r, stdin_w, e1 := os.pipe()
	if e1 != nil {
		result.exit_code = 1
		result.stderr_preview = fmt.aprintf("cannot create stdin pipe: %v", e1, alloc)
		return
	}
	stdout_r, stdout_w, e2 := os.pipe()
	if e2 != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		result.exit_code = 1
		result.stderr_preview = fmt.aprintf("cannot create stdout pipe: %v", e2, alloc)
		return
	}
	stderr_r, stderr_w, e3 := os.pipe()
	if e3 != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		os.close(stdout_r)
		os.close(stdout_w)
		result.exit_code = 1
		result.stderr_preview = fmt.aprintf("cannot create stderr pipe: %v", e3, alloc)
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
	platform.mark_non_inheritable(stdin_w)
	platform.mark_non_inheritable(stdout_r)
	platform.mark_non_inheritable(stderr_r)
	process, perr := os.process_start(desc)
	if perr != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		os.close(stdout_r)
		os.close(stdout_w)
		os.close(stderr_r)
		os.close(stderr_w)
		result.exit_code = 1
		result.stderr_preview = fmt.aprintf("cannot start %s: %v", options.agent_bin, perr, alloc)
		return
	}

	job := platform.attach_job(process)
	platform.register_job(job)
	defer platform.release_job(job)

	os.close(stdin_r)
	os.close(stdout_w)
	os.close(stderr_w)

	// 提示词走 stdin；关写端就是 --print0 的 EOF 信号。
	if !platform.write_all(stdin_w, transmute([]byte)prompt) {
		append_stderr_line(&state.stderr_log, "cannot write prompt to agent stdin")
	}
	os.close(stdin_w)

	ctx := Pump_Context {
		callbacks = &cb,
		state     = &state,
	}
	out_reader := protocol.Line_Reader {
		callback = on_agent_stdout_line,
		user     = &ctx,
	}
	err_reader := protocol.Line_Reader {
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
				protocol.line_reader_feed(&out_reader, data)
			}
			if done {
				os.close(stdout_r)
				stdout_open = false
			}
		}
		if stderr_open {
			data, done := read_stream(stderr_r, read_buf[:])
			if len(data) > 0 {
				protocol.line_reader_feed(&err_reader, data)
			}
			if done {
				os.close(stderr_r)
				stderr_open = false
			}
		}

		if !cancelled && platform.cancel_token_cancelled(options.cancel) {
			cancelled = true
			platform.kill_process_tree(job, process)
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
						protocol.line_reader_feed(&out_reader, data)
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
						protocol.line_reader_feed(&err_reader, data)
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

	protocol.line_reader_flush(&out_reader)
	protocol.line_reader_flush(&err_reader)
	if stdout_open {
		os.close(stdout_r)
	}
	if stderr_open {
		os.close(stderr_r)
	}

	result.exit_code = exit_code
	result.cancelled = cancelled
	if len(state.session_id) > 0 {
		result.session_id = state.session_id
		state.session_id = ""
	}
	if len(state.stderr_log) > 0 && exit_code != 0 {
		result.stderr_preview = strings.clone(string(state.stderr_log[:]), alloc)
	}
	return
}
