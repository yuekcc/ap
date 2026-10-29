package aptui

import "core:strings"
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
test_editor_vertical_from_end :: proc(t: ^testing.T) {
	e := editor_with("abcdef\nabcdefgh\nxy")
	defer editor_destroy(&e)
	e.cursor = 18
	testing.expect(t, editor_up(&e, 80, 0))
	testing.expect_value(t, e.cursor, 9)
	testing.expect(t, editor_up(&e, 80, 0))
	testing.expect_value(t, e.cursor, 2)
}

@(test)
test_editor_apply_key :: proc(t: ^testing.T) {
	e := editor_with("abc")
	defer editor_destroy(&e)
	action := editor_apply_key(&e, Key{kind = .Enter}, 80, 0)
	testing.expect_value(t, action, Editor_Action.Submit)
	testing.expect_value(t, editor_text(&e), "abc")

	e2 := editor_with("   ")
	defer editor_destroy(&e2)
	action = editor_apply_key(&e2, Key{kind = .Enter}, 80, 0)
	testing.expect_value(t, action, Editor_Action.None)
	testing.expect_value(t, editor_text(&e2), "")

	e3 := editor_with("x")
	defer editor_destroy(&e3)
	action = editor_apply_key(&e3, Key{kind = .Ctrl_C}, 80, 0)
	testing.expect_value(t, action, Editor_Action.None)
	testing.expect_value(t, editor_text(&e3), "")
	action = editor_apply_key(&e3, Key{kind = .Ctrl_C}, 80, 0)
	testing.expect_value(t, action, Editor_Action.Quit)

	e4 := editor_with("a")
	defer editor_destroy(&e4)
	action = editor_apply_key(&e4, Key{kind = .Ctrl_Enter}, 80, 0)
	testing.expect_value(t, action, Editor_Action.None)
	testing.expect_value(t, editor_text(&e4), "a\n")
}

@(test)
test_editor_typed_input_limit :: proc(t: ^testing.T) {
	e := editor_with("")
	defer editor_destroy(&e)

	huge := strings.repeat("a", MAX_INPUT)
	defer delete(huge)
	editor_insert_text(&e, huge)
	testing.expect_value(t, len(e.buffer), MAX_INPUT)

	// 普通按键同样受上限约束。
	editor_insert_rune(&e, 'x')
	testing.expect_value(t, len(e.buffer), MAX_INPUT)
}

@(test)
test_editor_paste_normalizes_crlf :: proc(t: ^testing.T) {
	e := editor_with("")
	defer editor_destroy(&e)
	truncated := editor_insert_text(&e, "a\r\nb\rc")
	testing.expect(t, !truncated)
	testing.expect_value(t, editor_text(&e), "a\nbc")
}

@(test)
test_editor_input_limit :: proc(t: ^testing.T) {
	e := editor_with("")
	defer editor_destroy(&e)

	huge := strings.repeat("a", MAX_INPUT + 100)
	defer delete(huge)
	truncated := editor_insert_text(&e, huge)
	testing.expect(t, truncated)
	testing.expect(t, len(e.buffer) <= MAX_INPUT)
	testing.expect(t, strings.contains(editor_text(&e), "[input truncated]"))

	// 已经满了以后继续插不进去。
	before := len(e.buffer)
	truncated = editor_insert_text(&e, "more")
	testing.expect(t, truncated)
	testing.expect_value(t, len(e.buffer), before)
}
