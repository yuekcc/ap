package aptools

import platform "../../ap-core/platform"

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

Child_Process :: struct {
	process:    os.Process,
	job:        platform.Job_Handle,
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
	cancel:            ^platform.Cancel_Token,
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

// 复制当前进程环境并剔除指定变量。返回的动态数组以及保留的字符串都由
// context.allocator 拥有，调用方用 free_env 释放。
filter_env_without :: proc(keys: ..string) -> [dynamic]string {
	env, _ := os.environ(context.allocator)
	out := make([dynamic]string, 0, len(env))
	for entry in env {
		matches := false
		for key in keys {
			if env_key_matches(entry, key) {
				matches = true
				break
			}
		}
		if matches {
			delete(entry)
			continue
		}
		append(&out, entry)
	}
	delete(env)
	return out
}

// Windows 环境变量不区分大小写，统一按不区分大小写匹配；POSIX 下大写
// 变量名也仍然只会命中同名项。
env_key_matches :: proc(entry, key: string) -> bool {
	if len(entry) <= len(key) || entry[len(key)] != '=' {
		return false
	}
	return strings.equal_fold(entry[:len(key)], key)
}

free_env :: proc(env: ^[dynamic]string) {
	for entry in env^ {
		delete(entry)
	}
	delete(env^)
	env^ = nil
}

spawn_child :: proc(
	command: []string,
	cwd: string,
	env: []string,
	stdin_data: []byte,
) -> (Child_Process, platform.Error) {
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
			return child, platform.errorf("cannot write temporary stdin file: %v", werr)
		}
		file, ferr := os.open(stdin_temp, {.Read, .Inheritable})
		if ferr != nil {
			os.remove(stdin_temp)
			return child, platform.errorf("cannot open temporary stdin file: %v", ferr)
		}
		stdin_file = file
	}
	r1, w1, e1 := os.pipe()
	if e1 != nil {
		if stdin_file != nil {
			os.close(stdin_file)
			os.remove(stdin_temp)
		}
		return child, platform.errorf("cannot create stdout pipe: %v", e1)
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
		return child, platform.errorf("cannot create stderr pipe: %v", e2)
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
		return child, platform.errorf("cannot spawn process: %v", perr)
	}

	if stdin_file != nil {
		os.close(stdin_file)
	}
	os.close(stdout_w)
	os.close(stderr_w)

	child = {
		process = process,
		job     = platform.attach_job(process),
		stdout  = stdout_r,
		stderr  = stderr_r,
		stdin_temp = stdin_temp,
	}
	return child, platform.ok_error()
}

read_available :: proc(file: ^os.File, buf: []byte) -> (data: []byte, done: bool, err: platform.Error) {
	has, herr := os.pipe_has_data(file)
	if herr != nil {
		return nil, true, platform.ok_error()
	}
	if !has {
		return nil, false, platform.ok_error()
	}
	n, rerr := os.read(file, buf)
	if rerr == os.General_Error.Broken_Pipe {
		return nil, true, platform.ok_error()
	}
	if rerr != nil {
		return nil, true, platform.errorf("pipe read failed: %v", rerr)
	}
	if n <= 0 {
		return nil, true, platform.ok_error()
	}
	return buf[:n], false, platform.ok_error()
}

run_child :: proc(opts: Run_Options) -> Run_Result {
	started := time.tick_now()
	result := Run_Result{exit_code = -1}
	child, serr := spawn_child(opts.command, opts.cwd, opts.env, opts.stdin_data)
	if !platform.is_ok(serr) {
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
	) -> (read_any: bool, err: platform.Error) {
		if file^ == nil {
			return false, platform.ok_error()
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
		if !platform.is_ok(stdout_err) {
			result.error = stdout_err.message
		}
		_, stderr_err := pump_stream(&child.stderr, &stderr_buf, &combined, read_buf[:], opts.on_stderr, opts.user)
		if !platform.is_ok(stderr_err) {
			result.error = stderr_err.message
		}

		if len(combined) > opts.max_capture_bytes {
			result.overflow = true
			kill_reason = 3
			break
		}
		if platform.cancel_token_cancelled(opts.cancel) {
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
		platform.kill_process_tree(child.job, child.process)
		state, werr := os.process_wait(child.process, 3000 * time.Millisecond)
		if werr == os.General_Error.Timeout {
			_ = os.process_kill(child.process)
			state, _ = os.process_wait(child.process, 3000 * time.Millisecond)
		}
		result.exit_code = state.exit_code
	}

	close_child_pipes(&child)
	if child.job != 0 {
		platform.register_job(child.job)
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
