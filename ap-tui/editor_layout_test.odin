package aptui

import "core:testing"

layout_of :: proc(text: string, cursor, cols, prefix: int) -> Layout {
	return layout(transmute([]u8)text, cursor, cols, prefix)
}

@(test)
test_layout_empty :: proc(t: ^testing.T) {
	l := layout_of("", 0, 20, 2)
	defer layout_destroy(&l)
	testing.expect_value(t, len(l.rows), 1)
	testing.expect_value(t, l.rows[0].start, 0)
	testing.expect_value(t, l.rows[0].len, 0)
	testing.expect_value(t, l.cursor_row, 0)
	testing.expect_value(t, l.cursor_col, 2)
}

@(test)
test_layout_ascii_and_prefix :: proc(t: ^testing.T) {
	l := layout_of("hello", 5, 20, 2)
	defer layout_destroy(&l)
	testing.expect_value(t, len(l.rows), 1)
	testing.expect_value(t, l.cursor_row, 0)
	testing.expect_value(t, l.cursor_col, 7)

	l2 := layout_of("abcdefgh", 8, 10, 2)
	defer layout_destroy(&l2)
	testing.expect_value(t, len(l2.rows), 1)
	testing.expect_value(t, l2.cursor_col, 10)
}

@(test)
test_layout_cjk_width :: proc(t: ^testing.T) {
	l := layout_of("中文", 6, 20, 2)
	defer layout_destroy(&l)
	testing.expect_value(t, len(l.rows), 1)
	testing.expect_value(t, l.cursor_col, 6)
}

@(test)
test_layout_hard_wrap :: proc(t: ^testing.T) {
	l := layout_of("abcdef", 5, 5, 0)
	defer layout_destroy(&l)
	testing.expect_value(t, len(l.rows), 2)
	testing.expect_value(t, l.rows[0].len, 5)
	testing.expect_value(t, l.rows[1].start, 5)
	testing.expect_value(t, l.rows[1].len, 1)
	// 折行点上的光标属于下一行。
	testing.expect_value(t, l.cursor_row, 1)
	testing.expect_value(t, l.cursor_col, 0)

	l2 := layout_of("abcdef", 6, 5, 0)
	defer layout_destroy(&l2)
	testing.expect_value(t, l2.cursor_row, 1)
	testing.expect_value(t, l2.cursor_col, 1)
}

@(test)
test_layout_exact_width :: proc(t: ^testing.T) {
	l := layout_of("abcde", 5, 5, 0)
	defer layout_destroy(&l)
	testing.expect_value(t, len(l.rows), 1)
	// 恰好整行宽度时，行尾光标仍留在本行。
	testing.expect_value(t, l.cursor_row, 0)
	testing.expect_value(t, l.cursor_col, 5)
}

@(test)
test_layout_newlines_and_empty_lines :: proc(t: ^testing.T) {
	l := layout_of("a\n", 2, 20, 0)
	defer layout_destroy(&l)
	testing.expect_value(t, len(l.rows), 2)
	testing.expect_value(t, l.rows[1].start, 2)
	testing.expect_value(t, l.rows[1].len, 0)
	testing.expect_value(t, l.cursor_row, 1)

	l2 := layout_of("a\n\nb", 2, 20, 0)
	defer layout_destroy(&l2)
	testing.expect_value(t, len(l2.rows), 3)
	testing.expect_value(t, l2.rows[1].start, 2)
	testing.expect_value(t, l2.rows[1].len, 0)
	testing.expect_value(t, l2.rows[2].start, 3)
	testing.expect_value(t, l2.cursor_row, 1)
}

@(test)
test_layout_cjk_wrap :: proc(t: ^testing.T) {
	l := layout_of("ab中文", 8, 4, 0)
	defer layout_destroy(&l)
	testing.expect_value(t, len(l.rows), 2)
	testing.expect_value(t, l.rows[0].len, 5) // "ab中"
	testing.expect_value(t, l.rows[1].start, 5)
	testing.expect_value(t, l.cursor_row, 1)
	testing.expect_value(t, l.cursor_col, 2)

	// 双宽字符在当前行放不下时整体换行。
	l2 := layout_of("a中", 4, 2, 0)
	defer layout_destroy(&l2)
	testing.expect_value(t, len(l2.rows), 2)
	testing.expect_value(t, l2.rows[0].len, 1)
	testing.expect_value(t, l2.cursor_row, 1)
	testing.expect_value(t, l2.cursor_col, 2)
}

@(test)
test_layout_window :: proc(t: ^testing.T) {
	// 光标在窗口内：不滚动。
	top, cap := layout_window(7, 2, 10)
	testing.expect_value(t, top, 0)
	testing.expect_value(t, cap, 7)

	// 需要滚动：首行让给 “…” 提示，内容容量 max_rows - 1。
	top, cap = layout_window(7, 6, 3)
	testing.expect_value(t, top, 5)
	testing.expect_value(t, cap, 2)

	// 贴底时窗口不越过末行。
	top, cap = layout_window(5, 4, 2)
	testing.expect_value(t, top, 4)
	testing.expect_value(t, cap, 1)

	// 只有一行可用的极端终端。
	top, cap = layout_window(5, 4, 1)
	testing.expect_value(t, top, 4)
	testing.expect_value(t, cap, 1)
}
