package protocol

import "core:strings"

// 把管道里的字节流切成完整行；一行 stdout 就是一个 stream-json 事件。
// 每次 feed 后压实缓冲，避免长 turn 的无界增长。
Line_Reader :: struct {
	buf:      [dynamic]u8,
	start:    int,
	callback: proc(user: rawptr, line: string),
	user:     rawptr,
}

line_reader_feed :: proc(lr: ^Line_Reader, chunk: []byte) {
	if len(chunk) > 0 {
		append(&lr.buf, ..chunk)
	}
	for {
		view := transmute(string)lr.buf[lr.start:]
		idx := strings.index_byte(view, '\n')
		if idx < 0 {
			break
		}
		line := view[:idx]
		lr.callback(lr.user, line)
		lr.start += idx + 1
	}
	if lr.start > 0 {
		remaining := len(lr.buf) - lr.start
		if remaining > 0 {
			copy(lr.buf[:], lr.buf[lr.start:])
		}
		resize(&lr.buf, remaining)
		lr.start = 0
	}
}

// 进程退出时把最后一截没有换行结尾的内容也交出去。
line_reader_flush :: proc(lr: ^Line_Reader) {
	if lr.start < len(lr.buf) {
		lr.callback(lr.user, transmute(string)lr.buf[lr.start:])
	}
	resize(&lr.buf, 0)
	lr.start = 0
}
