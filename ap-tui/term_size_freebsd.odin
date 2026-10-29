#+build freebsd
package aptui

import "core:os"
import "core:sys/freebsd"

term_platform_size :: proc(t: ^Term) -> (cols, rows: int) {
	ws: Winsize
	res, err := freebsd.ioctl(freebsd.Fd(os.fd(t.input)), freebsd.TIOCGWINSZ, uintptr(&ws))
	if res != 0 || err != nil || ws.col == 0 {
		return 0, 0
	}
	return int(ws.col), int(ws.row)
}
