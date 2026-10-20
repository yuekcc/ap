#+build windows
package ap

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"
import win32 "core:sys/windows"

foreign import k32 "system:Kernel32.lib"

@(default_calling_convention="system")
foreign k32 {
	CreateJobObjectW          :: proc(attrs: rawptr, name: win32.LPCWSTR) -> win32.HANDLE ---
	AssignProcessToJobObject  :: proc(job, process: win32.HANDLE) -> win32.BOOL ---
	TerminateJobObject        :: proc(job: win32.HANDLE, exit_code: u32) -> win32.BOOL ---
	CloseHandle               :: proc(handle: win32.HANDLE) -> win32.BOOL ---
	GetLocalTime              :: proc(lpSystemTime: ^win32.SYSTEMTIME) ---
}

local_now :: proc() -> (year, month, day, hour, minute, second: int) {
	st: win32.SYSTEMTIME
	GetLocalTime(&st)
	return int(st.year), int(st.month), int(st.day), int(st.hour), int(st.minute), int(st.second)
}

running_jobs: [dynamic]Job_Handle

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
	for existing in running_jobs {
		if existing == job {
			return
		}
	}
	append(&running_jobs, job)
}

cleanup_jobs :: proc() {
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

g_cancel_token: ^Cancel_Token
g_signal_code: i32
g_signal_tick: time.Tick

ctrl_handler :: proc "system" (ctrl_type: win32.DWORD) -> win32.BOOL {
	if ctrl_type != win32.CTRL_C_EVENT && ctrl_type != win32.CTRL_BREAK_EVENT {
		return false
	}
	code: i32 = 130
	if sync.atomic_load(&g_signal_code) != 0 {
		// 1s 内第二次 Ctrl+C：直接退出，不再写事件。
		if time.tick_since(g_signal_tick) < time.Second {
			os.exit(int(code))
		}
	}
	sync.atomic_store(&g_signal_code, code)
	g_signal_tick = time.tick_now()
	if token := g_cancel_token; token != nil {
		sync.atomic_store(&token.value, 1)
	}
	return true
}

install_signal_handlers :: proc(token: ^Cancel_Token) {
	g_cancel_token = token
	win32.SetConsoleCtrlHandler(ctrl_handler, true)
}

signal_exit_code :: proc() -> int {
	code := sync.atomic_load(&g_signal_code)
	return int(code)
}

setup_console_utf8 :: proc() {
	win32.SetConsoleCP(win32.CODEPAGE.UTF8)
	win32.SetConsoleOutputCP(win32.CODEPAGE.UTF8)
}
