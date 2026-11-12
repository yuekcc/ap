package lineedit

import "core:strings"
import "core:testing"

Fake_Term :: struct {
	screen:   ^Screen,
	input:    [dynamic]u8,
	pos:      int,
	cols:     int,
	rows:     int,
	chunk:    int,
	tty:      bool,
	raw:      bool,
	writes:   int,
	timeouts: int,
	eofs:     int,
}

fake_term_destroy :: proc(f: ^Fake_Term) {
	delete(f.input)
}

fake_transport :: proc(f: ^Fake_Term) -> Transport {
	return Transport {
		ctx = f,
		read = fake_read,
		write = fake_write,
		size = fake_size,
		enter_raw = fake_enter_raw,
		leave_raw = fake_leave_raw,
	}
}

fake_input :: proc(f: ^Fake_Term, text: string) {
	data := transmute([]u8)text
	for b in data {
		append(&f.input, b)
	}
}

fake_read :: proc(ctx: rawptr, buf: []u8, timeout_ms: int) -> (n: int, timed_out: bool, eof: bool) {
	f := cast(^Fake_Term)ctx
	if f.pos >= len(f.input) {
		if timeout_ms >= 0 {
			f.timeouts += 1
			return 0, true, false
		}
		f.eofs += 1
		return 0, false, true
	}
	limit := len(buf)
	if f.chunk > 0 {
		limit = min(limit, f.chunk)
	}
	n = min(limit, len(f.input) - f.pos)
	copy(buf[:n], f.input[f.pos:f.pos + n])
	f.pos += n
	return n, false, false
}

fake_write :: proc(ctx: rawptr, data: []u8) -> bool {
	f := cast(^Fake_Term)ctx
	if f.screen != nil {
		screen_feed(f.screen, data)
	}
	f.writes += 1
	return true
}

fake_size :: proc(ctx: rawptr) -> (cols, rows: int) {
	f := cast(^Fake_Term)ctx
	return f.cols, f.rows
}

fake_enter_raw :: proc(ctx: rawptr) -> bool {
	f := cast(^Fake_Term)ctx
	if !f.tty {
		return false
	}
	f.raw = true
	return true
}

fake_leave_raw :: proc(ctx: rawptr) {
	f := cast(^Fake_Term)ctx
	f.raw = false
}

new_fake_editor :: proc(
	t: ^testing.T,
	f: ^Fake_Term,
	s: ^Screen,
	cols := 80,
	rows := 24,
	chunk := 4,
	tty := true,
) -> (Line_Editor, bool) {
	f.screen = s
	f.cols = cols
	f.rows = rows
	f.chunk = chunk
	f.tty = tty
	le: Line_Editor
	ok := line_editor_init_transport(&le, fake_transport(f))
	testing.expect(t, ok)
	return le, ok
}

expect_line :: proc(t: ^testing.T, le: ^Line_Editor, prompt, want: string) {
	line, status := line_editor_read_line(le, prompt)
	testing.expect_value(t, status, Read_Status.Ok)
	testing.expect_value(t, line, want)
	delete(line)
}

@(test)
test_line_editor_basic :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, chunk = 4)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	fake_input(&f, "abc\r")
	expect_line(t, &le, "> ", "abc")

	testing.expect_value(t, screen_row_text(&s, 0), "> abc")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 1)
	testing.expect_value(t, col, 0)
	testing.expect(t, f.raw)
}

@(test)
test_line_editor_backspace :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, chunk = 1)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	fake_input(&f, "ab\x7fc\r")
	expect_line(t, &le, "> ", "ac")
	testing.expect_value(t, screen_row_text(&s, 0), "> ac")
}

@(test)
test_line_editor_multiline_kitty :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, chunk = 1)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	// kitty 的 Shift+Enter 是 CSI 13;2u；legacy 下没有等价编码。
	fake_input(&f, "a\x1b[13;2ub\r")
	expect_line(t, &le, "> ", "a\nb")
	testing.expect_value(t, screen_row_text(&s, 0), "> a")
	testing.expect_value(t, screen_row_text(&s, 1), "  b")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 2)
	testing.expect_value(t, col, 0)
}

