package aptui

import "core:strings"
import "core:unicode/utf8"

// 输入层把任意字节分片解码成事件。状态全部放在 Decoder 里，允许 CSI 只到一半、
// 粘贴跨 chunk、多字节 UTF-8 被切开。

Key_Kind :: enum {
	Rune,
	Backspace,
	Enter,
	Ctrl_Enter,
	Delete,
	Left,
	Right,
	Up,
	Down,
	Home,
	End,
	Ctrl_A,
	Ctrl_E,
	Ctrl_K,
	Ctrl_U,
	Ctrl_W,
	Ctrl_C,
	Escape,
	Ignore,
}

Key :: struct {
	kind: Key_Kind,
	r:    rune,
}

Paste :: struct {
	text: string,
}

Unsupported :: struct {}

Event :: union {
	Key,
	Paste,
	Unsupported,
}

Decoder_Mode :: enum {
	Ground,
	Escape,
	Csi,
	Ss3,
	Osc,
	Osc_Escape,
	Paste,
}

Paste_Terminator :: "\x1b[201~"

Decoder :: struct {
	mode:      Decoder_Mode,
	seq:       [64]u8,
	seq_len:   int,
	utf8_buf:  [4]u8,
	utf8_len:  int,
	utf8_need: int,
	paste:     [dynamic]u8,
}

decoder_destroy :: proc(d: ^Decoder) {
	delete(d.paste)
	d^ = {}
}

decode_feed :: proc(d: ^Decoder, data: []u8) -> [dynamic]Event {
	events: [dynamic]Event
	for b in data {
		decode_byte(d, b, &events)
	}
	return events
}

// 超时：legacy 下孤立的 ESC（或残缺序列）必须在 poll 超时后落地；
// 粘贴终止符迟迟不到时也不能把已收到的文本吞掉。
decode_timeout :: proc(d: ^Decoder) -> [dynamic]Event {
	events: [dynamic]Event
	switch d.mode {
	case .Paste:
		emit_paste(d, &events)
	case .Escape:
		emit_key(&events, .Escape)
		reset_sequence(d)
	case .Csi, .Ss3, .Osc, .Osc_Escape:
		// 残缺的转义序列一律丢弃，绝不把转义字节插进缓冲区。
		emit_key(&events, .Ignore)
		reset_sequence(d)
	case .Ground:
	}
	return events
}

decoder_incomplete :: proc(d: ^Decoder) -> bool {
	switch d.mode {
	case .Escape, .Csi, .Ss3, .Osc, .Osc_Escape:
		return true
	case .Ground, .Paste:
		return false
	}
	return false
}

events_destroy :: proc(events: ^[dynamic]Event) {
	for ev in events^ {
		switch e in ev {
		case Paste:
			delete(e.text)
		case Key, Unsupported:
		}
	}
	delete(events^)
}

reset_sequence :: proc(d: ^Decoder) {
	d.mode = .Ground
	d.seq_len = 0
}

emit_key :: proc(events: ^[dynamic]Event, kind: Key_Kind, r: rune = 0) {
	append(events, Event(Key{kind = kind, r = r}))
}

emit_unsupported :: proc(events: ^[dynamic]Event) {
	append(events, Event(Unsupported{}))
}

emit_paste :: proc(d: ^Decoder, events: ^[dynamic]Event) {
	text := ""
	if len(d.paste) > 0 {
		cloned, err := strings.clone_from_bytes(d.paste[:], context.allocator)
		if err == nil {
			text = cloned
		}
	}
	append(events, Event(Paste{text = text}))
	clear(&d.paste)
	reset_sequence(d)
}

decode_byte :: proc(d: ^Decoder, b: u8, events: ^[dynamic]Event) {
	switch d.mode {
	case .Ground:
		ground_byte(d, b, events)
	case .Escape:
		switch b {
		case '[':
			append_seq(d, b)
			d.mode = .Csi
		case 'O':
			append_seq(d, b)
			d.mode = .Ss3
		case ']':
			append_seq(d, b)
			d.mode = .Osc
		case:
			// 不是 CSI/SS3/OSC：把 ESC 当作 Esc，后面的字节按普通输入重新处理。
			emit_key(events, .Escape)
			reset_sequence(d)
			ground_byte(d, b, events)
		}
	case .Csi:
		if !append_seq(d, b) {
			emit_unsupported(events)
			reset_sequence(d)
			return
		}
		if is_final_byte(b) {
			handle_csi(d, events)
		}
	case .Ss3:
		if !append_seq(d, b) {
			emit_unsupported(events)
			reset_sequence(d)
			return
		}
		if is_final_byte(b) {
			handle_ss3(d, events)
		}
	case .Osc:
		if b == 0x07 {
			emit_unsupported(events)
			reset_sequence(d)
		} else if b == 0x1b {
			d.mode = .Osc_Escape
		}
	case .Osc_Escape:
		if b == '\\' {
			emit_unsupported(events)
			reset_sequence(d)
		} else {
			d.mode = .Osc
		}
	case .Paste:
		paste_byte(d, b, events)
	}
}

