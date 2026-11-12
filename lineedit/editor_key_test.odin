package lineedit

import "core:testing"

@(test)
test_editor_apply_text_and_shortcuts :: proc(t: ^testing.T) {
	e := editor_with("abc")
	defer editor_destroy(&e)

	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'X'), 80, 0), Edit_Action.None)
	testing.expect_value(t, editor_text(&e), "abcX")

	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'a', {.Ctrl}), 80, 0), Edit_Action.None)
	testing.expect_value(t, e.cursor, 0)
	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'e', {.Ctrl}), 80, 0), Edit_Action.None)
	testing.expect_value(t, e.cursor, 4)
	// 光标在 "abcX" 末尾，Ctrl+W 删除整个词。
	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'w', {.Ctrl}), 80, 0), Edit_Action.None)
	testing.expect_value(t, editor_text(&e), "")
}

@(test)
test_editor_apply_kill :: proc(t: ^testing.T) {
	e := editor_with("one two")
	defer editor_destroy(&e)
	editor_set_cursor(&e, 3)
	editor_apply_key(&e, key(.Rune, 'k', {.Ctrl}), 80, 0)
	testing.expect_value(t, editor_text(&e), "one")

	e2 := editor_with("one two")
	defer editor_destroy(&e2)
	editor_set_cursor(&e2, 4)
	editor_apply_key(&e2, key(.Rune, 'u', {.Ctrl}), 80, 0)
	testing.expect_value(t, editor_text(&e2), "two")
}

@(test)
test_editor_apply_enter_and_newline :: proc(t: ^testing.T) {
	e := editor_with("x")
	defer editor_destroy(&e)

	testing.expect_value(t, editor_apply_key(&e, key(.Enter), 80, 0), Edit_Action.Submit)
	testing.expect_value(t, editor_text(&e), "x")

	testing.expect_value(t, editor_apply_key(&e, key(.Enter, 0, {.Ctrl}), 80, 0), Edit_Action.None)
	testing.expect_value(t, editor_text(&e), "x\n")
	testing.expect_value(t, editor_apply_key(&e, key(.Enter, 0, {.Shift}), 80, 0), Edit_Action.None)
	testing.expect_value(t, editor_text(&e), "x\n\n")

	// kitty 下 Ctrl+M / Ctrl+J 与 Enter 分开；为兼容 readline 仍视为提交。
	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'm', {.Ctrl}), 80, 0), Edit_Action.Submit)
	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'j', {.Ctrl}), 80, 0), Edit_Action.Submit)
}

@(test)
test_editor_apply_tab_and_completion :: proc(t: ^testing.T) {
	e: Editor
	editor_init(&e)
	defer editor_destroy(&e)
	testing.expect_value(t, editor_apply_key(&e, key(.Tab), 80, 0), Edit_Action.Complete)
	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'i', {.Ctrl}), 80, 0), Edit_Action.Complete)
	testing.expect_value(t, editor_apply_key(&e, key(.Tab, 0, {.Shift}), 80, 0), Edit_Action.Complete_Prev)
	testing.expect_value(t, editor_text(&e), "")
}

@(test)
test_editor_apply_ctrl_c_d :: proc(t: ^testing.T) {
	e: Editor
	editor_init(&e)
	defer editor_destroy(&e)
	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'd', {.Ctrl}), 80, 0), Edit_Action.Eof)
	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'c', {.Ctrl}), 80, 0), Edit_Action.Cancel)

	editor_insert_text(&e, "abc")
	editor_set_cursor(&e, 2)
	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'd', {.Ctrl}), 80, 0), Edit_Action.None)
	testing.expect_value(t, editor_text(&e), "ab")
	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'c', {.Ctrl}), 80, 0), Edit_Action.None)
	testing.expect_value(t, editor_text(&e), "")
}

