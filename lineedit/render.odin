package lineedit

import "core:unicode/utf8"

Render_Config :: struct {
	prompt:       string,
	prefix_width: int,
	color:         bool,
	mask:          bool,
	hint:          string,
	menu:          []Completion,
	menu_selected: int,
}

// Renderer 只记住上一次画了多少行、光标在第几行，用来把新帧画在旧帧上面。
Renderer :: struct {
	drawn:      int,
	cursor_row: int,
}

render_init :: proc(r: ^Renderer) {
	r^ = {}
}

render_frame :: proc(r: ^Renderer, out: ^[dynamic]u8, e: ^Editor, cfg: Render_Config, cols, rows: int) {
	buf := e.buffer[:]
	cur := e.cursor

	masked: [dynamic]u8
	defer delete(masked)
	if cfg.mask {
		masked, cur = mask_buffer(buf, cur)
		buf = masked[:]
	}

	l := layout(buf, cur, cols, cfg.prefix_width)
	defer layout_destroy(&l)

	menu_total := len(cfg.menu)
	menu_budget := 0
	if menu_total > 0 && rows > 2 && cols > 2 {
		// 菜单最多占一半，给输入块留出空间。
		menu_max := max(1, (rows - 1) / 2)
		menu_budget = min(menu_total, menu_max)
	}

	capacity := rows - 1 - menu_budget
	if capacity < 1 {
		capacity = 1
	}
	top, content_cap := layout_window(len(l.rows), l.cursor_row, capacity)
	header := top > 0 && capacity > 1
	end := min(top + content_cap, len(l.rows))

	// 回到块首：光标在上一帧的 cursor_row，先上移再清到屏幕末尾。
	append(out, '\r')
	if r.cursor_row > 0 {
		render_append_csi(out, 'A', r.cursor_row)
	}
	render_append_string(out, "\x1b[0J")

	drawn := 0
	cursor_drawn := 0
	if header {
		render_write_spaces(out, cfg.prefix_width)
		render_append_string(out, "…")
		drawn = 1
	}

	for idx := top; idx < end; idx += 1 {
		if drawn > 0 {
			// raw 模式关闭 OPOST，换行必须自带 \r。
			render_append_string(out, "\r\n")
		}
		if idx == 0 {
			render_append_string(out, cfg.prompt)
		} else {
			render_write_spaces(out, cfg.prefix_width)
		}
		row := l.rows[idx]
		render_write_text(out, string(buf[row.start:row.start + row.len]))
		if idx == l.cursor_row {
			cursor_drawn = drawn
		}
		drawn += 1
	}

	// 补全菜单画在输入块下方，每项一行；选中项用 "> " 标记并加反色。
	if menu_budget > 0 {
		menu_start, menu_end := menu_window(menu_total, cfg.menu_selected, menu_budget)
		for i := menu_start; i < menu_end; i += 1 {
			if drawn > 0 {
				render_append_string(out, "\r\n")
			}
			item := cfg.menu[i]
			selected := i == cfg.menu_selected
			if selected {
				render_append_string(out, "> ")
			} else {
				render_append_string(out, "  ")
			}

			remaining := cols - 2
			if remaining < 0 {
				remaining = 0
			}
			if cfg.color && selected {
				render_append_string(out, "\x1b[7m")
			}
			render_write_text_limited(out, item.text, remaining)
			if cfg.color && selected {
				render_append_string(out, "\x1b[0m")
			}

			if len(item.description) > 0 {
				used := 2 + display_width(item.text)
				desc_remaining := cols - used - 2
				if desc_remaining > 0 {
					render_append_string(out, "  ")
					if cfg.color {
						render_append_string(out, "\x1b[2m")
					}
					render_write_text_limited(out, item.description, desc_remaining)
					if cfg.color {
						render_append_string(out, "\x1b[0m")
					}
				}
			}
			drawn += 1
		}
	}

	// hints 画在最后一条逻辑行的右侧，不参与布局，也不移动光标。
	if cfg.hint != "" && !cfg.mask && menu_budget == 0 && end == len(l.rows) {
		last := l.rows[end - 1]
		used := cfg.prefix_width + display_width(string(buf[last.start:last.start + last.len]))
		remaining := cols - used
		if remaining > 0 {
			if cfg.color {
				render_append_string(out, "\x1b[2m")
			}
			render_write_text_limited(out, cfg.hint, remaining)
			if cfg.color {
				render_append_string(out, "\x1b[0m")
			}
		}
	}

	if drawn == 0 {
		render_append_string(out, cfg.prompt)
		drawn = 1
	}

	bottom := drawn - 1
	append(out, '\r')
	if bottom > cursor_drawn {
		render_append_csi(out, 'A', bottom - cursor_drawn)
	}
	if l.cursor_col > 0 {
		render_append_csi(out, 'C', l.cursor_col)
	}

	r.drawn = drawn
	r.cursor_row = cursor_drawn
}

