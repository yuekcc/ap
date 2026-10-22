#+build windows
package tui

import "core:os"
import "core:strings"
import win32 "core:sys/windows"

real_path :: proc(path: string) -> (string, Error) {
	wpath := win32.utf8_to_wstring(path, context.temp_allocator)
	handle := win32.CreateFileW(
		wpath,
		win32.FILE_READ_ATTRIBUTES,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_FLAG_BACKUP_SEMANTICS,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE {
		return "", errorf("cannot open path for realpath: %s", path)
	}
	defer win32.CloseHandle(handle)

	n := win32.GetFinalPathNameByHandleW(handle, nil, 0, win32.VOLUME_NAME_DOS)
	if n == 0 {
		return "", errorf("GetFinalPathNameByHandleW failed: %s", path)
	}
	buf := make([]u16, n + 1, context.temp_allocator)
	n = win32.GetFinalPathNameByHandleW(handle, cstring16(raw_data(buf)), u32(len(buf)), win32.VOLUME_NAME_DOS)
	if n == 0 {
		return "", errorf("GetFinalPathNameByHandleW failed: %s", path)
	}
	s := win32.utf16_to_utf8(buf[:n], context.temp_allocator) or_else ""
	unc_prefix := `\\?\UNC\`
	win_prefix := `\\?\`
	switch {
	case strings.has_prefix(s, unc_prefix):
		s = strings.concatenate([]string{`\\`, s[len(unc_prefix):]})
	case strings.has_prefix(s, win_prefix):
		s = s[4:]
	}
	return s, ok_error()
}

setup_console :: proc() {
	win32.SetConsoleCP(win32.CODEPAGE.UTF8)
	win32.SetConsoleOutputCP(win32.CODEPAGE.UTF8)
}

// 管道两端默认都可继承；stdin 的写端、stdout/stderr 的读端如果被 ap 继承，
// ap 读 stdin 时永远等不到 EOF（它自己还握着一份写端）。这里清掉继承标志。
mark_non_inheritable :: proc(file: ^os.File) {
	if file == nil {
		return
	}
	win32.SetHandleInformation(win32.HANDLE(os.fd(file)), win32.HANDLE_FLAG_INHERIT, 0)
}

// 与 ap 相同：ACP 不是 UTF-8 时用宽字符命令行重建参数。
normalize_args :: proc(args: []string) -> []string {
	if win32.GetACP() == win32.CODEPAGE.UTF8 {
		return args
	}
	cmd_line := win32.GetCommandLineW()
	if cmd_line == nil {
		return args
	}
	argc: win32.c_int
	argv := win32.CommandLineToArgvW(cmd_line, &argc)
	if argv == nil || argc <= 0 {
		return args
	}
	defer win32.LocalFree(rawptr(argv))

	out := make([]string, int(argc))
	for arg_w, i in argv[:int(argc)] {
		converted, err := win32.wstring_to_utf8(arg_w, -1)
		if err != nil {
			return args
		}
		out[i] = converted
	}
	return out
}
