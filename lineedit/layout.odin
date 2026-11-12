package lineedit

import "core:unicode/utf8"

TAB_WIDTH :: 8

Row :: struct {
	start: int,
	len:   int,
}

Layout :: struct {
	rows:       [dynamic]Row,
	cursor_row: int,
	cursor_col: int, // 绝对终端列（含 prefix）
}

// 按显示宽度硬折行（不按词）。rows 里的区间是 buffer 的字节区间，不含行前缀。
// cols 是终端总列数，prefix_width 是每行前缀的显示宽度。
layout :: proc(buf: []u8, cursor, cols, prefix_width: int, allocator := context.allocator) -> Layout {
	l: Layout
	l.rows = make([dynamic]Row, 0, 4, allocator)

	content_cols := cols - prefix_width
	if content_cols < 1 {
		content_cols = 1
	}
	cur := cursor
	if cur < 0 {
		cur = 0
	}
	if cur > len(buf) {
		cur = len(buf)
	}

	row_start := 0
	col := 0
	it := utf8.decode_grapheme_iterator_make(string(buf))
	for {
		text, g, ok := utf8.decode_grapheme_iterate(&it)
		if !ok {
			break
		}

		if text == "\n" {
			append(&l.rows, Row{start = row_start, len = g.byte_index - row_start})
			row_start = g.byte_index + len(text)
			col = 0
			continue
		}

		w := g.width
		if w < 0 {
			w = 0
		}
		if text == "\t" {
			w = TAB_WIDTH - (col % TAB_WIDTH)
		}

		if col > 0 && col + w > content_cols {
			append(&l.rows, Row{start = row_start, len = g.byte_index - row_start})
			row_start = g.byte_index
			col = 0
		}
		col += w
	}
	append(&l.rows, Row{start = row_start, len = len(buf) - row_start})

	// 光标所在行：折行点属于下一行，硬换行前的光标留在本行行尾。
	l.cursor_row = 0
	for row, idx in l.rows {
		end := row.start + row.len
		if cur < end {
			l.cursor_row = idx
			break
		}
		if cur == end {
			if idx + 1 < len(l.rows) && l.rows[idx + 1].start == cur {
				l.cursor_row = idx + 1
			} else {
				l.cursor_row = idx
			}
			break
		}
	}

	// 光标列：只累计该行到 cursor 为止的 grapheme 宽度。
	row := l.rows[l.cursor_row]
	target := min(cur, row.start + row.len)
	col = 0
	if target > row.start {
		part := string(buf[row.start:target])
		it2 := utf8.decode_grapheme_iterator_make(part)
		for {
			text, g, ok := utf8.decode_grapheme_iterate(&it2)
			if !ok {
				break
			}
			w := g.width
			if w < 0 {
				w = 0
			}
			if text == "\t" {
				w = TAB_WIDTH - (col % TAB_WIDTH)
			}
			col += w
		}
	}
	l.cursor_col = prefix_width + col
	return l
}

layout_destroy :: proc(l: ^Layout) {
	delete(l.rows)
	l^ = {}
}

// 计算滚动窗口：cap 为从 top 起可见的内容行数，max_rows 是终端留给整块的行数。
// 需要滚动时首行让给 “…” 提示，因此内容容量少一行。
layout_window :: proc(total_rows, cursor_row, max_rows: int) -> (top: int, cap: int) {
	budget := max_rows
	if budget < 1 {
		budget = 1
	}
	cap = min(total_rows, budget)
	if cursor_row < cap {
		return 0, cap
	}
	if budget == 1 {
		return cursor_row, 1
	}
	cap = budget - 1
	top = cursor_row - cap + 1
	if top + cap > total_rows {
		top = total_rows - cap
	}
	if top < 0 {
		top = 0
	}
	return top, cap
}

// 计算一段文本的显示宽度。ANSI CSI/OSC 序列按 0 宽处理，tab 按 8 列制表位展开。
display_width :: proc(s: string) -> int {
	w := 0
	i := 0
	for i < len(s) {
		if s[i] == 0x1b {
			n := ansi_sequence_len(s[i:])
			if n > 0 {
				i += n
				continue
			}
		}

		it := utf8.decode_grapheme_iterator_make(s[i:])
		text, g, ok := utf8.decode_grapheme_iterate(&it)
		if !ok || len(text) == 0 {
			break
		}
		if text == "\t" {
			w += TAB_WIDTH - (w % TAB_WIDTH)
		} else if g.width > 0 {
			w += g.width
		}
		i += len(text)
	}
	return w
}

// 返回 s 开头的 ANSI 序列长度；不是 ANSI 序列时返回 0。
ansi_sequence_len :: proc(s: string) -> int {
	if len(s) < 2 || s[0] != 0x1b {
		return 0
	}
	switch s[1] {
	case '[':
		i := 2
		for i < len(s) {
			b := s[i]
			if b >= 0x40 && b <= 0x7e {
				return i + 1
			}
			i += 1
		}
		return len(s)
	case ']':
		i := 2
		for i < len(s) {
			if s[i] == 0x07 {
				return i + 1
			}
			if s[i] == 0x1b && i + 1 < len(s) && s[i + 1] == '\\' {
				return i + 2
			}
			i += 1
		}
		return len(s)
	case 'P', '^', '_':
		i := 2
		for i < len(s) {
			if s[i] == 0x1b && i + 1 < len(s) && s[i + 1] == '\\' {
				return i + 2
			}
			i += 1
		}
		return len(s)
	case '(', ')', '*', '+':
		if len(s) >= 3 {
			return 3
		}
		return len(s)
	case:
		return 2
	}
}
