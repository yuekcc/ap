#+build darwin
package lineedit

import "core:c"
import "core:os"
import "core:sys/darwin"

file_platform_size :: proc(ft: ^File_Transport) -> (cols, rows: int) {
	ws: Winsize
	res := darwin.syscall_ioctl(c.int(os.fd(ft.input)), darwin.TIOCGWINSZ, &ws)
	if res != 0 || ws.col == 0 {
		return 0, 0
	}
	return int(ws.col), int(ws.row)
}
