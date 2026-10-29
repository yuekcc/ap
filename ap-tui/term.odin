package aptui

import client "../ap-core/client"

import "core:os"
import "core:time"

// Term 是 raw mode 的门面：进入/退出、Kitty 协议探测、尺寸、带超时的分片读取。
// 平台相关的部分在 term_unix.odin / term_windows.odin。
Term :: struct {
	input:       ^os.File,
	output:      ^os.File,
	entered:     bool,
	probed:      bool,
	kitty:       bool,
	warned:      bool,
	pending:     [1024]u8,
	pending_len: int,
	saved:       Term_Raw_State,
}

KITTY_PROBE_MS :: 120

term_init :: proc(t: ^Term, input, output: ^os.File) {
	t.input = input
	t.output = output
	t.pending_len = 0
	t.entered = false
	t.probed = false
	t.kitty = false
	t.warned = false
}

term_write :: proc(t: ^Term, text: string) {
	if len(text) == 0 {
		return
	}
	_ = client.write_all(t.output, transmute([]byte)text)
}

term_enter :: proc(t: ^Term) -> bool {
	if t == nil {
		return false
	}
	if t.entered {
		return true
	}
	if !term_platform_raw_enable(t) {
		return false
	}
	t.entered = true
	term_write(t, "\x1b[>1u") // push kitty flags = 1 (disambiguate)
	term_write(t, "\x1b[?2004h") // bracketed paste
	if !t.probed {
		t.probed = true
		t.kitty = term_probe_kitty(t)
	}
	return true
}

// 幂等。恢复 termios / console mode，并弹掉 kitty flags 与 bracketed paste。
term_leave :: proc(t: ^Term) {
	if t == nil || !t.entered {
		return
	}
	term_write(t, "\x1b[<u")
	term_write(t, "\x1b[?2004l")
	term_platform_raw_restore(t)
	t.entered = false
}

term_probe_kitty :: proc(t: ^Term) -> bool {
	term_write(t, "\x1b[?u")
	start := time.now()
	for {
		elapsed := i64(time.duration_milliseconds(time.since(start)))
		remaining := i64(KITTY_PROBE_MS) - elapsed
		if remaining <= 0 {
			break
		}
		if !term_platform_wait_readable(t, int(remaining)) {
			break
		}
		buf: [256]u8
		n, err := os.read(t.input, buf[:])
		if n <= 0 || err != nil {
			break
		}
		term_push_pending(t, buf[:n])
		complete, kitty := term_pending_kitty(t)
		if complete {
			return kitty
		}
	}
	return false
}

term_push_pending :: proc(t: ^Term, data: []u8) {
	space := len(t.pending) - t.pending_len
	n := min(space, len(data))
	if n <= 0 {
		return
	}
	copy(t.pending[t.pending_len:], data[:n])
	t.pending_len += n
}

// 在启动探测阶段读到的字节里找 CSI ? <flags> u。
// complete=false 表示还没收全（可能跨分片），继续等。
term_pending_kitty :: proc(t: ^Term) -> (complete: bool, kitty: bool) {
	i := 0
	for i + 2 < t.pending_len {
		if t.pending[i] != 0x1b || t.pending[i + 1] != '[' || t.pending[i + 2] != '?' {
			i += 1
			continue
		}
		j := i + 3
		flags := 0
		have_digit := false
		for j < t.pending_len && t.pending[j] >= '0' && t.pending[j] <= '9' {
			flags = flags * 10 + int(t.pending[j] - '0')
			have_digit = true
			j += 1
		}
		if j >= t.pending_len {
			return false, false
		}
		if have_digit && t.pending[j] == 'u' {
			return true, flags & 1 != 0
		}
		i += 1
	}
	return false, false
}

term_size :: proc(t: ^Term) -> (cols, rows: int) {
	if t == nil {
		return 80, 24
	}
	cols, rows = term_platform_size(t)
	if cols <= 0 {
		cols = 80
	}
	if rows <= 0 {
		rows = 24
	}
	return
}

// timeout_ms < 0 表示阻塞读取。返回 timed_out 让上层决定是否 flush 半截序列/粘贴。
term_read_chunk :: proc(t: ^Term, buf: []u8, timeout_ms: int) -> (n: int, timed_out: bool, eof: bool) {
	if t.pending_len > 0 {
		n = min(len(buf), t.pending_len)
		copy(buf[:n], t.pending[:n])
		remaining := t.pending_len - n
		if remaining > 0 {
			copy(t.pending[:remaining], t.pending[n:t.pending_len])
		}
		t.pending_len = remaining
		return n, false, false
	}

	if timeout_ms >= 0 && !term_platform_wait_readable(t, timeout_ms) {
		return 0, true, false
	}

	got, err := os.read(t.input, buf)
	if err != nil && got <= 0 {
		return 0, false, true
	}
	return got, false, false
}
