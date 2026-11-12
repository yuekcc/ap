#+build windows
package lineedit

import "core:os"
import "core:sys/windows"

File_Transport :: struct {
	input:     ^os.File,
	output:    ^os.File,
	tty:       bool,
	entered:   bool,
	saved_in:  windows.DWORD,
	saved_out: windows.DWORD,
	has_in:    bool,
	has_out:   bool,
}

file_transport_make :: proc(input, output: ^os.File) -> Transport {
	ft := new(File_Transport)
	ft.input = input
	ft.output = output
	ft.tty = os.is_tty(input)
	return Transport {
		ctx = ft,
		read = file_read,
		write = file_write,
		size = file_size,
		enter_raw = file_enter_raw,
		leave_raw = file_leave_raw,
		destroy = file_destroy,
	}
}

file_read :: proc(ctx: rawptr, buf: []u8, timeout_ms: int) -> (n: int, timed_out: bool, eof: bool) {
	ft := cast(^File_Transport)ctx
	if timeout_ms >= 0 {
		handle := windows.HANDLE(os.fd(ft.input))
		res := windows.WaitForSingleObject(handle, windows.DWORD(timeout_ms))
		if res != windows.WAIT_OBJECT_0 {
			return 0, true, false
		}
	}
	got, _ := os.read(ft.input, buf)
	if got <= 0 {
		return 0, false, true
	}
	return got, false, false
}

file_write :: proc(ctx: rawptr, data: []u8) -> bool {
	ft := cast(^File_Transport)ctx
	written := 0
	for written < len(data) {
		n, err := os.write(ft.output, data[written:])
		if err != nil || n <= 0 {
			return false
		}
		written += n
	}
	return true
}

file_size :: proc(ctx: rawptr) -> (cols, rows: int) {
	ft := cast(^File_Transport)ctx
	info: windows.CONSOLE_SCREEN_BUFFER_INFO
	handle := windows.HANDLE(os.fd(ft.output))
	if !windows.GetConsoleScreenBufferInfo(handle, &info) {
		return 0, 0
	}
	cols = int(info.srWindow.Right-info.srWindow.Left) + 1
	rows = int(info.srWindow.Bottom-info.srWindow.Top) + 1
	return
}

file_enter_raw :: proc(ctx: rawptr) -> bool {
	ft := cast(^File_Transport)ctx
	if !ft.tty || ft.entered {
		return ft.entered
	}

	in_handle := windows.HANDLE(os.fd(ft.input))
	out_handle := windows.HANDLE(os.fd(ft.output))

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
	ft.saved_in = in_mode
	ft.has_in = true

	out_mode: windows.DWORD
	if windows.GetConsoleMode(out_handle, &out_mode) {
		new_out := out_mode |
			windows.ENABLE_PROCESSED_OUTPUT |
			windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING
		if windows.SetConsoleMode(out_handle, new_out) {
			ft.saved_out = out_mode
			ft.has_out = true
		}
	}

	ft.entered = true
	return true
}

file_leave_raw :: proc(ctx: rawptr) {
	ft := cast(^File_Transport)ctx
	if ft.has_in {
		windows.SetConsoleMode(windows.HANDLE(os.fd(ft.input)), ft.saved_in)
		ft.has_in = false
	}
	if ft.has_out {
		windows.SetConsoleMode(windows.HANDLE(os.fd(ft.output)), ft.saved_out)
		ft.has_out = false
	}
	ft.entered = false
}

file_destroy :: proc(ctx: rawptr) {
	ft := cast(^File_Transport)ctx
	file_leave_raw(ctx)
	free(ft)
}
