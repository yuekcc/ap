#+build linux, darwin, freebsd, netbsd, openbsd
package aptui

import "core:c"
import "core:os"
import "core:sys/posix"

Term_Raw_State :: struct {
	attrs: posix.termios,
	has:   bool,
}

Winsize :: struct {
	row:    u16,
	col:    u16,
	xpixel: u16,
	ypixel: u16,
}

term_platform_raw_enable :: proc(t: ^Term) -> bool {
	fd := posix.FD(os.fd(t.input))
	attrs: posix.termios
	if posix.tcgetattr(fd, &attrs) != .OK {
		return false
	}
	raw := attrs
	raw.c_iflag &~= {.IGNBRK, .BRKINT, .PARMRK, .ISTRIP, .INLCR, .IGNCR, .ICRNL, .IXON}
	raw.c_oflag &~= {.OPOST}
	raw.c_lflag &~= {.ECHO, .ECHONL, .ICANON, .ISIG, .IEXTEN}
	raw.c_cflag |= {.CS8}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0
	if posix.tcsetattr(fd, .TCSANOW, &raw) != .OK {
		return false
	}
	t.saved.attrs = attrs
	t.saved.has = true
	return true
}

term_platform_raw_restore :: proc(t: ^Term) {
	if !t.saved.has {
		return
	}
	fd := posix.FD(os.fd(t.input))
	posix.tcsetattr(fd, .TCSANOW, &t.saved.attrs)
	t.saved.has = false
}

term_platform_wait_readable :: proc(t: ^Term, timeout_ms: int) -> bool {
	fds := [1]posix.pollfd{{fd = posix.FD(os.fd(t.input)), events = {.IN}}}
	res := posix.poll(&fds[0], 1, c.int(timeout_ms))
	return res > 0
}
