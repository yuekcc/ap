package ap

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

Job_Handle :: distinct uintptr

Child_Process :: struct {
	process:    os.Process,
	job:        Job_Handle,
	stdout:     ^os.File,
	stderr:     ^os.File,
	stdin_temp: string,
}

Run_Options :: struct {
	command:           []string,
	cwd:               string,
	env:               []string,
	stdin_data:        []byte,
	timeout_ms:        int,
	max_capture_bytes: int,
	cancel:            ^Cancel_Token,
	on_stdout:         proc(user: rawptr, chunk: string),
	on_stderr:         proc(user: rawptr, chunk: string),
	user:              rawptr,
}

Run_Result :: struct {
	spawned:     bool,
	exit_code:   int,
	timed_out:   bool,
	cancelled:   bool,
	overflow:    bool,
	stdout:      []byte,
	stderr:      []byte,
	combined:    []byte,
	duration_ms: int,
	error:       string,
}

filter_env_without :: proc(key: string) -> []string {
	env, _ := os.environ(context.allocator)
	out := make([dynamic]string, 0, len(env))
	prefix, _ := strings.to_upper(fmt.tprintf("%s=", key), context.temp_allocator)
	for entry in env {
		upper, _ := strings.to_upper(entry, context.temp_allocator)
		if strings.has_prefix(upper, prefix) {
			continue
		}
		append(&out, entry)
	}
	return out[:]
}

spawn_child :: proc(
	command: []string,
	cwd: string,
	env: []string,
	stdin_data: []byte,
) -> (Child_Process, Error) {
	child: Child_Process
	stdin_file: ^os.File
	stdin_temp := ""
	stdout_r, stdout_w: ^os.File
	stderr_r, stderr_w: ^os.File

	if stdin_data != nil {
		base := os.get_env("TEMP", context.allocator)
		if len(base) == 0 {
			base = cwd
		}
		stdin_temp = fmt.tprintf("%s/.ap-stdin-%d-%d", base, os.get_pid(), time.time_to_unix_nano(time.now()))
		if werr := os.write_entire_file_from_bytes(stdin_temp, stdin_data); werr != nil {
			return child, make_error(.Tool, "cannot write temporary stdin file: %v", werr)
		}
		file, ferr := os.open(stdin_temp, {.Read, .Inheritable})
		if ferr != nil {
			os.remove(stdin_temp)
			return child, make_error(.Tool, "cannot open temporary stdin file: %v", ferr)
		}
		stdin_file = file
	}
	r1, w1, e1 := os.pipe()
	if e1 != nil {
		if stdin_file != nil {
			os.close(stdin_file)
			os.remove(stdin_temp)
		}
		return child, make_error(.Tool, "cannot create stdout pipe: %v", e1)
	}
	stdout_r, stdout_w = r1, w1
	r2, w2, e2 := os.pipe()
	if e2 != nil {
		os.close(stdout_r)
		os.close(stdout_w)
		if stdin_file != nil {
			os.close(stdin_file)
			os.remove(stdin_temp)
		}
		return child, make_error(.Tool, "cannot create stderr pipe: %v", e2)
	}
	stderr_r, stderr_w = r2, w2

	desc := os.Process_Desc {
		working_dir = cwd,
		command = command,
		env = env,
		stdin = stdin_file,
		stdout = stdout_w,
		stderr = stderr_w,
	}
	process, perr := os.process_start(desc)
	if perr != nil {
		os.close(stdout_r)
		os.close(stdout_w)
		os.close(stderr_r)
		os.close(stderr_w)
		if stdin_file != nil {
			os.close(stdin_file)
			os.remove(stdin_temp)
		}
		return child, make_error(.Tool, "cannot spawn process: %v", perr)
	}

	if stdin_file != nil {
		os.close(stdin_file)
	}
	os.close(stdout_w)
	os.close(stderr_w)

	child = {
		process = process,
		job     = attach_process_job(process),
		stdout  = stdout_r,
		stderr  = stderr_r,
		stdin_temp = stdin_temp,
	}
	return child, ok_error()
}

read_available :: proc(file: ^os.File, buf: []byte) -> (data: []byte, done: bool, err: Error) {
	has, herr := os.pipe_has_data(file)
	if herr != nil {
		return nil, true, ok_error()
	}
	if !has {
		return nil, false, ok_error()
	}
	n, rerr := os.read(file, buf)
	if rerr == os.General_Error.Broken_Pipe {
		return nil, true, ok_error()
	}
	if rerr != nil {
		return nil, true, make_error(.Tool, "pipe read failed: %v", rerr)
	}
	if n <= 0 {
		return nil, true, ok_error()
	}
	return buf[:n], false, ok_error()
}

