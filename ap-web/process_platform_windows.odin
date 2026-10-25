#+build windows
package main

import "core:fmt"
import "core:os"
import "core:sync"
import win32 "core:sys/windows"

// 进程树终止沿用 ap 的语义：优先 Job Object，失败时退化为 taskkill /T /F。
// ap-web 不能 import ap，所以这里按 ap/platform_windows.odin 复制一份。

Job_Handle :: distinct uintptr

foreign import k32 "system:Kernel32.lib"

@(default_calling_convention="system")
foreign k32 {
	CreateJobObjectW         :: proc(attrs: rawptr, name: win32.LPCWSTR) -> win32.HANDLE ---
	AssignProcessToJobObject :: proc(job, process: win32.HANDLE) -> win32.BOOL ---
	TerminateJobObject       :: proc(job: win32.HANDLE, exit_code: u32) -> win32.BOOL ---
	CloseHandle              :: proc(handle: win32.HANDLE) -> win32.BOOL ---
}

// turn 线程注册/释放，主线程（Ctrl+C）清理：表必须加锁。
running_jobs: [dynamic]Job_Handle
running_jobs_mu: sync.Mutex

// 管道两端默认都可继承；stdin 的写端、stdout/stderr 的读端如果被 ap 继承，
// ap 读 stdin 时永远等不到 EOF（它自己还握着一份写端）。这里清掉继承标志。
mark_non_inheritable :: proc(file: ^os.File) {
	if file == nil {
		return
	}
	win32.SetHandleInformation(win32.HANDLE(os.fd(file)), win32.HANDLE_FLAG_INHERIT, 0)
}

attach_process_job :: proc(process: os.Process) -> Job_Handle {
	job := CreateJobObjectW(nil, nil)
	if job == nil {
		return 0
	}
	if !AssignProcessToJobObject(job, win32.HANDLE(process.handle)) {
		CloseHandle(job)
		return 0
	}
	return Job_Handle(uintptr(job))
}

register_job :: proc(job: Job_Handle) {
	if job == 0 {
		return
	}
	sync.mutex_lock(&running_jobs_mu)
	defer sync.mutex_unlock(&running_jobs_mu)
	for existing in running_jobs {
		if existing == job {
			return
		}
	}
	append(&running_jobs, job)
}

// turn 正常结束后立刻释放句柄，避免每轮泄漏一个 job。
release_job :: proc(job: Job_Handle) {
	if job == 0 {
		return
	}
	sync.mutex_lock(&running_jobs_mu)
	defer sync.mutex_unlock(&running_jobs_mu)
	for existing, i in running_jobs {
		if existing == job {
			unordered_remove(&running_jobs, i)
			break
		}
	}
	CloseHandle(win32.HANDLE(uintptr(job)))
}

// 服务退出前终止所有仍挂着的子进程树。
cleanup_jobs :: proc() {
	sync.mutex_lock(&running_jobs_mu)
	defer sync.mutex_unlock(&running_jobs_mu)
	for job in running_jobs {
		TerminateJobObject(win32.HANDLE(uintptr(job)), 1)
		CloseHandle(win32.HANDLE(uintptr(job)))
	}
	clear(&running_jobs)
}

kill_process_tree :: proc(job: Job_Handle, process: os.Process) {
	if job != 0 {
		if TerminateJobObject(win32.HANDLE(uintptr(job)), 1) {
			return
		}
	}
	pid_text := fmt.tprintf("%d", process.pid)
	state, _, _, _ := os.process_exec(
		{command = []string{"taskkill", "/PID", pid_text, "/T", "/F"}},
		context.allocator,
	)
	_ = state
	_ = os.process_kill(process)
}