@(test)
test_line_editor_paste :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, chunk = 1)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	fake_input(&f, "\x1b[200~x\ny\x1b[201~\r")
	expect_line(t, &le, "> ", "x\ny")
	testing.expect_value(t, screen_row_text(&s, 0), "> x")
	testing.expect_value(t, screen_row_text(&s, 1), "  y")
}

@(test)
test_line_editor_cancel_and_eof :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, chunk = 1)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	fake_input(&f, "\x03")
	line, status := line_editor_read_line(&le, "> ")
	testing.expect_value(t, status, Read_Status.Cancel)
	testing.expect_value(t, line, "")
	testing.expect_value(t, screen_row_text(&s, 0), "")

	f.pos = 0
	clear(&f.input)
	fake_input(&f, "\x04")
	line, status = line_editor_read_line(&le, "> ")
	testing.expect_value(t, status, Read_Status.Eof)
	testing.expect_value(t, line, "")

	// 输入耗尽且没有提交，也按 EOF 处理。
	clear(&f.input)
	f.pos = 0
	line, status = line_editor_read_line(&le, "> ")
	testing.expect_value(t, status, Read_Status.Eof)
	testing.expect_value(t, line, "")
}

@(test)
test_line_editor_history :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, chunk = 4)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	fake_input(&f, "one\r")
	expect_line(t, &le, "> ", "one")

	fake_input(&f, "two\r")
	expect_line(t, &le, "> ", "two")

	fake_input(&f, "\x1b[A\r")
	expect_line(t, &le, "> ", "two")
}

@(test)
test_line_editor_mask :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, chunk = 2)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)
	le.config.mask = true

	fake_input(&f, "secret\r")
	expect_line(t, &le, "> ", "secret")
	testing.expect_value(t, screen_row_text(&s, 0), "> ******")
}

Hint_Ctx :: struct {
	calls: int,
}

test_hint_proc :: proc(ctx: rawptr, line: string, cursor: int) -> string {
	c := cast(^Hint_Ctx)ctx
	c.calls += 1
	_, _ = line, cursor
	if line == "a" {
		return "<hint>"
	}
	return ""
}

@(test)
test_line_editor_hint :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, chunk = 4)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	ctx: Hint_Ctx
	le.config.hint = test_hint_proc
	le.config.hint_ctx = &ctx

	fake_input(&f, "a\r")
	expect_line(t, &le, "> ", "a")
	testing.expect(t, ctx.calls > 0)
	// 提交前会用不带 hint 的帧重绘，提示不会留在最终行上。
	testing.expect_value(t, screen_row_text(&s, 0), "> a")
}

Completion_Ctx :: struct {
	calls:  int,
	single: bool,
	none:   bool,
}

test_completer_proc :: proc(ctx: rawptr, line: string, cursor: int, out: ^[dynamic]Completion) {
	c := cast(^Completion_Ctx)ctx
	c.calls += 1
	_, _ = line, cursor
	if c.none {
		return
	}
	if c.single {
		a, _ := strings.clone("hello")
		append(out, Completion{text = a})
		return
	}
	a, _ := strings.clone("hello")
	b, _ := strings.clone("help")
	append(out, Completion{text = a})
	append(out, Completion{text = b})
}

@(test)
test_line_editor_completion :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, chunk = 1)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	ctx: Completion_Ctx
	le.config.completer = Completer{ctx = &ctx, complete = test_completer_proc}

	fake_input(&f, "he\t\r")
	expect_line(t, &le, "> ", "hel")
	testing.expect_value(t, ctx.calls, 1)
	testing.expect_value(t, screen_row_text(&s, 0), "> hel")
}