append_seq :: proc(d: ^Decoder, b: u8) -> bool {
	if d.seq_len >= len(d.seq) {
		return false
	}
	d.seq[d.seq_len] = b
	d.seq_len += 1
	return true
}

is_final_byte :: proc(b: u8) -> bool {
	return b >= 0x40 && b <= 0x7e
}

paste_byte :: proc(d: ^Decoder, b: u8, events: ^[dynamic]Event) {
	// 粘贴归一：删 \r，保留 \n。
	if b == '\r' {
		return
	}
	append(&d.paste, b)
	term := Paste_Terminator
	if b == '~' && len(d.paste) >= len(term) {
		n := len(d.paste)
		if string(d.paste[n - len(term):]) == term {
			remove_last(&d.paste, len(term))
			emit_paste(d, events)
		}
	}
}

remove_last :: proc(s: ^[dynamic]u8, n: int) {
	if n >= len(s^) {
		clear(s)
		return
	}
	resize(s, len(s^) - n)
}

ground_byte :: proc(d: ^Decoder, b: u8, events: ^[dynamic]Event) {
	if b == 0x1b {
		d.seq_len = 0
		append_seq(d, b)
		d.mode = .Escape
		return
	}
	if b < 0x80 {
		switch b {
		case 0x7f, 0x08:
			emit_key(events, .Backspace)
		case 0x0d, 0x0a:
			emit_key(events, .Enter)
		case 0x03:
			emit_key(events, .Ctrl_C)
		case 0x01:
			emit_key(events, .Ctrl_A)
		case 0x05:
			emit_key(events, .Ctrl_E)
		case 0x0b:
			emit_key(events, .Ctrl_K)
		case 0x15:
			emit_key(events, .Ctrl_U)
		case 0x17:
			emit_key(events, .Ctrl_W)
		case:
			if b < 0x20 {
				emit_key(events, .Ignore)
			} else {
				emit_key(events, .Rune, rune(b))
			}
		}
		return
	}

	// 多字节 UTF-8：非法序列整体丢弃，绝不插入缓冲区。
	if d.utf8_len == 0 {
		need := utf8_sequence_length(b)
		if need == 0 {
			emit_key(events, .Ignore)
			return
		}
		d.utf8_need = need
		d.utf8_buf[0] = b
		d.utf8_len = 1
		return
	}
	if b < 0x80 || b > 0xbf {
		d.utf8_len = 0
		d.utf8_need = 0
		ground_byte(d, b, events)
		return
	}
	d.utf8_buf[d.utf8_len] = b
	d.utf8_len += 1
	if d.utf8_len < d.utf8_need {
		return
	}
	r, size := utf8.decode_rune_in_bytes(d.utf8_buf[:d.utf8_len])
	if r == utf8.RUNE_ERROR && size != d.utf8_len {
		emit_key(events, .Ignore)
	} else {
		emit_key(events, .Rune, r)
	}
	d.utf8_len = 0
	d.utf8_need = 0
}

utf8_sequence_length :: proc(b: u8) -> int {
	switch {
	case b >= 0xc2 && b <= 0xdf:
		return 2
	case b >= 0xe0 && b <= 0xef:
		return 3
	case b >= 0xf0 && b <= 0xf4:
		return 4
	}
	return 0
}

Csi_Params :: struct {
	nums:    [8]int,
	count:   int,
	private: u8,
	ok:      bool,
}

parse_csi_params :: proc(body: []u8) -> Csi_Params {
	p: Csi_Params
	p.ok = true
	i := 0
	if len(body) > 0 {
		b := body[0]
		if (b < '0' || b > '9') && b != ';' && b != ':' {
			p.private = b
			i = 1
		}
	}

	cur := 0
	have_digit := false
	in_sub := false
	for ; i < len(body); i += 1 {
		b := body[i]
		switch {
		case b >= '0' && b <= '9':
			if !in_sub {
				cur = cur * 10 + int(b - '0')
				if cur > 1_000_000 {
					cur = 1_000_000
				}
				have_digit = true
			}
		case b == ':':
			in_sub = true
		case b == ';':
			in_sub = false
			if !push_param(&p, cur, have_digit, true) {
				return p
			}
			cur = 0
			have_digit = false
		case:
			p.ok = false
			return p
		}
	}
	_ = push_param(&p, cur, have_digit, len(body) > 0)
	return p
}

