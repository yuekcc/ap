#+build linux
package lineedit

import "core:os"
import "core:sys/linux"

file_platform_size :: proc(ft: ^File_Transport) -> (cols, rows: int) {
	ws: Winsize
	res := linux.ioctl(linux.Fd(os.fd(ft.input)), linux.TIOCGWINSZ, uintptr(&ws))
	if res == ~uintptr(0) || ws.col == 0 {
		return 0, 0
	}
	return int(ws.col), int(ws.row)
}
