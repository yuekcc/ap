package lineedit

import "core:testing"

layout_text :: proc(text: string, cursor, cols, prefix: int) -> Layout {
	return layout(transmute([]u8)text, cursor, cols, prefix)
}

expect_row :: proc(t: ^testing.T, l: Layout, i, start, length: int) {
	if i >= len(l.rows) {
		testing.expectf(t, false, "row %d missing (rows=%d)", i, len(l.rows))
		return
	}
	got := l.rows[i]
	testing.expectf(t, got == Row{start = start, len = length}, "row %d: got %v, want {%d,%d}", i, got, start, length)
}

@(test)
test_layout_single_line :: proc(t: ^testing.T) {
	l := layout_text("abc", 0, 80, 2)
	defer layout_destroy(&l)
	testing.expect_value(t, len(l.rows), 1)
	expect_row(t, l, 0, 0, 3)
	testing.expect_value(t, l.cursor_row, 0)
	testing.expect_value(t, l.cursor_col, 2)

	l2 := layout_text("abc", 3, 80, 2)
	defer layout_destroy(&l2)
	testing.expect_value(t, l2.cursor_col, 5)

	l3 := layout_text("abc", 1, 80, 2)
	defer layout_destroy(&l3)
	testing.expect_value(t, l3.cursor_col, 3)
}

@(test)
test_layout_newlines :: proc(t: ^testing.T) {
	l := layout_text("abc\ndef", 4, 80, 0)
	defer layout_destroy(&l)
	testing.expect_value(t, len(l.rows), 2)
	expect_row(t, l, 0, 0, 3)
	expect_row(t, l, 1, 4, 3)
	testing.expect_value(t, l.cursor_row, 1)
	testing.expect_value(t, l.cursor_col, 0)

	l2 := layout_text("abc\ndef", 7, 80, 0)
	defer layout_destroy(&l2)
	testing.expect_value(t, l2.cursor_row, 1)
	testing.expect_value(t, l2.cursor_col, 3)

	l3 := layout_text("abc\ndef", 3, 80, 0)
	defer layout_destroy(&l3)
	testing.expect_value(t, l3.cursor_row, 0)
	testing.expect_value(t, l3.cursor_col, 3)
}

@(test)
test_layout_empty_and_trailing_newline :: proc(t: ^testing.T) {
	l := layout_text("", 0, 80, 2)
	defer layout_destroy(&l)
	testing.expect_value(t, len(l.rows), 1)
	expect_row(t, l, 0, 0, 0)
	testing.expect_value(t, l.cursor_row, 0)
	testing.expect_value(t, l.cursor_col, 2)

	l2 := layout_text("abc\n", 4, 80, 2)
	defer layout_destroy(&l2)
	testing.expect_value(t, len(l2.rows), 2)
	expect_row(t, l2, 0, 0, 3)
	expect_row(t, l2, 1, 4, 0)
	testing.expect_value(t, l2.cursor_row, 1)
	testing.expect_value(t, l2.cursor_col, 2)
}

@(test)
test_layout_hard_wrap :: proc(t: ^testing.T) {
	l := layout_text("abcdef", 5, 5, 0)
	defer layout_destroy(&l)
	testing.expect_value(t, len(l.rows), 2)
	expect_row(t, l, 0, 0, 5)
	expect_row(t, l, 1, 5, 1)
	// 折行点上的光标属于下一行。
	testing.expect_value(t, l.cursor_row, 1)
	testing.expect_value(t, l.cursor_col, 0)

	l2 := layout_text("abcdef", 4, 5, 0)
	defer layout_destroy(&l2)
	testing.expect_value(t, l2.cursor_row, 0)
	testing.expect_value(t, l2.cursor_col, 4)

	l3 := layout_text("abcdef", 6, 5, 0)
	defer layout_destroy(&l3)
	testing.expect_value(t, l3.cursor_row, 1)
	testing.expect_value(t, l3.cursor_col, 1)

	// 正好填满一行且没有后续内容：不额外产生空行。
	l4 := layout_text("abcde", 5, 5, 0)
	defer layout_destroy(&l4)
	testing.expect_value(t, len(l4.rows), 1)
	expect_row(t, l4, 0, 0, 5)
	testing.expect_value(t, l4.cursor_row, 0)
	testing.expect_value(t, l4.cursor_col, 5)
}

@(test)
test_layout_cjk :: proc(t: ^testing.T) {
	l := layout_text("中中中", 3, 5, 0)
	defer layout_destroy(&l)
	testing.expect_value(t, len(l.rows), 2)
	expect_row(t, l, 0, 0, 6)
	expect_row(t, l, 1, 6, 3)
	testing.expect_value(t, l.cursor_row, 0)
	testing.expect_value(t, l.cursor_col, 2)

	l2 := layout_text("中中中", 6, 5, 0)
	defer layout_destroy(&l2)
	testing.expect_value(t, l2.cursor_row, 1)
	testing.expect_value(t, l2.cursor_col, 0)

	l3 := layout_text("中中中", 9, 5, 0)
	defer layout_destroy(&l3)
	testing.expect_value(t, l3.cursor_row, 1)
	testing.expect_value(t, l3.cursor_col, 2)
}

@(test)
test_layout_emoji_and_combining :: proc(t: ^testing.T) {
	family := "👨‍👩‍👧‍👦"
	l := layout_text(family, len(family), 80, 0)
	defer layout_destroy(&l)
	testing.expect_value(t, len(l.rows), 1)
	testing.expect_value(t, l.cursor_col, 2)

	combined := "e\u0301"
	l2 := layout_text(combined, len(combined), 80, 0)
	defer layout_destroy(&l2)
	testing.expect_value(t, len(l2.rows), 1)
	testing.expect_value(t, l2.cursor_col, 1)

	flag := "🇯🇵"
	l3 := layout_text(flag, len(flag), 80, 0)
	defer layout_destroy(&l3)
	testing.expect_value(t, len(l3.rows), 1)
	testing.expect_value(t, l3.cursor_col, 2)
}

@(test)
test_layout_tab :: proc(t: ^testing.T) {
	l := layout_text("a\tb", 3, 80, 0)
	defer layout_destroy(&l)
	testing.expect_value(t, l.cursor_col, 9)
}

@(test)
test_layout_narrow_terminal :: proc(t: ^testing.T) {
	// prefix 比终端还宽时，内容区至少保留 1 列。
	l := layout_text("abc", 0, 1, 5)
	defer layout_destroy(&l)
	testing.expect_value(t, len(l.rows), 3)
	expect_row(t, l, 0, 0, 1)
	expect_row(t, l, 1, 1, 1)
	expect_row(t, l, 2, 2, 1)
	testing.expect_value(t, l.cursor_col, 5)
}

@(test)
test_display_width :: proc(t: ^testing.T) {
	testing.expect_value(t, display_width("abc"), 3)
	testing.expect_value(t, display_width("中文"), 4)
	testing.expect_value(t, display_width("👨‍👩‍👧‍👦"), 2)
	testing.expect_value(t, display_width("e\u0301"), 1)
	testing.expect_value(t, display_width("a\tb"), 9)
	// ANSI CSI 序列不占列。
	testing.expect_value(t, display_width("\x1b[31m> \x1b[0m"), 2)
}
