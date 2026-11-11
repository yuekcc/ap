package aptui

import "core:testing"

collect_events :: proc(chunks: []string) -> [dynamic]Event {
	d: Decoder
	defer decoder_destroy(&d)
	events: [dynamic]Event
	for chunk in chunks {
		part := decode_feed(&d, transmute([]u8)chunk)
		for ev in part {
			append(&events, ev)
		}
		delete(part)
	}
	return events
}

expect_kinds :: proc(t: ^testing.T, chunks: []string, kinds: []Key_Kind) {
	events := collect_events(chunks)
	defer events_destroy(&events)
	testing.expect_value(t, len(events), len(kinds))
	for kind, i in kinds {
		if i >= len(events) {
			break
		}
		key, ok := events[i].(Key)
		if !ok {
			testing.expectf(t, false, "event %d is not a Key", i)
			continue
		}
		testing.expectf(t, key.kind == kind, "event %d: got %v, want %v", i, key.kind, kind)
	}
}

@(test)
test_decode_basic_keys :: proc(t: ^testing.T) {
	tests := []struct {
		name:   string,
		chunks: []string,
		kinds:  []Key_Kind,
	} {
		{"kitty enter", []string{"\x1b[13u"}, []Key_Kind{.Enter}},
		{"legacy enter", []string{"\r"}, []Key_Kind{.Enter}},
		{"ctrl+enter", []string{"\x1b[13;5u"}, []Key_Kind{.Ctrl_Enter}},
		{"kitty esc", []string{"\x1b[27u"}, []Key_Kind{.Escape}},
		{"backspace 0x7f", []string{"\x7f"}, []Key_Kind{.Backspace}},
		{"backspace kitty", []string{"\x1b[127u"}, []Key_Kind{.Backspace}},
		{"arrow csi", []string{"\x1b[A\x1b[B\x1b[C\x1b[D"}, []Key_Kind{.Up, .Down, .Right, .Left}},
		{"arrow ss3", []string{"\x1bOA\x1bOD"}, []Key_Kind{.Up, .Left}},
		{"arrow explicit", []string{"\x1b[1;1A"}, []Key_Kind{.Up}},
		{"modified arrow", []string{"\x1b[1;5A"}, []Key_Kind{.Up}},
		{"home end", []string{"\x1b[H\x1b[F"}, []Key_Kind{.Home, .End}},
		{"home end tilde", []string{"\x1b[1~\x1b[4~"}, []Key_Kind{.Home, .End}},
		{"delete", []string{"\x1b[3~\x1b[3;1~"}, []Key_Kind{.Delete, .Delete}},
		{"ctrl legacy", []string{"\x01\x05\x0b\x15\x17\x03"}, []Key_Kind {
			.Ctrl_A,
			.Ctrl_E,
			.Ctrl_K,
			.Ctrl_U,
			.Ctrl_W,
			.Ctrl_C,
		}},
		{"ctrl kitty", []string{"\x1b[97;5u\x1b[101;5u\x1b[107;5u\x1b[117;5u\x1b[119;5u\x1b[99;5u"}, []Key_Kind {
			.Ctrl_A,
			.Ctrl_E,
			.Ctrl_K,
			.Ctrl_U,
			.Ctrl_W,
			.Ctrl_C,
		}},
		{"alt key", []string{"\x1bx"}, []Key_Kind{.Escape, .Rune}},
	}
	for tc in tests {
		expect_kinds(t, tc.chunks, tc.kinds)
	}
}

@(test)
test_decode_unsupported_sequences :: proc(t: ^testing.T) {
	events := collect_events([]string{"\x1b[999~", "\x1b]0;title\x07"})
	defer events_destroy(&events)
	testing.expect_value(t, len(events), 2)
	for ev in events {
		_, ok := ev.(Unsupported)
		testing.expect(t, ok)
	}
}

