#+build windows
package ap

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
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

// Windows CRT 用 ANSI 代码页（ACP，不是控制台代码页）把 UTF-16 命令行转成 argv。
// 系统未启用「Beta: 使用 Unicode UTF-8」时，os.args 里的中文是 GBK 等本地编码的字节，
// 当成 UTF-8 使用会一路变成非法字符串（transcript 里的 content 会被写成空）。
// 因此 ACP 不是 UTF-8 时改用宽字符命令行重建参数，保证进入 parse_args 的文本是 UTF-8。
normalize_cli_args :: proc(args: []string) -> []string {
	if win32.GetACP() == win32.CODEPAGE.UTF8 {
		return args
	}
	if wide_args, ok := wide_cli_args(); ok && len(wide_args) == len(args) {
		return wide_args
	}
	out := make([]string, len(args))
	for arg, i in args {
		out[i] = acp_arg_to_utf8(arg)
	}
	return out
}

wide_cli_args :: proc() -> ([]string, bool) {
	cmd_line := win32.GetCommandLineW()
	if cmd_line == nil {
		return nil, false
	}
	argc: win32.c_int
	argv := win32.CommandLineToArgvW(cmd_line, &argc)
	if argv == nil || argc <= 0 {
		return nil, false
	}
	defer win32.LocalFree(rawptr(argv))

	out := make([]string, int(argc))
	for arg_w, i in argv[:int(argc)] {
		converted, err := win32.wstring_to_utf8(arg_w, -1)
		if err != nil {
			return nil, false
		}
		out[i] = converted
	}
	return out, true
}

// 宽字符命令行不可用时的退化路径：只转换不合法的 UTF-8 参数，
// 纯 ASCII 与已经是 UTF-8 的参数保持原样。
acp_arg_to_utf8 :: proc(arg: string) -> string {
	if utf8.valid_string(arg) {
		return arg
	}
	page := win32.GetACP()
	wide_len := win32.MultiByteToWideChar(
		u32(page),
		win32.MB_ERR_INVALID_CHARS,
		raw_data(arg),
		win32.c_int(len(arg)),
		nil,
		0,
	)
	if wide_len <= 0 {
		return arg
	}
	wide := make([]u16, int(wide_len))
	defer delete(wide)
	written := win32.MultiByteToWideChar(
		u32(page),
		win32.MB_ERR_INVALID_CHARS,
		raw_data(arg),
		win32.c_int(len(arg)),
		raw_data(wide),
		wide_len,
	)
	if written <= 0 {
		return arg
	}
	return win32.utf16_to_utf8(wide[:int(written)]) or_else arg
}
