package lineedit

import "core:testing"

collect :: proc(chunks: []string) -> [dynamic]Event {
	d: Decoder
	decoder_init(&d)
	defer decoder_destroy(&d)

	events: [dynamic]Event
	for chunk in chunks {
		part := decode_feed(&d, transmute([]u8)chunk)
		for ev in part {
			append(&events, ev)
		}
		// 事件数组的所有权已经转移；Paste.text 由 events_destroy 释放。
		delete(part)
	}
	return events
}

key :: proc(kind: Key_Kind, r: rune = 0, mods: Key_Mods = {}) -> Key {
	return Key{kind = kind, r = r, mods = mods}
}

feed :: proc(d: ^Decoder, s: string) -> [dynamic]Event {
	return decode_feed(d, transmute([]u8)s)
}

expect_keys :: proc(t: ^testing.T, chunks: []string, want: []Key) {
	events := collect(chunks)
	defer events_destroy(&events)

	testing.expect_value(t, len(events), len(want))
	for w, i in want {
		if i >= len(events) {
			break
		}
		got, ok := events[i].(Key)
		if !ok {
			testing.expectf(t, false, "event %d is not a Key: %v", i, events[i])
			continue
		}
		testing.expectf(t, got == w, "event %d: got %v, want %v", i, got, w)
	}
}

@(test)
test_decode_ascii :: proc(t: ^testing.T) {
	expect_keys(t, []string{"a"}, []Key{key(.Rune, 'a')})
	expect_keys(t, []string{"abc"}, []Key{key(.Rune, 'a'), key(.Rune, 'b'), key(.Rune, 'c')})
}

@(test)
test_decode_utf8_and_split :: proc(t: ^testing.T) {
	expect_keys(t, []string{"中"}, []Key{key(.Rune, '中')})
	expect_keys(t, []string{"\xe4\xb8", "\xad"}, []Key{key(.Rune, '中')})
	expect_keys(t, []string{"é"}, []Key{key(.Rune, 'é')})
}

@(test)
test_decode_legacy_controls :: proc(t: ^testing.T) {
	expect_keys(t, []string{"\r"}, []Key{key(.Enter)})
	expect_keys(t, []string{"\n"}, []Key{key(.Enter)})
	expect_keys(t, []string{"\x7f"}, []Key{key(.Backspace)})
	expect_keys(t, []string{"\x08"}, []Key{key(.Backspace)})
	expect_keys(t, []string{"\t"}, []Key{key(.Tab)})
	expect_keys(t, []string{"\x01"}, []Key{key(.Rune, 'a', {.Ctrl})})
	expect_keys(t, []string{"\x05"}, []Key{key(.Rune, 'e', {.Ctrl})})
	expect_keys(t, []string{"\x03"}, []Key{key(.Rune, 'c', {.Ctrl})})
}

@(test)
test_decode_invalid_utf8 :: proc(t: ^testing.T) {
	expect_keys(t, []string{"\xff"}, []Key{key(.Ignore)})
	// 非法起始字节丢弃，后面的 ASCII 必须保留。
	expect_keys(t, []string{"\xffa"}, []Key{key(.Ignore), key(.Rune, 'a')})
	// 残缺的多字节序列丢弃，后面的 ASCII 必须保留。
	expect_keys(t, []string{"\xe4\xb8", "a"}, []Key{key(.Ignore), key(.Rune, 'a')})
}

@(test)
test_decode_legacy_alt :: proc(t: ^testing.T) {
	expect_keys(t, []string{"\x1bx"}, []Key{key(.Rune, 'x', {.Alt})})
	expect_keys(t, []string{"\x1b\r"}, []Key{key(.Enter, 0, {.Alt})})
	expect_keys(t, []string{"\x1b中"}, []Key{key(.Rune, '中', {.Alt})})
	// Alt 只作用于紧跟的一个键。
	expect_keys(t, []string{"\x1bxa"}, []Key {
		key(.Rune, 'x', {.Alt}),
		key(.Rune, 'a'),
	})
}

@(test)
test_decode_timeout :: proc(t: ^testing.T) {
	d: Decoder
	decoder_init(&d)
	defer decoder_destroy(&d)

	// 孤立的 ESC 在超时后落地。
	part := feed(&d, "\x1b")
	delete(part)
	testing.expect(t, decoder_incomplete(&d))
	events := decode_timeout(&d)
	defer events_destroy(&events)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		got, ok := events[0].(Key)
		testing.expect(t, ok)
		testing.expect_value(t, got, key(.Escape))
	}
	testing.expect(t, !decoder_incomplete(&d))
}