@(test)
test_line_editor_completion_menu :: proc(t: ^testing.T) {
	s := screen_init(40, 10)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, cols = 40, rows = 10, chunk = 8)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	ctx: Completion_Ctx
	le.config.completer = Completer{ctx = &ctx, complete = test_completer_proc}
	testing.expect(t, line_editor_begin(&le, "> "))

	text := "he\t"
	line, status := line_editor_feed(&le, transmute([]u8)text)
	testing.expect_value(t, status, Feed_Status.Continue)
	testing.expect_value(t, line, "")
	testing.expect_value(t, editor_text(&le.editor), "hel")
	testing.expect_value(t, screen_row_text(&s, 0), "> hel")
	testing.expect_value(t, screen_row_text(&s, 1), "  hello")
	testing.expect_value(t, screen_row_text(&s, 2), "  help")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 0)
	testing.expect_value(t, col, 5)

	tab := "\t"
	line, status = line_editor_feed(&le, transmute([]u8)tab)
	testing.expect_value(t, status, Feed_Status.Continue)
	testing.expect_value(t, line, "")
	testing.expect_value(t, editor_text(&le.editor), "hello")
	testing.expect_value(t, screen_row_text(&s, 0), "> hello")
	testing.expect_value(t, screen_row_text(&s, 1), "> hello")
	testing.expect_value(t, screen_row_text(&s, 2), "  help")

	enter := "\r"
	line, status = line_editor_feed(&le, transmute([]u8)enter)
	testing.expect_value(t, status, Feed_Status.Submitted)
	testing.expect_value(t, line, "hello")
	delete(line)
	testing.expect_value(t, screen_row_text(&s, 0), "> hello")
	testing.expect_value(t, screen_row_text(&s, 1), "")
}

@(test)
test_line_editor_completion_menu_escape :: proc(t: ^testing.T) {
	s := screen_init(40, 10)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, cols = 40, rows = 10, chunk = 8)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	ctx: Completion_Ctx
	le.config.completer = Completer{ctx = &ctx, complete = test_completer_proc}
	testing.expect(t, line_editor_begin(&le, "> "))

	text := "he\t"
	_, status := line_editor_feed(&le, transmute([]u8)text)
	testing.expect_value(t, status, Feed_Status.Continue)
	testing.expect_value(t, editor_text(&le.editor), "hel")

	esc := "\x1b[27u"
	_, status = line_editor_feed(&le, transmute([]u8)esc)
	testing.expect_value(t, status, Feed_Status.Continue)
	// Esc 只关菜单，不清空输入。
	testing.expect_value(t, editor_text(&le.editor), "hel")
	testing.expect_value(t, screen_row_text(&s, 0), "> hel")
	testing.expect_value(t, screen_row_text(&s, 1), "")

	enter := "\r"
	line, submit_status := line_editor_feed(&le, transmute([]u8)enter)
	testing.expect_value(t, submit_status, Feed_Status.Submitted)
	testing.expect_value(t, line, "hel")
	delete(line)
}

@(test)
test_line_editor_completion_menu_typing_dismisses :: proc(t: ^testing.T) {
	s := screen_init(40, 10)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, cols = 40, rows = 10, chunk = 8)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	ctx: Completion_Ctx
	le.config.completer = Completer{ctx = &ctx, complete = test_completer_proc}
	testing.expect(t, line_editor_begin(&le, "> "))

	text := "he\t"
	_, status := line_editor_feed(&le, transmute([]u8)text)
	testing.expect_value(t, status, Feed_Status.Continue)
	testing.expect_value(t, editor_text(&le.editor), "hel")

	more := "x"
	_, status = line_editor_feed(&le, transmute([]u8)more)
	testing.expect_value(t, status, Feed_Status.Continue)
	testing.expect_value(t, editor_text(&le.editor), "helx")
	testing.expect_value(t, screen_row_text(&s, 0), "> helx")
	testing.expect_value(t, screen_row_text(&s, 1), "")
}

@(test)
test_line_editor_completion_menu_arrows :: proc(t: ^testing.T) {
	s := screen_init(40, 10)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, cols = 40, rows = 10, chunk = 8)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	ctx: Completion_Ctx
	le.config.completer = Completer{ctx = &ctx, complete = test_completer_proc}
	testing.expect(t, line_editor_begin(&le, "> "))

	text := "he\t"
	_, _ = line_editor_feed(&le, transmute([]u8)text)
	testing.expect_value(t, editor_text(&le.editor), "hel")

	up := "\x1b[A"
	_, status := line_editor_feed(&le, transmute([]u8)up)
	testing.expect_value(t, status, Feed_Status.Continue)
	testing.expect_value(t, editor_text(&le.editor), "help")
	testing.expect_value(t, screen_row_text(&s, 1), "  hello")
	testing.expect_value(t, screen_row_text(&s, 2), "> help")

	down := "\x1b[B"
	_, status = line_editor_feed(&le, transmute([]u8)down)
	testing.expect_value(t, status, Feed_Status.Continue)
	testing.expect_value(t, editor_text(&le.editor), "hello")
	testing.expect_value(t, screen_row_text(&s, 1), "> hello")
	testing.expect_value(t, screen_row_text(&s, 2), "  help")
}