@(test)
test_editor_apply_navigation :: proc(t: ^testing.T) {
	e := editor_with("foo bar\nbaz")
	defer editor_destroy(&e)
	editor_set_cursor(&e, 11)

	// Ctrl+←/→ 按词移动。
	testing.expect_value(t, editor_apply_key(&e, key(.Left, 0, {.Ctrl}), 80, 0), Edit_Action.None)
	testing.expect_value(t, e.cursor, 8)
	testing.expect_value(t, editor_apply_key(&e, key(.Right, 0, {.Ctrl}), 80, 0), Edit_Action.None)
	testing.expect_value(t, e.cursor, 11)

	// Ctrl+Home/End 到整个缓冲区。
	testing.expect_value(t, editor_apply_key(&e, key(.Home, 0, {.Ctrl}), 80, 0), Edit_Action.None)
	testing.expect_value(t, e.cursor, 0)
	testing.expect_value(t, editor_apply_key(&e, key(.End, 0, {.Ctrl}), 80, 0), Edit_Action.None)
	testing.expect_value(t, e.cursor, 11)

	// Alt+B/F 同词移动。
	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'b', {.Alt}), 80, 0), Edit_Action.None)
	testing.expect_value(t, e.cursor, 8)
	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'f', {.Alt}), 80, 0), Edit_Action.None)
	testing.expect_value(t, e.cursor, 11)
}

@(test)
test_editor_apply_history_navigation :: proc(t: ^testing.T) {
	e := editor_with("single")
	defer editor_destroy(&e)

	// 单行缓冲区：上下到达边界时交给 history。
	testing.expect_value(t, editor_apply_key(&e, key(.Up), 80, 0), Edit_Action.History_Prev)
	testing.expect_value(t, editor_apply_key(&e, key(.Down), 80, 0), Edit_Action.History_Next)

	// 多行缓冲区：行内优先上下移动。
	e2 := editor_with("a\nb")
	defer editor_destroy(&e2)
	editor_set_cursor(&e2, 0)
	testing.expect_value(t, editor_apply_key(&e2, key(.Down), 80, 0), Edit_Action.None)
	testing.expect_value(t, e2.cursor, 2)
	testing.expect_value(t, editor_apply_key(&e2, key(.Up), 80, 0), Edit_Action.None)
	testing.expect_value(t, e2.cursor, 0)
	testing.expect_value(t, editor_apply_key(&e2, key(.Up), 80, 0), Edit_Action.History_Prev)

	// 末行再按下键才交给 history。
	editor_set_cursor(&e2, 3)
	testing.expect_value(t, editor_apply_key(&e2, key(.Down), 80, 0), Edit_Action.History_Next)
}

@(test)
test_editor_apply_misc_keys :: proc(t: ^testing.T) {
	e := editor_with("ab")
	defer editor_destroy(&e)
	editor_set_cursor(&e, 2)

	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'h', {.Ctrl}), 80, 0), Edit_Action.None)
	testing.expect_value(t, editor_text(&e), "a")
	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'l', {.Ctrl}), 80, 0), Edit_Action.Redraw)
	testing.expect_value(t, editor_apply_key(&e, key(.Escape), 80, 0), Edit_Action.None)
	testing.expect_value(t, editor_text(&e), "")
	testing.expect_value(t, editor_apply_key(&e, key(.Page_Up), 80, 0), Edit_Action.History_Prev)
	testing.expect_value(t, editor_apply_key(&e, key(.Page_Down), 80, 0), Edit_Action.History_Next)
	testing.expect_value(t, editor_apply_key(&e, key(.Insert), 80, 0), Edit_Action.None)
}

@(test)
test_editor_apply_unknown_modifiers_do_not_insert :: proc(t: ^testing.T) {
	e: Editor
	editor_init(&e)
	defer editor_destroy(&e)

	// 没绑定的 Ctrl/Alt 组合绝不能退化成正文插入。
	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'z', {.Ctrl}), 80, 0), Edit_Action.None)
	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'z', {.Alt}), 80, 0), Edit_Action.None)
	testing.expect_value(t, editor_text(&e), "")

	// Shift 只是修饰，文本本身已经是大写。
	testing.expect_value(t, editor_apply_key(&e, key(.Rune, 'A', {.Shift}), 80, 0), Edit_Action.None)
	testing.expect_value(t, editor_text(&e), "A")
}
