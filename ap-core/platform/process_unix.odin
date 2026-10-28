#+build !windows
package platform

import "core:os"
import "core:sys/posix"
import "core:time"

// Unix 没有 Job Object；进程树靠 PPid 递归扫描，SIGTERM 后等 2s 再 SIGKILL。

Job_Handle :: distinct uintptr

mark_non_inheritable :: proc(file: ^os.File) {
}

attach_job :: proc(process: os.Process) -> Job_Handle {
	return 0
}

register_job :: proc(job: Job_Handle) {
}

release_job :: proc(job: Job_Handle) {
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
	defer delete(pids)
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
