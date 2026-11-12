package lineedit

import "core:testing"

editor_with :: proc(text: string) -> Editor {
	e: Editor
	editor_init(&e)
	editor_insert_text(&e, text)
	return e
}

@(test)
test_editor_insert_and_delete :: proc(t: ^testing.T) {
	e := editor_with("abc")
	defer editor_destroy(&e)
	testing.expect_value(t, editor_text(&e), "abc")
	testing.expect_value(t, e.cursor, 3)

	editor_backspace(&e)
	testing.expect_value(t, editor_text(&e), "ab")
	testing.expect_value(t, e.cursor, 2)

	editor_left(&e)
	editor_delete(&e)
	testing.expect_value(t, editor_text(&e), "a")

	editor_right(&e)
	testing.expect_value(t, e.cursor, 1)
}

@(test)
test_editor_insert_in_middle :: proc(t: ^testing.T) {
	e := editor_with("abc")
	defer editor_destroy(&e)
	e.cursor = 1
	editor_insert_text(&e, "XY")
	testing.expect_value(t, editor_text(&e), "aXYbc")
	testing.expect_value(t, e.cursor, 3)

	editor_backspace(&e)
	testing.expect_value(t, editor_text(&e), "aXbc")
}

@(test)
test_editor_multibyte_rune :: proc(t: ^testing.T) {
	e := editor_with("中文")
	defer editor_destroy(&e)
	editor_backspace(&e)
	testing.expect_value(t, editor_text(&e), "中")

	editor_left(&e)
	editor_delete(&e)
	testing.expect_value(t, editor_text(&e), "")
	testing.expect_value(t, e.cursor, 0)
}

@(test)
test_editor_insert_rune :: proc(t: ^testing.T) {
	e: Editor
	editor_init(&e)
	defer editor_destroy(&e)
	truncated := editor_insert_rune(&e, '中')
	testing.expect(t, !truncated)
	testing.expect_value(t, editor_text(&e), "中")
	testing.expect_value(t, e.cursor, 3)
}

@(test)
test_editor_left_right_across_newline :: proc(t: ^testing.T) {
	e := editor_with("a\nb")
	defer editor_destroy(&e)
	testing.expect_value(t, e.cursor, 3)
	editor_left(&e)
	testing.expect_value(t, e.cursor, 2)
	editor_left(&e)
	testing.expect_value(t, e.cursor, 1)
	editor_left(&e)
	testing.expect_value(t, e.cursor, 0)
	editor_right(&e)
	testing.expect_value(t, e.cursor, 1)
	editor_right(&e)
	testing.expect_value(t, e.cursor, 2)
}

@(test)
test_editor_home_end :: proc(t: ^testing.T) {
	e := editor_with("abc\ndef")
	defer editor_destroy(&e)
	e.cursor = 5 // "abc\nd|ef"
	editor_home(&e)
	testing.expect_value(t, e.cursor, 4)
	editor_end(&e)
	testing.expect_value(t, e.cursor, 7)
	editor_home(&e)
	editor_left(&e)
	testing.expect_value(t, e.cursor, 3) // 换行符之前
	editor_home(&e)
	testing.expect_value(t, e.cursor, 0)
	editor_end(&e)
	testing.expect_value(t, e.cursor, 3)
}

@(test)
test_editor_buffer_start_end :: proc(t: ^testing.T) {
	e := editor_with("abc\ndef")
	defer editor_destroy(&e)
	e.cursor = 5
	editor_buffer_start(&e)
	testing.expect_value(t, e.cursor, 0)
	editor_buffer_end(&e)
	testing.expect_value(t, e.cursor, 7)
}

@(test)
test_editor_kill_line :: proc(t: ^testing.T) {
	e := editor_with("one\ntwo three\nfour")
	defer editor_destroy(&e)
	e.cursor = 7 // "one\ntwo| three"
	editor_kill_to_end(&e)
	testing.expect_value(t, editor_text(&e), "one\ntwo\nfour")
	testing.expect_value(t, e.cursor, 7)

	e2 := editor_with("one\ntwo three\nfour")
	defer editor_destroy(&e2)
	e2.cursor = 7
	editor_kill_to_start(&e2)
	testing.expect_value(t, editor_text(&e2), "one\n three\nfour")
	testing.expect_value(t, e2.cursor, 4)

	// 对称：行首 Ctrl+U、行尾 Ctrl+K 都是 no-op。
	e3 := editor_with("abc\ndef")
	defer editor_destroy(&e3)
	e3.cursor = 4
	editor_kill_to_start(&e3)
	testing.expect_value(t, editor_text(&e3), "abc\ndef")
	e3.cursor = 3
	editor_kill_to_end(&e3)
	testing.expect_value(t, editor_text(&e3), "abc\ndef")
}

