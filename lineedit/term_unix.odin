#+build linux, darwin, freebsd, netbsd, openbsd
package lineedit

import "core:c"
import "core:os"
import "core:sys/posix"

Winsize :: struct {
	row:    u16,
	col:    u16,
	xpixel: u16,
	ypixel: u16,
}

File_Transport :: struct {
	input:     ^os.File,
	output:    ^os.File,
	tty:       bool,
	entered:   bool,
	saved:     posix.termios,
	has_saved: bool,
}

file_transport_make :: proc(input, output: ^os.File) -> Transport {
	ft := new(File_Transport)
	ft.input = input
	ft.output = output
	ft.tty = os.is_tty(input)
	return Transport {
		ctx = ft,
		read = file_read,
		write = file_write,
		size = file_size,
		enter_raw = file_enter_raw,
		leave_raw = file_leave_raw,
		destroy = file_destroy,
	}
}

file_read :: proc(ctx: rawptr, buf: []u8, timeout_ms: int) -> (n: int, timed_out: bool, eof: bool) {
	ft := cast(^File_Transport)ctx
	if timeout_ms >= 0 {
		fds := [1]posix.pollfd{{fd = posix.FD(os.fd(ft.input)), events = {.IN}}}
		res := posix.poll(&fds[0], 1, c.int(timeout_ms))
		if res <= 0 {
			return 0, true, false
		}
	}
	got, _ := os.read(ft.input, buf)
	if got <= 0 {
		return 0, false, true
	}
	return got, false, false
}

file_write :: proc(ctx: rawptr, data: []u8) -> bool {
	ft := cast(^File_Transport)ctx
	written := 0
	for written < len(data) {
		n, err := os.write(ft.output, data[written:])
		if err != nil || n <= 0 {
			return false
		}
		written += n
	}
	return true
}

file_size :: proc(ctx: rawptr) -> (cols, rows: int) {
	ft := cast(^File_Transport)ctx
	return file_platform_size(ft)
}

file_enter_raw :: proc(ctx: rawptr) -> bool {
	ft := cast(^File_Transport)ctx
	if !ft.tty {
		return false
	}
	if ft.entered {
		return true
	}

	fd := posix.FD(os.fd(ft.input))
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
	ft.saved = attrs
	ft.has_saved = true
	ft.entered = true
	return true
}

file_leave_raw :: proc(ctx: rawptr) {
	ft := cast(^File_Transport)ctx
	if ft.has_saved {
		fd := posix.FD(os.fd(ft.input))
		posix.tcsetattr(fd, .TCSANOW, &ft.saved)
		ft.has_saved = false
	}
	ft.entered = false
}

file_destroy :: proc(ctx: rawptr) {
	ft := cast(^File_Transport)ctx
	file_leave_raw(ctx)
	free(ft)
}