@(test)
test_line_editor_completion_menu_shift_tab :: proc(t: ^testing.T) {
	s := screen_init(40, 10)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, cols = 40, rows = 10, chunk = 8)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	ctx: Completion_Ctx
	le.config.completer = Completer{ctx = &ctx, complete = test_completer_proc}
	testing.expect(t, line_editor_begin(&le, "> "))

	text := "he\t"
	_, _ = line_editor_feed(&le, transmute([]u8)text)
	testing.expect_value(t, editor_text(&le.editor), "hel")

	shift_tab := "\x1b[Z"
	_, status := line_editor_feed(&le, transmute([]u8)shift_tab)
	testing.expect_value(t, status, Feed_Status.Continue)
	testing.expect_value(t, editor_text(&le.editor), "help")
}

@(test)
test_line_editor_completion_single_no_menu :: proc(t: ^testing.T) {
	s := screen_init(40, 10)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, cols = 40, rows = 10, chunk = 8)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	ctx: Completion_Ctx
	ctx.single = true
	le.config.completer = Completer{ctx = &ctx, complete = test_completer_proc}
	testing.expect(t, line_editor_begin(&le, "> "))

	text := "he\t"
	_, status := line_editor_feed(&le, transmute([]u8)text)
	testing.expect_value(t, status, Feed_Status.Continue)
	testing.expect_value(t, editor_text(&le.editor), "hello")
	testing.expect_value(t, screen_row_text(&s, 0), "> hello")
	testing.expect_value(t, screen_row_text(&s, 1), "")
}

@(test)
test_line_editor_completion_none :: proc(t: ^testing.T) {
	s := screen_init(40, 10)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, cols = 40, rows = 10, chunk = 8)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	ctx: Completion_Ctx
	ctx.none = true
	le.config.completer = Completer{ctx = &ctx, complete = test_completer_proc}
	testing.expect(t, line_editor_begin(&le, "> "))

	text := "he\t"
	_, status := line_editor_feed(&le, transmute([]u8)text)
	testing.expect_value(t, status, Feed_Status.Continue)
	testing.expect_value(t, editor_text(&le.editor), "he")
	testing.expect_value(t, screen_row_text(&s, 1), "")
}

@(test)
test_line_editor_completion_disabled_in_mask :: proc(t: ^testing.T) {
	s := screen_init(40, 10)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, cols = 40, rows = 10, chunk = 8)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)
	le.config.mask = true

	ctx: Completion_Ctx
	le.config.completer = Completer{ctx = &ctx, complete = test_completer_proc}
	testing.expect(t, line_editor_begin(&le, "> "))

	text := "he\t"
	_, status := line_editor_feed(&le, transmute([]u8)text)
	testing.expect_value(t, status, Feed_Status.Continue)
	testing.expect_value(t, editor_text(&le.editor), "he")
	testing.expect_value(t, ctx.calls, 0)
	testing.expect_value(t, screen_row_text(&s, 0), "> **")
	testing.expect_value(t, screen_row_text(&s, 1), "")
}

@(test)
test_line_editor_completion_no_completer_tab :: proc(t: ^testing.T) {
	s := screen_init(40, 10)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, cols = 40, rows = 10, chunk = 8)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	fake_input(&f, "he\t\r")
	expect_line(t, &le, "> ", "he\t")
}

@(test)
test_line_editor_feed_api :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	testing.expect(t, line_editor_begin(&le, "> "))
	text := "ab"
	line, status := line_editor_feed(&le, transmute([]u8)text)
	testing.expect_value(t, status, Feed_Status.Continue)
	testing.expect_value(t, line, "")
	testing.expect_value(t, screen_row_text(&s, 0), "> ab")

	enter := "\r"
	line, status = line_editor_feed(&le, transmute([]u8)enter)
	testing.expect_value(t, status, Feed_Status.Submitted)
	testing.expect_value(t, line, "ab")
	delete(line)
	testing.expect(t, !le.active)
}

