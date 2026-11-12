#+build freebsd
package lineedit

import "core:os"
import "core:sys/freebsd"

file_platform_size :: proc(ft: ^File_Transport) -> (cols, rows: int) {
	ws: Winsize
	res, err := freebsd.ioctl(freebsd.Fd(os.fd(ft.input)), freebsd.TIOCGWINSZ, uintptr(&ws))
	if res != 0 || err != nil || ws.col == 0 {
		return 0, 0
	}
	return int(ws.col), int(ws.row)
}
