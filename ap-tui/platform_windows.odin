#+build windows
package tui

import "../ap/platform"
import "core:os"
import win32 "core:sys/windows"

setup_console :: proc() {
	platform.setup_console()
}

normalize_args :: proc(args: []string) -> []string {
	return platform.normalize_args(args)
}

// 管道两端默认都可继承；stdin 的写端、stdout/stderr 的读端如果被 ap 继承，
// ap 读 stdin 时永远等不到 EOF（它自己还握着一份写端）。这里清掉继承标志。
mark_non_inheritable :: proc(file: ^os.File) {
	if file == nil {
		return
	}
	win32.SetHandleInformation(win32.HANDLE(os.fd(file)), win32.HANDLE_FLAG_INHERIT, 0)
}