// 提交：把光标移到块底下一行并换行，缓冲区内容留在屏幕上。
render_finish :: proc(r: ^Renderer, out: ^[dynamic]u8) {
	append(out, '\r')
	down := r.drawn - 1 - r.cursor_row
	if down > 0 {
		render_append_csi(out, 'B', down)
	}
	render_append_string(out, "\r\n")
	r^ = {}
}

// 放弃输入：清掉整个编辑块，把光标留在块首。
render_abort :: proc(r: ^Renderer, out: ^[dynamic]u8) {
	append(out, '\r')
	if r.cursor_row > 0 {
		render_append_csi(out, 'A', r.cursor_row)
	}
	render_append_string(out, "\x1b[0J")
	r^ = {}
}

// 补全菜单的可见窗口。selected < 0 时从第一项开始；否则尽量把选中项放在窗口中间。
menu_window :: proc(total, selected, budget: int) -> (start, end: int) {
	if total <= budget {
		return 0, total
	}
	start = 0
	if selected >= 0 {
		start = selected - budget / 2
		if start < 0 {
			start = 0
		}
		if start + budget > total {
			start = total - budget
		}
	}
	return start, start + budget
}

// mask 模式按 grapheme 输出一个 '*'，换行保留。光标偏移也映射到掩码后的缓冲区。
mask_buffer :: proc(buf: []u8, cursor: int) -> (masked: [dynamic]u8, masked_cursor: int) {
	masked = make([dynamic]u8, 0, len(buf))
	it := utf8.decode_grapheme_iterator_make(string(buf))
	for {
		text, g, ok := utf8.decode_grapheme_iterate(&it)
		if !ok || len(text) == 0 {
			break
		}
		if text == "\n" {
			append(&masked, '\n')
		} else {
			append(&masked, '*')
		}
		end := g.byte_index + len(text)
		if end <= cursor {
			masked_cursor = len(masked)
		}
	}
	return
}

render_write_spaces :: proc(out: ^[dynamic]u8, n: int) {
	for _ in 0 ..< n {
		append(out, ' ')
	}
}

// 按 grapheme 写一行内容，并把 tab 展开成与 layout 一致的 8 列制表位空格。
render_write_text :: proc(out: ^[dynamic]u8, text: string) {
	it := utf8.decode_grapheme_iterator_make(text)
	col := 0
	for {
		piece, g, ok := utf8.decode_grapheme_iterate(&it)
		if !ok || len(piece) == 0 {
			break
		}
		if piece == "\t" {
			n := TAB_WIDTH - (col % TAB_WIDTH)
			render_write_spaces(out, n)
			col += n
			continue
		}
		render_append_string(out, piece)
		if g.width > 0 {
			col += g.width
		}
	}
}

// 只写能放进 max_cols 列的完整 grapheme；用于右侧 hints。
render_write_text_limited :: proc(out: ^[dynamic]u8, text: string, max_cols: int) {
	it := utf8.decode_grapheme_iterator_make(text)
	col := 0
	for {
		piece, g, ok := utf8.decode_grapheme_iterate(&it)
		if !ok || len(piece) == 0 {
			break
		}
		w := g.width
		if w < 0 {
			w = 0
		}
		if piece == "\t" {
			w = TAB_WIDTH - (col % TAB_WIDTH)
		}
		if col + w > max_cols {
			break
		}
		if piece == "\t" {
			render_write_spaces(out, w)
		} else {
			render_append_string(out, piece)
		}
		col += w
	}
}

render_append_string :: proc(out: ^[dynamic]u8, s: string) {
	for i in 0 ..< len(s) {
		append(out, s[i])
	}
}

render_append_csi :: proc(out: ^[dynamic]u8, final: u8, n: int) {
	if n <= 0 {
		return
	}
	append(out, 0x1b)
	append(out, '[')
	render_append_int(out, n)
	append(out, final)
}

render_append_int :: proc(out: ^[dynamic]u8, n: int) {
	if n <= 0 {
		append(out, '0')
		return
	}
	buf: [20]u8
	i := len(buf)
	v := n
	for v > 0 {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
	}
	for j := i; j < len(buf); j += 1 {
		append(out, buf[j])
	}
}