@(test)
test_decode_split_sequences :: proc(t: ^testing.T) {
	// CSI 前缀和参数分两次到。
	expect_kinds(t, []string{"\x1b[", "13;5u"}, []Key_Kind{.Ctrl_Enter})
	// 方向键序列按字节切开。
	expect_kinds(t, []string{"\x1b", "[", "A"}, []Key_Kind{.Up})
	// UTF-8 被切开时不能丢。
	expect_kinds(t, []string{"\xe4\xb8", "\xad"}, []Key_Kind{.Rune})
}

@(test)
test_decode_utf8 :: proc(t: ^testing.T) {
	events := collect_events([]string{"中a"})
	defer events_destroy(&events)
	testing.expect_value(t, len(events), 2)
	if len(events) == 2 {
		first, _ := events[0].(Key)
		second, _ := events[1].(Key)
		testing.expect_value(t, first.r, '中')
		testing.expect_value(t, second.r, 'a')
	}
}

@(test)
test_decode_invalid_utf8_discarded :: proc(t: ^testing.T) {
	// 0xff 不是合法起始字节；坏掉的序列不能进入缓冲区，后续合法字节要保留。
	expect_kinds(t, []string{"\xff"}, []Key_Kind{.Ignore})
	expect_kinds(t, []string{"\xe4\xb8", "A"}, []Key_Kind{.Rune})
}

@(test)
test_decode_paste :: proc(t: ^testing.T) {
	events := collect_events([]string{"\x1b[200~hello\r\nworld\x1b[201~"})
	defer events_destroy(&events)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		paste, ok := events[0].(Paste)
		testing.expect(t, ok)
		// \r 被删掉，\n 保留；粘贴内容不当作按键。
		testing.expect_value(t, paste.text, "hello\nworld")
	}
}

@(test)
test_decode_paste_split_terminator :: proc(t: ^testing.T) {
	events := collect_events([]string{"\x1b[200~abc\x1b[20", "1~"})
	defer events_destroy(&events)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		paste, ok := events[0].(Paste)
		testing.expect(t, ok)
		testing.expect_value(t, paste.text, "abc")
	}
}

@(test)
test_decode_timeout_flush :: proc(t: ^testing.T) {
	d: Decoder
	defer decoder_destroy(&d)

	// legacy 孤立 ESC 在超时后落地。
	esc := "\x1b"
	part := decode_feed(&d, transmute([]u8)esc)
	delete(part)
	events := decode_timeout(&d)
	defer events_destroy(&events)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		key, ok := events[0].(Key)
		testing.expect(t, ok)
		testing.expect_value(t, key.kind, .Escape)
	}
}

@(test)
test_decode_timeout_flush_paste :: proc(t: ^testing.T) {
	d: Decoder
	defer decoder_destroy(&d)

	paste_start := "\x1b[200~abc"
	part := decode_feed(&d, transmute([]u8)paste_start)
	delete(part)
	events := decode_timeout(&d)
	defer events_destroy(&events)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		paste, ok := events[0].(Paste)
		testing.expect(t, ok)
		testing.expect_value(t, paste.text, "abc")
	}
}

@(test)
test_term_pending_queue :: proc(t: ^testing.T) {
	term: Term
	data := "abc"
	term_push_pending(&term, transmute([]u8)data)

	buf: [4]u8
	n, timed_out, eof := term_read_chunk(&term, buf[:2], -1)
	testing.expect_value(t, n, 2)
	testing.expect(t, !timed_out)
	testing.expect(t, !eof)
	testing.expect_value(t, string(buf[:n]), "ab")

	n, _, _ = term_read_chunk(&term, buf[:], -1)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, string(buf[:n]), "c")
	testing.expect_value(t, term.pending_len, 0)
}

@(test)
test_term_pending_kitty :: proc(t: ^testing.T) {
	term: Term
	yes := "\x1b[?1u"
	term_push_pending(&term, transmute([]u8)yes)
	complete, kitty := term_pending_kitty(&term)
	testing.expect(t, complete)
	testing.expect(t, kitty)

	term = {}
	no := "\x1b[?0u"
	term_push_pending(&term, transmute([]u8)no)
	complete, kitty = term_pending_kitty(&term)
	testing.expect(t, complete)
	testing.expect(t, !kitty)

	term = {}
	partial := "\x1b[?"
	term_push_pending(&term, transmute([]u8)partial)
	complete, _ = term_pending_kitty(&term)
	testing.expect(t, !complete)
}

