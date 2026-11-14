#+build windows
package platform

import "core:fmt"
import "core:os"
import "core:sync"
import win32 "core:sys/windows"

// 进程树终止：优先 Job Object，失败时退化为 taskkill /T /F。
// Job 表会被多个 turn 线程与主线程同时访问，必须加锁。

Job_Handle :: distinct uintptr

foreign import k32 "system:Kernel32.lib"

@(default_calling_convention="system")
foreign k32 {
	CreateJobObjectW         :: proc(attrs: rawptr, name: win32.LPCWSTR) -> win32.HANDLE ---
	AssignProcessToJobObject :: proc(job, process: win32.HANDLE) -> win32.BOOL ---
	TerminateJobObject       :: proc(job: win32.HANDLE, exit_code: u32) -> win32.BOOL ---
	CloseHandle              :: proc(handle: win32.HANDLE) -> win32.BOOL ---
	SetInformationJobObject   :: proc(job: win32.HANDLE, info_class: u32, info: rawptr, len: u32) -> win32.BOOL ---
	QueryInformationJobObject :: proc(job: win32.HANDLE, info_class: u32, info: rawptr, len: u32, returned: ^u32) -> win32.BOOL ---
}

// 最小化的 Win32 结构定义：只需要读 ActiveProcesses 和写 LimitFlags。
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x00002000
JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS :: 9
JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION_CLASS :: 1

JOBOBJECT_BASIC_LIMIT_INFORMATION :: struct {
	per_process_user_time_limit: i64,
	per_job_user_time_limit:     i64,
	limit_flags:                 u32,
	minimum_working_set_size:    uintptr,
	maximum_working_set_size:    uintptr,
	active_process_limit:        u32,
	affinity:                    uintptr,
	priority_class:              u32,
	scheduling_class:            u32,
}

IO_COUNTERS :: struct {
	read_operation_count:  u64,
	write_operation_count: u64,
	other_operation_count: u64,
	read_transfer_count:   u64,
	write_transfer_count:  u64,
	other_transfer_count:  u64,
}

JOBOBJECT_EXTENDED_LIMIT_INFORMATION :: struct {
	basic_limit_information: JOBOBJECT_BASIC_LIMIT_INFORMATION,
	io_info:                 IO_COUNTERS,
	process_memory_limit:     uintptr,
	job_memory_limit:         uintptr,
	peak_process_memory_used: uintptr,
	peak_job_memory_used:     uintptr,
}

JOBOBJECT_BASIC_ACCOUNTING_INFORMATION :: struct {
	total_user_time:               i64,
	total_kernel_time:             i64,
	this_period_total_user_time:   i64,
	this_period_total_kernel_time: i64,
	total_page_fault_count:        u32,
	total_processes:              u32,
	active_processes:             u32,
	total_terminated_processes:   u32,
}

running_jobs: [dynamic]Job_Handle
running_jobs_mu: sync.Mutex
// 关停后不再接受新登记：句柄值会被系统复用，迟到的 release_job 不能
// 误伤别的线程刚创建、恰好拿到同一个数值的 job。
jobs_shutdown: bool

// 管道两端默认都可继承；stdin 的写端、stdout/stderr 的读端如果被子进程继承，
// 子进程读 stdin 时永远等不到 EOF（它自己还握着一份写端）。这里清掉继承标志。
mark_non_inheritable :: proc(file: ^os.File) {
	if file == nil {
		return
	}
	win32.SetHandleInformation(win32.HANDLE(os.fd(file)), win32.HANDLE_FLAG_INHERIT, 0)
}

attach_job :: proc(process: os.Process) -> Job_Handle {
	job := CreateJobObjectW(nil, nil)
	if job == nil {
		return 0
	}
	if !AssignProcessToJobObject(job, win32.HANDLE(process.handle)) {
		CloseHandle(job)
		return 0
	}
	// 兜底：前端进程崩溃或 os.exit 时没机会跑 cleanup_jobs，最后一个 job
	// 句柄随进程消失被关闭，必须连带终止整棵进程树。
	limit := JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	limit.basic_limit_information.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	SetInformationJobObject(
		job,
		JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
		&limit,
		size_of(limit),
	)
	return Job_Handle(uintptr(job))
}

// 查询 job 里还活着的进程数；失败按 0 处理，宁可提前归还句柄。
job_active_processes :: proc(job: Job_Handle) -> int {
	info: JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
	returned: u32
	if !QueryInformationJobObject(
		win32.HANDLE(uintptr(job)),
		JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION_CLASS,
		&info,
		size_of(info),
		&returned,
	) {
		return 0
	}
	return int(info.active_processes)
}

register_job :: proc(job: Job_Handle) {
	if job == 0 {
		return
	}
	sync.mutex_lock(&running_jobs_mu)
	defer sync.mutex_unlock(&running_jobs_mu)
	if jobs_shutdown {
		return
	}
	for existing in running_jobs {
		if existing == job {
			return
		}
	}
	append(&running_jobs, job)
}

// 正常结束后归还句柄，避免每轮泄漏一个 job。还有后台后代时不归还：
// 句柄一关 KILL_ON_JOB_CLOSE 就会连带杀掉它们，而工具语义允许后台进程
// 活到 ap 退出。这类 job 留给 cleanup_jobs 统一处理。
release_job :: proc(job: Job_Handle) {
	if job == 0 {
		return
	}
	sync.mutex_lock(&running_jobs_mu)
	defer sync.mutex_unlock(&running_jobs_mu)
	if jobs_shutdown {
		return
	}
	for existing, i in running_jobs {
		if existing == job {
			if job_active_processes(job) > 0 {
				return
			}
			unordered_remove(&running_jobs, i)
			CloseHandle(win32.HANDLE(uintptr(job)))
			return
		}
	}
	// 不在注册表里说明 cleanup_jobs 已经回收过。不能再 CloseHandle：
	// 句柄值可能已被系统复用给别的 socket、文件或管道。
}

// 进程退出前终止所有仍挂着的子进程树。
cleanup_jobs :: proc() {
	sync.mutex_lock(&running_jobs_mu)
	defer sync.mutex_unlock(&running_jobs_mu)
	jobs_shutdown = true
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
