package aptui

import "core:unicode"
import "core:unicode/utf8"

Row :: struct {
	start: int,
	len:   int,
}

Layout :: struct {
	rows:       [dynamic]Row,
	top:        int,
	cursor_row: int,
	cursor_col: int,
}

rune_width :: proc(r: rune) -> int {
	w := unicode.normalized_east_asian_width(r)
	if w < 0 {
		return 0
	}
	return w
}

string_width :: proc(s: string) -> int {
	w := 0
	for r in s {
		w += rune_width(r)
	}
	return w
}

// 按显示宽度硬折行（不按词）。返回的行都是 buffer 的字节区间，不含前缀。
// cols 是终端总列数，prefix_width 是每行前缀的显示宽度。
layout :: proc(buf: []u8, cursor, cols, prefix_width: int, allocator := context.allocator) -> Layout {
	l: Layout
	l.rows = make([dynamic]Row, 0, 4, allocator)

	content_cols := cols - prefix_width
	if content_cols < 1 {
		content_cols = 1
	}

	row_start := 0
	col := 0
	i := 0
	for i < len(buf) {
		if buf[i] == '\n' {
			append(&l.rows, Row{start = row_start, len = i - row_start})
			i += 1
			row_start = i
			col = 0
			continue
		}
		r, size := utf8.decode_rune_in_bytes(buf[i:])
		if size <= 0 {
			size = 1
		}
		w := rune_width(r)
		if col > 0 && col + w > content_cols {
			append(&l.rows, Row{start = row_start, len = i - row_start})
			row_start = i
			col = 0
		}
		col += w
		i += size
	}
	append(&l.rows, Row{start = row_start, len = len(buf) - row_start})

	l.cursor_row = max(len(l.rows) - 1, 0)
	for row, idx in l.rows {
		end := row.start + row.len
		if cursor < end {
			l.cursor_row = idx
			break
		}
		if cursor == end {
			// 折行点上的光标属于下一行；硬换行的光标仍留在本行行尾。
			if idx + 1 < len(l.rows) && l.rows[idx + 1].start == cursor {
				l.cursor_row = idx + 1
			} else {
				l.cursor_row = idx
			}
			break
		}
	}

	row := l.rows[l.cursor_row]
	col = 0
	i = row.start
	for i < cursor {
		r, size := utf8.decode_rune_in_bytes(buf[i:])
		if size <= 0 {
			size = 1
		}
		col += rune_width(r)
		i += size
	}
	l.cursor_col = prefix_width + col
	return l
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

layout_destroy :: proc(l: ^Layout) {
	delete(l.rows)
	l^ = {}
}
