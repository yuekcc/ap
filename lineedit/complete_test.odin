package lineedit

import "core:testing"

@(test)
test_completion_token_start :: proc(t: ^testing.T) {
	s1 := "foo bar"
	s2 := "hello"
	s3 := "中文 x"
	testing.expect_value(t, editor_token_start(transmute([]u8)s1, 7), 4)
	testing.expect_value(t, editor_token_start(transmute([]u8)s1, 4), 4)
	testing.expect_value(t, editor_token_start(transmute([]u8)s2, 2), 0)
	testing.expect_value(t, editor_token_start(transmute([]u8)s3, 8), 7)
}

@(test)
test_completion_single :: proc(t: ^testing.T) {
	e := editor_with("he")
	defer editor_destroy(&e)
	testing.expect(t, editor_apply_completions(&e, []Completion{{text = "hello"}}))
	testing.expect_value(t, editor_text(&e), "hello")
	testing.expect_value(t, e.cursor, 5)
}

@(test)
test_completion_common_prefix :: proc(t: ^testing.T) {
	e := editor_with("he")
	defer editor_destroy(&e)
	testing.expect(t, editor_apply_completions(&e, []Completion {
		{text = "hello"},
		{text = "help"},
	}))
	testing.expect_value(t, editor_text(&e), "hel")
	testing.expect_value(t, e.cursor, 3)
}

@(test)
test_completion_mid_token :: proc(t: ^testing.T) {
	e := editor_with("foo bar")
	defer editor_destroy(&e)
	editor_set_cursor(&e, 7)
	testing.expect(t, editor_apply_completions(&e, []Completion{{text = "baz"}}))
	testing.expect_value(t, editor_text(&e), "foo baz")
	testing.expect_value(t, e.cursor, 7)
}

@(test)
test_completion_no_change :: proc(t: ^testing.T) {
	e := editor_with("hello")
	defer editor_destroy(&e)
	testing.expect(t, !editor_apply_completions(&e, []Completion {
		{text = "hello"},
		{text = "help"},
	}))
	testing.expect_value(t, editor_text(&e), "hello")

	e2 := editor_with("")
	defer editor_destroy(&e2)
	testing.expect(t, !editor_apply_completions(&e2, []Completion{}))
	testing.expect_value(t, editor_text(&e2), "")
}

@(test)
test_completion_cjk_prefix :: proc(t: ^testing.T) {
	e := editor_with("中")
	defer editor_destroy(&e)
	testing.expect(t, editor_apply_completions(&e, []Completion {
		{text = "中文"},
		{text = "中文书"},
	}))
	testing.expect_value(t, editor_text(&e), "中文")
	testing.expect_value(t, e.cursor, 6)
}
