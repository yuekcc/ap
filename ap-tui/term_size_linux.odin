#+build linux
package aptui

import "core:os"
import "core:sys/linux"

term_platform_size :: proc(t: ^Term) -> (cols, rows: int) {
	ws: Winsize
	res := linux.ioctl(linux.Fd(os.fd(t.input)), linux.TIOCGWINSZ, uintptr(&ws))
	if res == ~uintptr(0) || ws.col == 0 {
		return 0, 0
	}
	return int(ws.col), int(ws.row)
}