@(test)
test_line_editor_feed_timeout_escape :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	testing.expect(t, line_editor_begin(&le, "> "))
	esc := "\x1b"
	_, status := line_editor_feed(&le, transmute([]u8)esc)
	testing.expect_value(t, status, Feed_Status.Continue)
	testing.expect_value(t, line_editor_poll_timeout(&le), ESC_TIMEOUT_MS)

	line, timeout_status := line_editor_timeout(&le)
	testing.expect_value(t, timeout_status, Feed_Status.Continue)
	testing.expect_value(t, line, "")
	testing.expect(t, le.active)
	line_editor_abort_line(&le)
	testing.expect(t, !le.active)
}

@(test)
test_line_editor_feed_timeout_paste :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	testing.expect(t, line_editor_begin(&le, "> "))
	start := "\x1b[200~abc"
	line, status := line_editor_feed(&le, transmute([]u8)start)
	testing.expect_value(t, status, Feed_Status.Continue)
	testing.expect_value(t, line_editor_poll_timeout(&le), PASTE_FLUSH_MS)

	line, status = line_editor_timeout(&le)
	testing.expect_value(t, status, Feed_Status.Continue)
	testing.expect_value(t, line, "")
	testing.expect_value(t, screen_row_text(&s, 0), "> abc")
	testing.expect_value(t, line_editor_poll_timeout(&le), -1)
}

@(test)
test_line_editor_feed_requires_begin :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	data := "a"
	line, status := line_editor_feed(&le, transmute([]u8)data)
	testing.expect_value(t, status, Feed_Status.Error)
	testing.expect_value(t, line, "")
}

@(test)
test_line_editor_resize :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	testing.expect(t, line_editor_begin(&le, "> "))
	before := f.writes
	testing.expect(t, line_editor_resize(&le))
	testing.expect(t, f.writes > before)
}

@(test)
test_line_editor_hide_show :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)

	testing.expect(t, line_editor_begin(&le, "> "))
	data := "ab"
	_, status := line_editor_feed(&le, transmute([]u8)data)
	testing.expect_value(t, status, Feed_Status.Continue)
	testing.expect_value(t, screen_row_text(&s, 0), "> ab")

	testing.expect(t, line_editor_hide(&le))
	testing.expect_value(t, screen_row_text(&s, 0), "")

	line_editor_write_string(&le, "async\r\n")
	testing.expect(t, line_editor_show(&le))
	testing.expect_value(t, screen_row_text(&s, 0), "async")
	testing.expect_value(t, screen_row_text(&s, 1), "> ab")
	row, col := screen_cursor(&s)
	testing.expect_value(t, row, 1)
	testing.expect_value(t, col, 4)
}

@(test)
test_line_editor_pipe_mode :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	le, ok := new_fake_editor(t, &f, &s, chunk = 3, tty = false)
	if !ok {
		return
	}
	defer line_editor_destroy(&le)
	testing.expect(t, !le.raw)
	testing.expect(t, !f.raw)

	fake_input(&f, "a\r\nb\n")
	expect_line(t, &le, "> ", "a")
	expect_line(t, &le, "> ", "b")

	line, status := line_editor_read_line(&le, "> ")
	testing.expect_value(t, status, Read_Status.Eof)
	testing.expect_value(t, line, "")
}

@(test)
test_line_editor_raw_balance :: proc(t: ^testing.T) {
	s := screen_init(80, 24)
	defer screen_destroy(&s)
	f: Fake_Term
	defer fake_term_destroy(&f)

	{
		le, ok := new_fake_editor(t, &f, &s)
		if !ok {
			return
		}
		testing.expect(t, f.raw)
		line_editor_leave_raw(&le)
		testing.expect(t, !le.raw)
		testing.expect(t, !f.raw)
		testing.expect(t, line_editor_enter_raw(&le))
		testing.expect(t, f.raw)
		line_editor_destroy(&le)
	}
	testing.expect(t, !f.raw)
}