@(test)
test_decode_numpad :: proc(t: ^testing.T) {
	// application keypad 模式：数字走 SS3 p-y，Enter 是 SS3 M，其余按键是运算符。
	events := collect_events([]string{"\x1bOp\x1bOq\x1bOs\x1bOy\x1bOu\x1bOM\x1bOk\x1bOm\x1bOn\x1bOl"})
	defer events_destroy(&events)
	want := []struct {
		kind: Key_Kind,
		r:    rune,
	} {
		{.Rune, '0'},
		{.Rune, '1'},
		{.Rune, '3'},
		{.Rune, '9'},
		{.Rune, '5'},
		{.Enter, 0},
		{.Rune, '+'},
		{.Rune, '-'},
		{.Rune, '.'},
		{.Rune, ','},
	}
	testing.expect_value(t, len(events), len(want))
	for w, i in want {
		if i >= len(events) {
			break
		}
		key, ok := events[i].(Key)
		if !ok {
			testing.expectf(t, false, "event %d is not a Key", i)
			continue
		}
		testing.expectf(t, key.kind == w.kind && key.r == w.r, "event %d: got %v %q", i, key.kind, key.r)
	}
}

@(test)
test_decode_numpad_navigation_ignored :: proc(t: ^testing.T) {
	// NumLock 关闭且不在 application keypad 模式：小键盘发来 Begin / Insert / PgUp / PgDn。
	expect_kinds(
		t,
		[]string{"\x1b[E\x1b[2~\x1b[5~\x1b[6~"},
		[]Key_Kind{.Ignore, .Ignore, .Ignore, .Ignore},
	)
}

@(test)
test_decode_modified_arrows :: proc(t: ^testing.T) {
	events := collect_events(
		[]string{"\x1b[1;5C", "\x1b[1;3D", "\x1b[1;2A", "\x1b[1;6B", "\x1b[1;5H", "\x1b[1;5F"},
	)
	defer events_destroy(&events)
	cases := []struct {
		kind: Key_Kind,
		mods: Key_Mods,
	} {
		{.Right, {.Ctrl}},
		{.Left, {.Alt}},
		{.Up, {.Shift}},
		{.Down, {.Shift, .Ctrl}},
		{.Home, {.Ctrl}},
		{.End, {.Ctrl}},
	}
	testing.expect_value(t, len(events), len(cases))
	for c, i in cases {
		if i >= len(events) {
			break
		}
		key, ok := events[i].(Key)
		if !ok {
			testing.expectf(t, false, "event %d is not a Key", i)
			continue
		}
		testing.expectf(
			t,
			key.kind == c.kind && key.mods == c.mods,
			"event %d: got %v %v, want %v %v",
			i,
			key.kind,
			key.mods,
			c.kind,
			c.mods,
		)
	}
}

@(test)
test_decode_kitty_modifiers :: proc(t: ^testing.T) {
	// 小键盘 Enter 和 Shift+字符走 CSI-u，修饰键用第二个参数编码。
	events := collect_events([]string{"\x1b[13;1u", "\x1b[97;2u"})
	defer events_destroy(&events)
	testing.expect_value(t, len(events), 2)
	if len(events) != 2 {
		return
	}
	enter, _ := events[0].(Key)
	testing.expect_value(t, enter.kind, Key_Kind.Enter)
	testing.expect_value(t, enter.mods, Key_Mods{})

	rune_key, _ := events[1].(Key)
	testing.expect_value(t, rune_key.kind, Key_Kind.Rune)
	testing.expect_value(t, rune_key.r, 'a')
	testing.expect_value(t, rune_key.mods, Key_Mods{.Shift})
}