@(test)
test_editor_delete_word :: proc(t: ^testing.T) {
	e := editor_with("foo/bar baz  ")
	defer editor_destroy(&e)
	editor_delete_word(&e)
	testing.expect_value(t, editor_text(&e), "foo/bar ")

	e2 := editor_with("a/b")
	defer editor_destroy(&e2)
	editor_delete_word(&e2)
	testing.expect_value(t, editor_text(&e2), "")

	e3 := editor_with("keep   drop")
	defer editor_destroy(&e3)
	e3.cursor = 7 // "keep   |drop"：先跳过空白，再删掉前一个词
	editor_delete_word(&e3)
	testing.expect_value(t, editor_text(&e3), "drop")
}

@(test)
test_editor_word_motion :: proc(t: ^testing.T) {
	e := editor_with("foo bar baz")
	defer editor_destroy(&e)
	e.cursor = 0
	editor_word_right(&e)
	testing.expect_value(t, e.cursor, 3)
	editor_word_right(&e)
	testing.expect_value(t, e.cursor, 7)
	editor_word_right(&e)
	testing.expect_value(t, e.cursor, 11)
	editor_word_left(&e)
	testing.expect_value(t, e.cursor, 8)
	editor_word_left(&e)
	testing.expect_value(t, e.cursor, 4)
	editor_word_left(&e)
	testing.expect_value(t, e.cursor, 0)
}

@(test)
test_editor_crlf_normalized :: proc(t: ^testing.T) {
	e: Editor
	editor_init(&e)
	defer editor_destroy(&e)
	editor_insert_text(&e, "a\r\nb\rc")
	testing.expect_value(t, editor_text(&e), "a\nb\nc")
}

@(test)
test_editor_max_len :: proc(t: ^testing.T) {
	e: Editor
	editor_init(&e, 5)
	defer editor_destroy(&e)
	truncated := editor_insert_text(&e, "abcdef")
	testing.expect(t, truncated)
	testing.expect_value(t, editor_text(&e), "abcde")
	testing.expect_value(t, e.cursor, 5)

	e2: Editor
	editor_init(&e2, 4)
	defer editor_destroy(&e2)
	// 4 字节只能放下一个 3 字节汉字，不能切在 rune 中间。
	truncated = editor_insert_text(&e2, "中中")
	testing.expect(t, truncated)
	testing.expect_value(t, editor_text(&e2), "中")
	testing.expect_value(t, e2.cursor, 3)
}

@(test)
test_editor_vertical_keeps_column :: proc(t: ^testing.T) {
	e := editor_with("abcdef\nabcdefgh\nxy")
	defer editor_destroy(&e)

	e.cursor = 4 // 第一行第 4 列
	testing.expect(t, editor_down(&e, 80, 0))
	testing.expect_value(t, e.cursor, 11) // "abcdefgh" 第 4 列
	testing.expect(t, editor_down(&e, 80, 0))
	testing.expect_value(t, e.cursor, 18) // "xy" 只有 2 列，clamp
	testing.expect(t, !editor_down(&e, 80, 0))
	testing.expect_value(t, e.cursor, 18)

	// 回到短行时 desired_col 仍应恢复为 4。
	testing.expect(t, editor_up(&e, 80, 0))
	testing.expect_value(t, e.cursor, 11)

	testing.expect(t, editor_up(&e, 80, 0))
	testing.expect_value(t, e.cursor, 4)
	testing.expect(t, !editor_up(&e, 80, 0))
}

@(test)
test_editor_vertical_wrap :: proc(t: ^testing.T) {
	e := editor_with("abcdefgh")
	defer editor_destroy(&e)

	// cols=4 时折成两行：abcd / efgh。
	editor_set_cursor(&e, 2)
	testing.expect(t, editor_down(&e, 4, 0))
	testing.expect_value(t, e.cursor, 6)
	testing.expect(t, editor_up(&e, 4, 0))
	testing.expect_value(t, e.cursor, 2)

	// 横向移动会清掉 desired_col，不要继续沿用旧列。
	editor_set_cursor(&e, 3)
	testing.expect(t, editor_down(&e, 4, 0))
	testing.expect_value(t, e.cursor, 7)
	editor_left(&e) // 回到第 2 列，同时清掉 desired_col
	testing.expect(t, editor_up(&e, 4, 0))
	testing.expect_value(t, e.cursor, 2) // 跟随当前第 2 列，而不是之前的第 3 列
}

@(test)
test_editor_offset_for_column_cjk :: proc(t: ^testing.T) {
	text := "中中"
	buf := transmute([]u8)text
	// 第 3 列落在第一个汉字之后（宽度 2），下一个汉字会让列号变成 4。
	offset, col := editor_offset_for_column(buf, Row{start = 0, len = len(buf)}, 3)
	testing.expect_value(t, offset, 3)
	testing.expect_value(t, col, 2)
}

@(test)
test_editor_boundaries :: proc(t: ^testing.T) {
	e: Editor
	editor_init(&e)
	defer editor_destroy(&e)
	editor_backspace(&e)
	editor_delete(&e)
	editor_left(&e)
	editor_right(&e)
	editor_home(&e)
	editor_end(&e)
	editor_kill_to_end(&e)
	editor_kill_to_start(&e)
	editor_delete_word(&e)
	testing.expect_value(t, editor_text(&e), "")
	testing.expect_value(t, e.cursor, 0)
}
