package lineedit

import "core:testing"

draw :: proc(s: ^Screen, r: ^Renderer, e: ^Editor, cfg: Render_Config, cols, rows: int) {
	out: [dynamic]u8
	defer delete(out)
	render_frame(r, &out, e, cfg, cols, rows)
	screen_feed(s, out[:])
}

finish :: proc(s: ^Screen, r: ^Renderer) {
	out: [dynamic]u8
	defer delete(out)
	render_finish(r, &out)
	screen_feed(s, out[:])
}

abort :: proc(s: ^Screen, r: ^Renderer) {
	out: [dynamic]u8
	defer delete(out)
	render_abort(r, &out)
	screen_feed(s, out[:])
}

@(test)
test_render_basic :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("abc")
	defer editor_destroy(&e)
	editor_set_cursor(&e, 0)

	draw(&s, &r, &e, Render_Config{prompt = "> ", prefix_width = 2}, 80, 24)
	testing.expect_value(t, screen_row_text(&s, 0), "> abc")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 0)
	testing.expect_value(t, col, 2)
}

@(test)
test_render_redraw :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("abc")
	defer editor_destroy(&e)
	cfg := Render_Config{prompt = "> ", prefix_width = 2}

	draw(&s, &r, &e, cfg, 80, 24)
	editor_set_cursor(&e, 3)
	editor_insert_rune(&e, 'd')
	draw(&s, &r, &e, cfg, 80, 24)

	testing.expect_value(t, screen_row_text(&s, 0), "> abcd")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 0)
	testing.expect_value(t, col, 6)
}

@(test)
test_render_multiline :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("a\nb")
	defer editor_destroy(&e)
	draw(&s, &r, &e, Render_Config{prompt = "> ", prefix_width = 2}, 80, 24)

	testing.expect_value(t, screen_row_text(&s, 0), "> a")
	testing.expect_value(t, screen_row_text(&s, 1), "  b")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 1)
	testing.expect_value(t, col, 3)
}

@(test)
test_render_hard_wrap :: proc(t: ^testing.T) {
	s := screen_init(5, 24)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("abcdef")
	defer editor_destroy(&e)
	draw(&s, &r, &e, Render_Config{prompt = "> ", prefix_width = 2}, 5, 24)

	testing.expect_value(t, screen_row_text(&s, 0), "> abc")
	testing.expect_value(t, screen_row_text(&s, 1), "  def")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 1)
	testing.expect_value(t, col, 5)
}

@(test)
test_render_finish :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("abc")
	defer editor_destroy(&e)
	draw(&s, &r, &e, Render_Config{prompt = "> ", prefix_width = 2}, 80, 24)
	finish(&s, &r)

	testing.expect_value(t, screen_row_text(&s, 0), "> abc")
	testing.expect_value(t, screen_row_text(&s, 1), "")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 1)
	testing.expect_value(t, col, 0)
}

@(test)
test_render_abort :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("abc")
	defer editor_destroy(&e)
	draw(&s, &r, &e, Render_Config{prompt = "> ", prefix_width = 2}, 80, 24)
	abort(&s, &r)

	testing.expect_value(t, screen_row_text(&s, 0), "")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 0)
	testing.expect_value(t, col, 0)
}

@(test)
test_render_window_scroll :: proc(t: ^testing.T) {
	s := screen_init(20, 4)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e: Editor
	editor_init(&e)
	defer editor_destroy(&e)
	editor_insert_text(&e, "line0\nline1\nline2\nline3\nline4")

	draw(&s, &r, &e, Render_Config{prompt = "> ", prefix_width = 2}, 20, 4)
	testing.expect_value(t, screen_row_text(&s, 0), "  …")
	testing.expect_value(t, screen_row_text(&s, 1), "  line3")
	testing.expect_value(t, screen_row_text(&s, 2), "  line4")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 2)
	testing.expect_value(t, col, 7)
}

@(test)
test_render_cjk :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("中文")
	defer editor_destroy(&e)
	editor_set_cursor(&e, 3)
	draw(&s, &r, &e, Render_Config{prompt = "> ", prefix_width = 2}, 80, 24)

	testing.expect_value(t, screen_row_text(&s, 0), "> 中文")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 0)
	testing.expect_value(t, col, 4)
}

@(test)
test_render_hint :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("git ")
	defer editor_destroy(&e)
	draw(&s, &r, &e, Render_Config{prompt = "> ", prefix_width = 2, hint = "<url>"}, 80, 24)

	testing.expect_value(t, screen_row_text(&s, 0), "> git <url>")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 0)
	testing.expect_value(t, col, 6)
}

@(test)
test_render_hint_truncated :: proc(t: ^testing.T) {
	s := screen_init(8, 24)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("abc")
	defer editor_destroy(&e)
	draw(&s, &r, &e, Render_Config{prompt = "> ", prefix_width = 2, hint = "XYZ123"}, 8, 24)

	testing.expect_value(t, screen_row_text(&s, 0), "> abcXYZ")
}

