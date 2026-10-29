#+build windows
package aptui

import "core:os"
import "core:sys/windows"

Term_Raw_State :: struct {
	in_mode:  windows.DWORD,
	out_mode: windows.DWORD,
	has_in:   bool,
	has_out:  bool,
}

term_platform_raw_enable :: proc(t: ^Term) -> bool {
	in_handle := windows.HANDLE(os.fd(t.input))
	out_handle := windows.HANDLE(os.fd(t.output))

	in_mode: windows.DWORD
	if !windows.GetConsoleMode(in_handle, &in_mode) {
		return false
	}
	new_in := (in_mode &
		~(
			windows.ENABLE_LINE_INPUT |
			windows.ENABLE_ECHO_INPUT |
			windows.ENABLE_PROCESSED_INPUT |
			windows.ENABLE_WINDOW_INPUT // 只收字符，避免 resize/mouse 记录混进读取
		)) | windows.ENABLE_VIRTUAL_TERMINAL_INPUT
	if !windows.SetConsoleMode(in_handle, new_in) {
		return false
	}
	t.saved.in_mode = in_mode
	t.saved.has_in = true

	// core:terminal 通常会先设置 VT 输出，但 ap-tui 不假设初始化顺序，自己再确认一次。
	out_mode: windows.DWORD
	if windows.GetConsoleMode(out_handle, &out_mode) {
		new_out := out_mode |
			windows.ENABLE_PROCESSED_OUTPUT |
			windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING
		if windows.SetConsoleMode(out_handle, new_out) {
			t.saved.out_mode = out_mode
			t.saved.has_out = true
		}
	}
	return true
}

term_platform_raw_restore :: proc(t: ^Term) {
	if t.saved.has_in {
		windows.SetConsoleMode(windows.HANDLE(os.fd(t.input)), t.saved.in_mode)
		t.saved.has_in = false
	}
	if t.saved.has_out {
		windows.SetConsoleMode(windows.HANDLE(os.fd(t.output)), t.saved.out_mode)
		t.saved.has_out = false
	}
}

term_platform_size :: proc(t: ^Term) -> (cols, rows: int) {
	info: windows.CONSOLE_SCREEN_BUFFER_INFO
	handle := windows.HANDLE(os.fd(t.output))
	if !windows.GetConsoleScreenBufferInfo(handle, &info) {
		return 0, 0
	}
	cols = int(info.srWindow.Right-info.srWindow.Left) + 1
	rows = int(info.srWindow.Bottom-info.srWindow.Top) + 1
	return
}

term_platform_wait_readable :: proc(t: ^Term, timeout_ms: int) -> bool {
	handle := windows.HANDLE(os.fd(t.input))
	res := windows.WaitForSingleObject(handle, windows.DWORD(timeout_ms))
	return res == windows.WAIT_OBJECT_0
}