run_child :: proc(opts: Run_Options) -> Run_Result {
	started := time.tick_now()
	result := Run_Result{exit_code = -1}
	child, serr := spawn_child(opts.command, opts.cwd, opts.env, opts.stdin_data)
	if !is_ok(serr) {
		result.error = serr.message
		return result
	}
	result.spawned = true

	// 读一路管道并追加到缓冲；返回本轮是否读到数据。EOF 或出错时关闭并清空句柄。
	pump_stream :: proc(
		file: ^^os.File,
		sink, combined: ^[dynamic]byte,
		read_buf: []byte,
		on_chunk: proc(user: rawptr, chunk: string),
		user: rawptr,
	) -> (read_any: bool, err: Error) {
		if file^ == nil {
			return false, ok_error()
		}
		data, done, rerr := read_available(file^, read_buf)
		if len(data) > 0 {
			append(sink, ..data)
			append(combined, ..data)
			if on_chunk != nil {
				on_chunk(user, string(data))
			}
			read_any = true
		}
		if done {
			os.close(file^)
			file^ = nil
		}
		return read_any, rerr
	}

	stdout_buf := make([dynamic]byte, 0, 4096)
	stderr_buf := make([dynamic]byte, 0, 4096)
	combined := make([dynamic]byte, 0, 8192)

	read_buf: [65536]byte
	timeout := time.Duration(opts.timeout_ms) * time.Millisecond
	process_exited := false
	kill_reason := 0 // 1=timeout 2=cancel 3=overflow

	for {
		// 读取两路管道；先读的流先进入 combined（顺序不保证，符合契约）。
		_, stdout_err := pump_stream(&child.stdout, &stdout_buf, &combined, read_buf[:], opts.on_stdout, opts.user)
		if !is_ok(stdout_err) {
			result.error = stdout_err.message
		}
		_, stderr_err := pump_stream(&child.stderr, &stderr_buf, &combined, read_buf[:], opts.on_stderr, opts.user)
		if !is_ok(stderr_err) {
			result.error = stderr_err.message
		}

		if len(combined) > opts.max_capture_bytes {
			result.overflow = true
			kill_reason = 3
			break
		}
		if cancel_token_cancelled(opts.cancel) {
			result.cancelled = true
			kill_reason = 2
			break
		}
		if opts.timeout_ms > 0 && time.tick_since(started) >= timeout {
			result.timed_out = true
			kill_reason = 1
			break
		}

		if !process_exited {
			state, werr := os.process_wait(child.process, 20 * time.Millisecond)
			if werr == nil && state.exited {
				result.exit_code = state.exit_code
				process_exited = true
			} else if werr != nil && werr != os.General_Error.Timeout {
				result.error = fmt.tprintf("wait failed: %v", werr)
				process_exited = true
			}
		}

		if process_exited {
			// 直接子进程退出后只排空当前可用数据，不等待后台后代持有的管道 EOF。
			for {
				read_any := false
				any_stdout, _ := pump_stream(&child.stdout, &stdout_buf, &combined, read_buf[:], opts.on_stdout, opts.user)
				any_stderr, _ := pump_stream(&child.stderr, &stderr_buf, &combined, read_buf[:], opts.on_stderr, opts.user)
				if any_stdout || any_stderr {
					read_any = true
				}
				if len(combined) > opts.max_capture_bytes {
					result.overflow = true
					break
				}
				if !read_any {
					break
				}
			}
			break
		}

		time.sleep(5 * time.Millisecond)
	}

	if kill_reason != 0 {
		kill_process_tree(child.job, child.process)
		state, werr := os.process_wait(child.process, 3000 * time.Millisecond)
		if werr == os.General_Error.Timeout {
			_ = os.process_kill(child.process)
			state, _ = os.process_wait(child.process, 3000 * time.Millisecond)
		}
		result.exit_code = state.exit_code
	}

	close_child_pipes(&child)
	if child.job != 0 {
		register_job(child.job)
	}
	result.stdout = stdout_buf[:]
	result.stderr = stderr_buf[:]
	result.combined = combined[:]
	result.duration_ms = int(time.tick_since(started) / time.Millisecond)
	return result
}

free_run_result :: proc(result: ^Run_Result) {
	delete(result.stdout)
	delete(result.stderr)
	delete(result.combined)
	result.stdout = nil
	result.stderr = nil
	result.combined = nil
}

close_child_pipes :: proc(child: ^Child_Process) {
	if child.stdout != nil {
		os.close(child.stdout)
		child.stdout = nil
	}
	if child.stderr != nil {
		os.close(child.stderr)
		child.stderr = nil
	}
	if len(child.stdin_temp) > 0 {
		os.remove(child.stdin_temp)
		child.stdin_temp = ""
	}
}

// 把可能包含非法 UTF-8 的字节转成合法字符串，用于 JSON transcript。
sanitize_utf8 :: proc(data: []byte) -> string {
	if utf8.valid_string(string(data)) {
		return string(data)
	}
	b := strings.builder_make()
	remaining := data
	for len(remaining) > 0 {
		r, size := utf8.decode_rune(remaining)
		if r == utf8.RUNE_ERROR && size == 1 {
			strings.write_string(&b, "\uFFFD")
			remaining = remaining[1:]
			continue
		}
		strings.write_rune(&b, r)
		remaining = remaining[size:]
	}
	return strings.to_string(b)
}