@(test)
test_render_mask_suppresses_hint :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("abc")
	defer editor_destroy(&e)
	draw(&s, &r, &e, Render_Config{prompt = "> ", prefix_width = 2, mask = true, hint = "<url>"}, 80, 24)

	testing.expect_value(t, screen_row_text(&s, 0), "> ***")
}

@(test)
test_render_completion_menu :: proc(t: ^testing.T) {
	s := screen_init(40, 10)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("he")
	defer editor_destroy(&e)
	editor_set_cursor(&e, 2)

	menu := []Completion{{text = "hello"}, {text = "help"}}
	cfg := Render_Config {
		prompt        = "> ",
		prefix_width  = 2,
		menu          = menu,
		menu_selected = 0,
	}
	draw(&s, &r, &e, cfg, 40, 10)

	testing.expect_value(t, screen_row_text(&s, 0), "> he")
	testing.expect_value(t, screen_row_text(&s, 1), "> hello")
	testing.expect_value(t, screen_row_text(&s, 2), "  help")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 0)
	testing.expect_value(t, col, 4)

	cfg.menu_selected = 1
	draw(&s, &r, &e, cfg, 40, 10)
	testing.expect_value(t, screen_row_text(&s, 1), "  hello")
	testing.expect_value(t, screen_row_text(&s, 2), "> help")
}

@(test)
test_render_completion_menu_description :: proc(t: ^testing.T) {
	s := screen_init(40, 10)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("he")
	defer editor_destroy(&e)
	editor_set_cursor(&e, 2)

	menu := []Completion{{text = "hello", description = "greeting"}}
	draw(&s, &r, &e, Render_Config {
		prompt        = "> ",
		prefix_width  = 2,
		menu          = menu,
		menu_selected = 0,
	}, 40, 10)

	testing.expect_value(t, screen_row_text(&s, 1), "> hello  greeting")
}

@(test)
test_render_completion_menu_window :: proc(t: ^testing.T) {
	s := screen_init(40, 8)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("x")
	defer editor_destroy(&e)
	editor_set_cursor(&e, 1)

	names := [10]string{"item0", "item1", "item2", "item3", "item4", "item5", "item6", "item7", "item8", "item9"}
	menu: [10]Completion
	for name, i in names {
		menu[i] = Completion{text = name}
	}
	draw(&s, &r, &e, Render_Config {
		prompt        = "> ",
		prefix_width  = 2,
		menu          = menu[:],
		menu_selected = 9,
	}, 40, 8)

	testing.expect_value(t, screen_row_text(&s, 0), "> x")
	testing.expect_value(t, screen_row_text(&s, 1), "  item7")
	testing.expect_value(t, screen_row_text(&s, 2), "  item8")
	testing.expect_value(t, screen_row_text(&s, 3), "> item9")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 0)
	testing.expect_value(t, col, 3)
}

@(test)
test_render_completion_menu_too_short :: proc(t: ^testing.T) {
	s := screen_init(40, 2)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("he")
	defer editor_destroy(&e)
	editor_set_cursor(&e, 2)

	menu := []Completion{{text = "hello"}, {text = "help"}}
	draw(&s, &r, &e, Render_Config {
		prompt        = "> ",
		prefix_width  = 2,
		menu          = menu,
		menu_selected = 0,
	}, 40, 2)

	testing.expect_value(t, screen_row_text(&s, 0), "> he")
	testing.expect_value(t, screen_row_text(&s, 1), "")
}

@(test)
test_render_completion_menu_truncated :: proc(t: ^testing.T) {
	s := screen_init(10, 6)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("x")
	defer editor_destroy(&e)
	editor_set_cursor(&e, 1)

	menu := []Completion{{text = "verylongcompletion"}}
	draw(&s, &r, &e, Render_Config {
		prompt        = "> ",
		prefix_width  = 2,
		menu          = menu,
		menu_selected = 0,
	}, 10, 6)

	testing.expect_value(t, screen_row_text(&s, 1), "> verylong")
}

@(test)
test_render_mask :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("中文")
	defer editor_destroy(&e)
	editor_set_cursor(&e, 3)
	draw(&s, &r, &e, Render_Config{prompt = "> ", prefix_width = 2, mask = true}, 80, 24)

	testing.expect_value(t, screen_row_text(&s, 0), "> **")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 0)
	testing.expect_value(t, col, 3)

	editor_set_cursor(&e, 6)
	draw(&s, &r, &e, Render_Config{prompt = "> ", prefix_width = 2, mask = true}, 80, 24)
	testing.expect_value(t, screen_row_text(&s, 0), "> **")
	row, col = screen_cursor(&s)
	testing.expect_value(t, col, 4)
}

@(test)
test_render_tab_expands_to_spaces :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	r: Renderer
	render_init(&r)

	e := editor_with("a\tb")
	defer editor_destroy(&e)
	draw(&s, &r, &e, Render_Config{prompt = "> ", prefix_width = 2}, 80, 24)

	testing.expect_value(t, screen_row_text(&s, 0), "> a       b")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 0)
	testing.expect_value(t, col, 11)
}