@(test)
test_decode_timeout_incomplete_csi :: proc(t: ^testing.T) {
	d: Decoder
	decoder_init(&d)
	defer decoder_destroy(&d)

	part := feed(&d, "\x1b[")
	delete(part)
	testing.expect(t, decoder_incomplete(&d))
	events := decode_timeout(&d)
	defer events_destroy(&events)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		_, ok := events[0].(Key)
		testing.expect(t, ok)
		got, _ := events[0].(Key)
		testing.expect_value(t, got.kind, .Ignore)
	}
	testing.expect(t, !decoder_incomplete(&d))
}

@(test)
test_decode_arrows_and_navigation :: proc(t: ^testing.T) {
	expect_keys(t, []string{"\x1b[A\x1b[B\x1b[C\x1b[D"}, []Key {
		key(.Up),
		key(.Down),
		key(.Right),
		key(.Left),
	})
	expect_keys(t, []string{"\x1bOA\x1bOD"}, []Key{key(.Up), key(.Left)})
	expect_keys(t, []string{"\x1b[1;1A"}, []Key{key(.Up)})
	expect_keys(t, []string{"\x1b[1;5A"}, []Key{key(.Up, 0, {.Ctrl})})
	expect_keys(t, []string{"\x1b[1;2B"}, []Key{key(.Down, 0, {.Shift})})
	expect_keys(t, []string{"\x1b[1;3C"}, []Key{key(.Right, 0, {.Alt})})
	expect_keys(t, []string{"\x1b[H\x1b[F"}, []Key{key(.Home), key(.End)})
	expect_keys(t, []string{"\x1b[1~\x1b[4~\x1b[7~\x1b[8~"}, []Key {
		key(.Home),
		key(.End),
		key(.Home),
		key(.End),
	})
	expect_keys(t, []string{"\x1b[2~\x1b[3~\x1b[5~\x1b[6~"}, []Key {
		key(.Insert),
		key(.Delete),
		key(.Page_Up),
		key(.Page_Down),
	})
	expect_keys(t, []string{"\x1b[Z"}, []Key{key(.Tab, 0, {.Shift})})
}

@(test)
test_decode_split_csi :: proc(t: ^testing.T) {
	expect_keys(t, []string{"\x1b[", "1;5", "A"}, []Key{key(.Up, 0, {.Ctrl})})
	expect_keys(t, []string{"\x1b[", "3", "~"}, []Key{key(.Delete)})
}

@(test)
test_decode_kitty_keys :: proc(t: ^testing.T) {
	expect_keys(t, []string{"\x1b[97u"}, []Key{key(.Rune, 'a')})
	expect_keys(t, []string{"\x1b[97;5u"}, []Key{key(.Rune, 'a', {.Ctrl})})
	expect_keys(t, []string{"\x1b[97;3u"}, []Key{key(.Rune, 'a', {.Alt})})
	expect_keys(t, []string{"\x1b[97;2u"}, []Key{key(.Rune, 'a', {.Shift})})
	// Ctrl+I 与 Tab 在 kitty 下可以区分。
	expect_keys(t, []string{"\x1b[9u"}, []Key{key(.Tab)})
	expect_keys(t, []string{"\x1b[105;5u"}, []Key{key(.Rune, 'i', {.Ctrl})})
	// Ctrl+M 与 Enter 同理。
	expect_keys(t, []string{"\x1b[13u"}, []Key{key(.Enter)})
	expect_keys(t, []string{"\x1b[13;5u"}, []Key{key(.Enter, 0, {.Ctrl})})
	expect_keys(t, []string{"\x1b[13;2u"}, []Key{key(.Enter, 0, {.Shift})})
	expect_keys(t, []string{"\x1b[109;5u"}, []Key{key(.Rune, 'm', {.Ctrl})})
	expect_keys(t, []string{"\x1b[27u"}, []Key{key(.Escape)})
	expect_keys(t, []string{"\x1b[127u"}, []Key{key(.Backspace)})
	expect_keys(t, []string{"\x1b[9;2u"}, []Key{key(.Tab, 0, {.Shift})})
}

@(test)
test_decode_kitty_modifier_locks_and_unsupported :: proc(t: ^testing.T) {
	// CapsLock/NumLock 位必须接受但不能影响语义。
	expect_keys(t, []string{"\x1b[97;65u"}, []Key{key(.Rune, 'a')})
	expect_keys(t, []string{"\x1b[97;129u"}, []Key{key(.Rune, 'a')})
	expect_keys(t, []string{"\x1b[97;u"}, []Key{key(.Rune, 'a')})
	// Super 等不支持的修饰键不能退化成无修饰插入。
	expect_unsupported(t, []string{"\x1b[97;9u"})
	expect_unsupported(t, []string{"\x1b[97;17u"})
}

