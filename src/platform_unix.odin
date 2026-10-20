#+build !windows
package ap

import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:time"

local_now :: proc() -> (year, month, day, hour, minute, second: int) {
	stamp := posix.time_t(time.time_to_unix(time.now()))
	tm: posix.tm
	if posix.localtime_r(&stamp, &tm) == nil {
		return 1970, 1, 1, 0, 0, 0
	}
	return tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec
}

attach_process_job :: proc(process: os.Process) -> Job_Handle {
	return 0
}

register_job :: proc(job: Job_Handle) {
}

cleanup_jobs :: proc() {
}

collect_descendants :: proc(pid: int, out: ^[dynamic]int) {
	processes, _ := os.process_list(context.allocator)
	defer delete(processes)
	for child_pid in processes {
		if child_pid == pid {
			continue
		}
		info, err := os.process_info_by_pid(child_pid, {.PPid}, context.temp_allocator)
		ppid := -1
		if err == nil && .PPid in info.fields {
			ppid = info.ppid
		}
		os.free_process_info(info, context.temp_allocator)
		if ppid == pid {
			append(out, child_pid)
			collect_descendants(child_pid, out)
		}
	}
}

kill_process_tree :: proc(job: Job_Handle, process: os.Process) {
	pids := make([dynamic]int, 0, 8)
	append(&pids, process.pid)
	collect_descendants(process.pid, &pids)

	for pid in pids {
		posix.kill(posix.pid_t(pid), .SIGTERM)
	}
	time.sleep(2 * time.Second)
	for pid in pids {
		// 已退出的 pid 可能被复用；这里仍按 2s 前的快照发送 SIGKILL。
		posix.kill(posix.pid_t(pid), .SIGKILL)
	}
}

g_cancel_token: ^Cancel_Token
g_signal_code: i32
g_signal_tick: time.Tick

unix_signal_handler :: proc "c" (sig: posix.Signal) {
	code: i32 = 130
	if sig == .SIGTERM {
		code = 143
	}
	if sync.atomic_load(&g_signal_code) != 0 {
		if time.tick_since(g_signal_tick) < time.Second {
			os.exit(int(code))
		}
	}
	sync.atomic_store(&g_signal_code, code)
	g_signal_tick = time.tick_now()
	if token := g_cancel_token; token != nil {
		sync.atomic_store(&token.value, 1)
	}
}

install_signal_handlers :: proc(token: ^Cancel_Token) {
	g_cancel_token = token
	act: posix.sigaction_t
	act.sa_handler = unix_signal_handler
	posix.sigemptyset(&act.sa_mask)
	act.sa_flags = {}
	posix.sigaction(.SIGINT, &act, nil)
	posix.sigaction(.SIGTERM, &act, nil)
}

signal_exit_code :: proc() -> int {
	code := sync.atomic_load(&g_signal_code)
	return int(code)
}

setup_console_utf8 :: proc() {
}