push_param :: proc(p: ^Csi_Params, value: int, have_digit: bool, push: bool) -> bool {
	if !push {
		return true
	}
	if p.count >= len(p.nums) {
		p.ok = false
		return false
	}
	p.nums[p.count] = have_digit ? value : 0
	p.count += 1
	return true
}

handle_csi :: proc(d: ^Decoder, events: ^[dynamic]Event) {
	// d.seq = ESC '[' <body> <final>
	final := d.seq[d.seq_len - 1]
	body := d.seq[2:d.seq_len - 1]
	p := parse_csi_params(body)
	reset_sequence(d)

	if !p.ok || p.private != 0 {
		emit_unsupported(events)
		return
	}

	switch final {
	case 'u':
		handle_csi_u(&p, events)
	case 'A':
		arrow(&p, events, .Up)
	case 'B':
		arrow(&p, events, .Down)
	case 'C':
		arrow(&p, events, .Right)
	case 'D':
		arrow(&p, events, .Left)
	case 'H':
		if plain_param(&p) {
			emit_key(events, .Home)
		} else {
			emit_key(events, .Ignore)
		}
	case 'F':
		if plain_param(&p) {
			emit_key(events, .End)
		} else {
			emit_key(events, .Ignore)
		}
	case '~':
		handle_csi_tilde(d, &p, events)
	case:
		emit_unsupported(events)
	}
}

handle_csi_u :: proc(p: ^Csi_Params, events: ^[dynamic]Event) {
	if p.count == 0 {
		emit_key(events, .Ignore)
		return
	}
	code := p.nums[0]
	mod := 1
	if p.count >= 2 {
		mod = p.nums[1]
	}
	ctrl := (mod - 1) & 4 != 0

	if ctrl {
		switch code {
		case 'a', 'A':
			emit_key(events, .Ctrl_A)
		case 'e', 'E':
			emit_key(events, .Ctrl_E)
		case 'k', 'K':
			emit_key(events, .Ctrl_K)
		case 'u', 'U':
			emit_key(events, .Ctrl_U)
		case 'w', 'W':
			emit_key(events, .Ctrl_W)
		case 'c', 'C':
			emit_key(events, .Ctrl_C)
		case 13:
			emit_key(events, .Ctrl_Enter)
		case:
			emit_unsupported(events)
		}
		return
	}

	if p.count > 1 {
		emit_unsupported(events)
		return
	}
	switch code {
	case 13:
		emit_key(events, .Enter)
	case 27:
		emit_key(events, .Escape)
	case 127, 8:
		emit_key(events, .Backspace)
	case:
		if code >= 0x20 && code <= 0x10ffff {
			emit_key(events, .Rune, rune(code))
		} else {
			emit_unsupported(events)
		}
	}
}

arrow :: proc(p: ^Csi_Params, events: ^[dynamic]Event, kind: Key_Kind) {
	// CSI A（无参数）、CSI 1 A、CSI 1;1 A 是无修饰方向键；带修饰的忽略。
	if p.count == 0 || (p.count == 1 && p.nums[0] == 1) || (p.count == 2 && p.nums[1] == 1) {
		emit_key(events, kind)
	} else {
		emit_key(events, .Ignore)
	}
}

plain_param :: proc(p: ^Csi_Params) -> bool {
	if p.count == 0 {
		return true
	}
	if p.count == 1 {
		return p.nums[0] == 1
	}
	return p.count == 2 && p.nums[1] == 1
}

handle_csi_tilde :: proc(d: ^Decoder, p: ^Csi_Params, events: ^[dynamic]Event) {
	if p.count == 0 {
		emit_key(events, .Ignore)
		return
	}
	code := p.nums[0]
	mod := 1
	if p.count >= 2 {
		mod = p.nums[1]
	}
	if mod != 1 {
		emit_key(events, .Ignore)
		return
	}
	switch code {
	case 1, 7:
		emit_key(events, .Home)
	case 4, 8:
		emit_key(events, .End)
	case 3:
		emit_key(events, .Delete)
	case 200:
		d.mode = .Paste
	case 201:
		// 粘贴终止符出现在粘贴模式之外：忽略。
		emit_key(events, .Ignore)
	case:
		emit_unsupported(events)
	}
}

handle_ss3 :: proc(d: ^Decoder, events: ^[dynamic]Event) {
	final := d.seq[d.seq_len - 1]
	reset_sequence(d)
	switch final {
	case 'A':
		emit_key(events, .Up)
	case 'B':
		emit_key(events, .Down)
	case 'C':
		emit_key(events, .Right)
	case 'D':
		emit_key(events, .Left)
	case 'H':
		emit_key(events, .Home)
	case 'F':
		emit_key(events, .End)
	case:
		emit_unsupported(events)
	}
}
