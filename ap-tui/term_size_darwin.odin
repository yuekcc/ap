#+build darwin
package aptui

import "core:c"
import "core:os"
import "core:sys/darwin"

term_platform_size :: proc(t: ^Term) -> (cols, rows: int) {
	ws: Winsize
	res := darwin.syscall_ioctl(c.int(os.fd(t.input)), darwin.TIOCGWINSZ, &ws)
	if res != 0 || ws.col == 0 {
		return 0, 0
	}
	return int(ws.col), int(ws.row)
}
