#+build windows
package platform

import "core:strings"
import "core:unicode/utf8"
import win32 "core:sys/windows"

foreign import k32_local "system:Kernel32.lib"

@(default_calling_convention="system")
foreign k32_local {
	GetLocalTime :: proc(lpSystemTime: ^win32.SYSTEMTIME) ---
}

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

// Windows CRT 用 ANSI 代码页（ACP，不是控制台代码页）把 UTF-16 命令行转成 argv。
// 系统未启用「Beta: 使用 Unicode UTF-8」时，os.args 里的中文是 GBK 等本地编码的字节，
// 当成 UTF-8 使用会一路变成非法字符串。因此 ACP 不是 UTF-8 时改用宽字符命令行重建参数。
normalize_args :: proc(args: []string) -> []string {
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

// 宽字符命令行不可用时的退化路径：只转换不合法的 UTF-8 参数。
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

local_now :: proc() -> (year, month, day, hour, minute, second: int) {
	st: win32.SYSTEMTIME
	GetLocalTime(&st)
	return int(st.year), int(st.month), int(st.day), int(st.hour), int(st.minute), int(st.second)
}
