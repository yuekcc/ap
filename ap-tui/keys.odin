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

Key_Mod :: enum {
	Shift,
	Alt,
	Ctrl,
}

Key_Mods :: bit_set[Key_Mod]

Key :: struct {
	kind: Key_Kind,
	r:    rune,
	mods: Key_Mods,
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

emit_key :: proc(events: ^[dynamic]Event, kind: Key_Kind, r: rune = 0, mods: Key_Mods = {}) {
	append(events, Event(Key{kind = kind, r = r, mods = mods}))
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
		mods, ok := csi_mods(&p)
		if ok {
			emit_key(events, .Home, 0, mods)
		} else {
			emit_key(events, .Ignore)
		}
	case 'F':
		mods, ok := csi_mods(&p)
		if ok {
			emit_key(events, .End, 0, mods)
		} else {
			emit_key(events, .Ignore)
		}
	case 'E':
		// 小键盘 5（NumLock 关闭）的 Begin 键，输入框没有对应动作。
		emit_key(events, .Ignore)
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
	mods: Key_Mods
	if p.count >= 2 {
		decoded, ok := decode_modifier(p.nums[1])
		if !ok {
			emit_unsupported(events)
			return
		}
		mods = decoded
	}

	if kitty_functional_key(code, mods, events) {
		return
	}
	if .Ctrl in mods {
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

	switch code {
	case 13:
		emit_key(events, .Enter, 0, mods)
	case 27:
		emit_key(events, .Escape)
	case 127, 8:
		emit_key(events, .Backspace)
	case:
		if code >= 0x20 && code <= 0x10ffff {
			// PUA 是 kitty 的功能键号段；未识别的功能键不能当正文插入。
			if code >= 0xe000 && code <= 0xf8ff {
				emit_unsupported(events)
			} else {
				emit_key(events, .Rune, rune(code), mods)
			}
		} else {
			emit_unsupported(events)
		}
	}
}

// kitty 打开 disambiguate 后，非文本的小键盘按键改用 PUA 功能键码（57399-57427）。
// 返回 false 表示不是本表内的键。
kitty_functional_key :: proc(code: int, mods: Key_Mods, events: ^[dynamic]Event) -> bool {
	switch code {
	case 57399 ..= 57408:
		emit_key(events, .Rune, rune(int('0') + (code - 57399)), mods)
	case 57409:
		emit_key(events, .Rune, '.', mods)
	case 57410:
		emit_key(events, .Rune, '/', mods)
	case 57411:
		emit_key(events, .Rune, '*', mods)
	case 57412:
		emit_key(events, .Rune, '-', mods)
	case 57413:
		emit_key(events, .Rune, '+', mods)
	case 57414:
		// 小键盘 Enter。带 Ctrl 时和主键盘一致，插入换行。
		if .Ctrl in mods {
			emit_key(events, .Ctrl_Enter)
		} else {
			emit_key(events, .Enter, 0, mods)
		}
	case 57415:
		emit_key(events, .Rune, '=', mods)
	case 57416:
		emit_key(events, .Rune, ',', mods)
	case 57417:
		emit_key(events, .Left, 0, mods)
	case 57418:
		emit_key(events, .Right, 0, mods)
	case 57419:
		emit_key(events, .Up, 0, mods)
	case 57420:
		emit_key(events, .Down, 0, mods)
	case 57423:
		emit_key(events, .Home, 0, mods)
	case 57424:
		emit_key(events, .End, 0, mods)
	case 57426:
		emit_key(events, .Delete, 0, mods)
	case 57421, 57422, 57425, 57427:
		// KP_PAGE_UP / KP_PAGE_DOWN / KP_INSERT / KP_BEGIN：输入框没有对应动作。
		emit_key(events, .Ignore)
	case:
		return false
	}
	return true
}

arrow :: proc(p: ^Csi_Params, events: ^[dynamic]Event, kind: Key_Kind) {
	mods, ok := csi_mods(p)
	if !ok {
		emit_key(events, .Ignore)
		return
	}
	emit_key(events, kind, 0, mods)
}

// 方向键和 Home/End 的修饰键编码：CSI A（无参数）、CSI 1 A、CSI 1;1 A 是无修饰；
// 第二个参数是 modifier code。修饰位含义见 decode_modifier。
csi_mods :: proc(p: ^Csi_Params) -> (mods: Key_Mods, ok: bool) {
	switch p.count {
	case 0:
		return {}, true
	case 1:
		return {}, p.nums[0] == 1
	case 2:
		if p.nums[0] != 1 {
			return {}, false
		}
	case:
		return {}, false
	}
	return decode_modifier(p.nums[1])
}

// modifier code 是 1 + 位掩码。kitty 定义了 8 位：shift(1)、alt(2)、ctrl(4)、
// super(8)、hyper(16)、meta(32)、caps_lock(64)、num_lock(128)。锁键位在
// NumLock/CapsLock 打开时出现在非文本按键上，必须接受但不能影响编辑语义。
KITTY_MODIFIER_MASK :: 0xff

decode_modifier :: proc(code: int) -> (mods: Key_Mods, ok: bool) {
	// 空字段（CSI ...;u）表示使用默认值 1，等价于无修饰。
	if code == 0 {
		return {}, true
	}
	bits := code - 1
	if bits < 0 || bits > KITTY_MODIFIER_MASK {
		return {}, false
	}
	if bits & 1 != 0 {
		mods |= {.Shift}
	}
	if bits & 2 != 0 {
		mods |= {.Alt}
	}
	if bits & 4 != 0 {
		mods |= {.Ctrl}
	}
	return mods, true
}

handle_csi_tilde :: proc(d: ^Decoder, p: ^Csi_Params, events: ^[dynamic]Event) {
	if p.count == 0 {
		emit_key(events, .Ignore)
		return
	}
	code := p.nums[0]
	mods: Key_Mods
	if p.count >= 2 {
		decoded, ok := decode_modifier(p.nums[1])
		if !ok {
			emit_unsupported(events)
			return
		}
		mods = decoded
	}
	switch code {
	case 1, 7:
		emit_key(events, .Home, 0, mods)
	case 4, 8:
		emit_key(events, .End, 0, mods)
	case 3:
		emit_key(events, .Delete, 0, mods)
	case 2, 5, 6:
		// Insert / PgUp / PgDn（也是小键盘 NumLock 关闭时的 0、9、3），输入框没有对应动作。
		emit_key(events, .Ignore)
	case 57427:
		// kitty 的 KP_BEGIN 另一种编码：CSI 57427 ~。
		emit_key(events, .Ignore)
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
	case 'p' ..= 'y':
		// application keypad 模式下的小键盘数字 0-9。
		emit_key(events, .Rune, rune(int('0') + int(final - 'p')))
	case 'n':
		emit_key(events, .Rune, '.')
	case 'm':
		emit_key(events, .Rune, '-')
	case 'k':
		emit_key(events, .Rune, '+')
	case 'l':
		emit_key(events, .Rune, ',')
	case 'o':
		emit_key(events, .Rune, '/')
	case 'j':
		emit_key(events, .Rune, '*')
	case 'X':
		emit_key(events, .Rune, '=')
	case 'M':
		// 小键盘 Enter。
		emit_key(events, .Enter)
	case:
		emit_unsupported(events)
	}
}
