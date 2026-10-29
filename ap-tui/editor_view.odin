package aptui

import client "../ap-core/client"

import "core:fmt"
import "core:os"
import "core:strings"

PREFIX :: "› "
CONT_PREFIX :: "  "

editor_prefix_width :: proc() -> int {
	return string_width(PREFIX)
}

// 编辑块的重绘状态：cur_row 是上次画完时光标相对块左上角的位置。
Editor_View :: struct {
	out:     ^os.File,
	color:   bool,
	drawn:   int,
	cur_row: int,
}

editor_view_draw :: proc(v: ^Editor_View, e: ^Editor, cols, term_rows: int) {
	prefix_width := editor_prefix_width()
	l := layout(e.buffer[:], e.cursor, cols, prefix_width)
	defer delete(l.rows)

	total := len(l.rows)
	capacity := term_rows - 1
	if capacity < 1 {
		capacity = 1
	}
	top, content_cap := layout_window(total, l.cursor_row, capacity)
	l.top = top
	header := top > 0 && capacity > 1
	end := min(top + content_cap, total)

	b := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&b)

	// 回到块首，再清掉块及以下所有内容。
	strings.write_byte(&b, '\r')
	if v.cur_row > 0 {
		fmt.sbprintf(&b, "\x1b[%dA", v.cur_row)
	}
	strings.write_string(&b, "\x1b[0J")

	drawn := 0
	cursor_drawn := 0
	if header {
		strings.write_string(&b, CONT_PREFIX)
		strings.write_string(&b, "…")
		drawn = 1
	}
	for idx := top; idx < end; idx += 1 {
		if drawn > 0 {
			// 用 \r\n：\r 会清掉终端的 pending-wrap，恰好整行宽时不会多空一行。
			strings.write_string(&b, "\r\n")
		}
		if idx == 0 {
			if v.color {
				strings.write_string(&b, BOLD + CYAN)
			}
			strings.write_string(&b, PREFIX)
			if v.color {
				strings.write_string(&b, RESET)
			}
		} else {
			strings.write_string(&b, CONT_PREFIX)
		}
		row := l.rows[idx]
		strings.write_string(&b, string(e.buffer[row.start:row.start + row.len]))
		if idx == l.cursor_row {
			cursor_drawn = drawn
		}
		drawn += 1
	}
	if drawn == 0 {
		strings.write_string(&b, PREFIX)
		drawn = 1
	}

	bottom := drawn - 1
	strings.write_byte(&b, '\r')
	if bottom > cursor_drawn {
		fmt.sbprintf(&b, "\x1b[%dA", bottom - cursor_drawn)
	}
	if l.cursor_col > 0 {
		fmt.sbprintf(&b, "\x1b[%dC", l.cursor_col)
	}

	_ = client.write_all(v.out, transmute([]byte)strings.to_string(b))
	v.drawn = drawn
	v.cur_row = cursor_drawn
}

// 提交：把光标移到块底下一行，缓冲区文本留在屏幕上。
editor_view_finish :: proc(v: ^Editor_View) {
	b := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&b)

	strings.write_byte(&b, '\r')
	down := v.drawn - 1 - v.cur_row
	if down > 0 {
		fmt.sbprintf(&b, "\x1b[%dB", down)
	}
	strings.write_byte(&b, '\n')
	_ = client.write_all(v.out, transmute([]byte)strings.to_string(b))
}

// 放弃输入（Ctrl+C 退出、EOF）：清掉整个编辑块，把光标留在块首。
editor_view_abort :: proc(v: ^Editor_View) {
	b := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&b)

	strings.write_byte(&b, '\r')
	if v.cur_row > 0 {
		fmt.sbprintf(&b, "\x1b[%dA", v.cur_row)
	}
	strings.write_string(&b, "\x1b[0J")
	_ = client.write_all(v.out, transmute([]byte)strings.to_string(b))
}