@(test)
test_decode_kitty_functional_keys :: proc(t: ^testing.T) {
	expect_keys(t, []string{"\x1b[57399u\x1b[57408u"}, []Key {
		key(.Rune, '0'),
		key(.Rune, '9'),
	})
	expect_keys(t, []string{"\x1b[57414u"}, []Key{key(.Enter)})
	expect_keys(t, []string{"\x1b[57417u\x1b[57418u\x1b[57419u\x1b[57420u"}, []Key {
		key(.Left),
		key(.Right),
		key(.Up),
		key(.Down),
	})
	expect_keys(t, []string{"\x1b[57423u\x1b[57424u\x1b[57426u"}, []Key {
		key(.Home),
		key(.End),
		key(.Delete),
	})
}

@(test)
test_decode_unknown_and_string_sequences :: proc(t: ^testing.T) {
	expect_unsupported(t, []string{"\x1b[999~"})
	expect_unsupported(t, []string{"\x1b[?1u"})
	expect_unsupported(t, []string{"\x1b]0;title\x07"})
	expect_unsupported(t, []string{"\x1b]0;title\x1b\\"})
	expect_unsupported(t, []string{"\x1bP1;2;3q\x1b\\"})
	// String 序列跨 chunk 时不能把内容当正文。
	expect_unsupported(t, []string{"\x1b]0;ti", "tle\x07"})
}

expect_unsupported :: proc(t: ^testing.T, chunks: []string) {
	events := collect(chunks)
	defer events_destroy(&events)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		_, ok := events[0].(Unsupported)
		testing.expect(t, ok)
	}
}

expect_paste :: proc(t: ^testing.T, chunks: []string, want: string) {
	events := collect(chunks)
	defer events_destroy(&events)
	testing.expect_value(t, len(events), 1)
	if len(events) != 1 {
		return
	}
	got, ok := events[0].(Paste)
	testing.expect(t, ok)
	testing.expect_value(t, got.text, want)
	testing.expect(t, !got.truncated)
}

@(test)
test_decode_paste :: proc(t: ^testing.T) {
	expect_paste(t, []string{"\x1b[200~hello\x1b[201~"}, "hello")
	expect_paste(t, []string{"\x1b[200~a\r\nb\rc\x1b[201~"}, "a\nb\nc")
	expect_paste(t, []string{"\x1b[200~\x1b[201~"}, "")
	// 终止符跨 chunk。
	expect_paste(t, []string{"\x1b[200~abc\x1b[20", "1~"}, "abc")
	// 形似终止符但匹配失败的内容必须保留；其中的 ESC 作为控制字符被丢弃。
	expect_paste(t, []string{"\x1b[200~abc\x1b[20x\x1b[201~"}, "abc[20x")
}

@(test)
test_decode_paste_strips_c0_controls :: proc(t: ^testing.T) {
	// ESC 不能原样进入缓冲区，否则重绘时会被终端当成转义序列。
	expect_paste(t, []string{"\x1b[200~a\x1b[31mb\x07c\x1b[201~"}, "a[31mbc")
	expect_paste(t, []string{"\x1b[200~a\tb\nc\x1b[201~"}, "a\tb\nc")
}

@(test)
test_decode_multiple_pastes :: proc(t: ^testing.T) {
	events := collect([]string{"\x1b[200~a\x1b[201~\x1b[200~b\x1b[201~"})
	defer events_destroy(&events)
	testing.expect_value(t, len(events), 2)
	if len(events) == 2 {
		a, a_ok := events[0].(Paste)
		b, b_ok := events[1].(Paste)
		testing.expect(t, a_ok)
		testing.expect(t, b_ok)
		testing.expect_value(t, a.text, "a")
		testing.expect_value(t, b.text, "b")
	}
}

@(test)
test_decode_paste_timeout :: proc(t: ^testing.T) {
	d: Decoder
	decoder_init(&d)
	defer decoder_destroy(&d)

	part := feed(&d, "\x1b[200~abc")
	delete(part)
	testing.expect_value(t, decoder_state(&d), Decoder_Mode.Paste)
	events := decode_timeout(&d)
	defer events_destroy(&events)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		got, ok := events[0].(Paste)
		testing.expect(t, ok)
		testing.expect_value(t, got.text, "abc")
	}
	testing.expect_value(t, decoder_state(&d), Decoder_Mode.Ground)
}
