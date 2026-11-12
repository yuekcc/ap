package lineedit

// 输入层把任意字节分片解码成事件。状态全部放在 Decoder 里，允许 CSI 只到一半、
// 粘贴跨 chunk、多字节 UTF-8 被切开。

import "core:strings"
import "core:unicode/utf8"

Key_Kind :: enum {
	Rune,
	Tab,
	Enter,
	Backspace,
	Delete,
	Insert,
	Left,
	Right,
	Up,
	Down,
	Home,
	End,
	Page_Up,
	Page_Down,
	Escape,
	Ignore,
}

Key_Mod :: enum {
	Shift,
	Alt,
	Ctrl,
}

Key_Mods :: bit_set[Key_Mod]

// Rune 上的 Ctrl/Alt 是有意义的：编辑器把 Ctrl+A 这类组合映射成动作，
// 而不是在解码层硬编码成 Ctrl_A 之类的专用键。这样 kitty 和 legacy 可以共用事件模型。
Key :: struct {
	kind: Key_Kind,
	r:    rune,
	mods: Key_Mods,
}

Paste :: struct {
	text:      string,
	truncated: bool,
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
	String,
	String_Escape,
	Paste,
}

PASTE_TERMINATOR :: "\x1b[201~"
MAX_PASTE_BYTES  :: 8 << 20

Decoder :: struct {
	mode:           Decoder_Mode,
	seq:            [64]u8,
	seq_len:        int,
	utf8_buf:       [4]u8,
	utf8_len:       int,
	utf8_need:      int,
	alt_pending:    bool,
	paste:          [dynamic]u8,
	paste_match:    int,
	paste_overflow: bool,
}

decoder_init :: proc(d: ^Decoder) {
	d^ = {}
	d.paste = make([dynamic]u8, 0, 256)
}

decoder_destroy :: proc(d: ^Decoder) {
	delete(d.paste)
	d^ = {}
}

// 新一轮 read_line 前清掉上一轮可能残留的半截序列/粘贴。
decoder_reset :: proc(d: ^Decoder) {
	d.mode = .Ground
	d.seq_len = 0
	d.utf8_len = 0
	d.utf8_need = 0
	d.alt_pending = false
	clear(&d.paste)
	d.paste_match = 0
	d.paste_overflow = false
}

decode_feed :: proc(d: ^Decoder, data: []u8) -> [dynamic]Event {
	events: [dynamic]Event
	for b in data {
		decode_byte(d, b, &events)
	}
	return events
}

// 超时用于落地 legacy 下孤立的 ESC、残缺的 CSI，以及迟迟等不到终止符的粘贴。
decode_timeout :: proc(d: ^Decoder) -> [dynamic]Event {
	events: [dynamic]Event
	switch d.mode {
	case .Paste:
		flush_paste_match(d)
		emit_paste(d, &events)
	case .Escape:
		emit_key(&events, .Escape)
		reset_sequence(d)
	case .Csi, .Ss3:
		// 残缺的转义序列一律丢弃，绝不把转义字节插进缓冲区。
		emit_key(&events, .Ignore)
		reset_sequence(d)
	case .String, .String_Escape:
		emit_unsupported(&events)
		reset_sequence(d)
	case .Ground:
		if d.utf8_len > 0 {
			d.utf8_len = 0
			d.utf8_need = 0
			d.alt_pending = false
			emit_key(&events, .Ignore)
		}
	}
	return events
}

decoder_state :: proc(d: ^Decoder) -> Decoder_Mode {
	return d.mode
}

decoder_incomplete :: proc(d: ^Decoder) -> bool {
	return d.mode != .Ground || d.utf8_len > 0
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

// legacy 的 Alt 是 ESC 前缀；真正落地时才把 Alt 加到按键上。
ground_emit_key :: proc(d: ^Decoder, events: ^[dynamic]Event, kind: Key_Kind, r: rune = 0, mods: Key_Mods = {}) {
	m := mods
	if d.alt_pending {
		m |= {.Alt}
		d.alt_pending = false
	}
	emit_key(events, kind, r, m)
}

emit_unsupported :: proc(events: ^[dynamic]Event) {
	append(events, Event(Unsupported{}))
}

decode_byte :: proc(d: ^Decoder, b: u8, events: ^[dynamic]Event) {
	switch d.mode {
	case .Ground:
		ground_byte(d, b, events)
	case .Escape:
		escape_byte(d, b, events)
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
	case .String:
		if b == 0x07 {
			emit_unsupported(events)
			reset_sequence(d)
		} else if b == 0x1b {
			d.mode = .String_Escape
		}
	case .String_Escape:
		if b == '\\' {
			emit_unsupported(events)
			reset_sequence(d)
		} else {
			d.mode = .String
		}
	case .Paste:
		paste_byte(d, b, events)
	}
}

escape_byte :: proc(d: ^Decoder, b: u8, events: ^[dynamic]Event) {
	switch b {
	case '[':
		d.mode = .Csi
		d.seq_len = 0
	case 'O':
		d.mode = .Ss3
		d.seq_len = 0
	case ']', 'P', '^', '_':
		// OSC / DCS / PM / APC：内容不参与编辑，整段吃掉。
		d.mode = .String
	case 0x1b:
		// 连续两个 ESC：第一个作为 Esc 落地，第二个继续开启新序列。
		emit_key(events, .Escape)
		d.seq_len = 0
	case:
		// legacy 的 Alt 前缀。后面的字节可能是控制键、ASCII 或 UTF-8 首字节。
		d.alt_pending = true
		d.mode = .Ground
		ground_byte(d, b, events)
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

ground_byte :: proc(d: ^Decoder, b: u8, events: ^[dynamic]Event) {
	// 先把未完成的 UTF-8 处理掉：续字节继续累积，非续字节丢弃残缺序列后
	// 重新处理当前字节（可能是 ASCII、ESC 或新的 UTF-8 首字节）。
	if d.utf8_len > 0 {
		if b >= 0x80 && b <= 0xbf {
			d.utf8_buf[d.utf8_len] = b
			d.utf8_len += 1
			if d.utf8_len < d.utf8_need {
				return
			}
			n := d.utf8_len
			r, size := utf8.decode_rune_in_bytes(d.utf8_buf[:n])
			d.utf8_len = 0
			d.utf8_need = 0
			if r == utf8.RUNE_ERROR && size != n {
				d.alt_pending = false
				emit_key(events, .Ignore)
			} else {
				ground_emit_key(d, events, .Rune, r)
			}
			return
		}

		d.utf8_len = 0
		d.utf8_need = 0
		d.alt_pending = false
		emit_key(events, .Ignore)
	}

	if b == 0x1b {
		d.mode = .Escape
		d.seq_len = 0
		return
	}

	if b < 0x80 {
		switch b {
		case 0x7f, 0x08:
			ground_emit_key(d, events, .Backspace)
		case 0x09:
			ground_emit_key(d, events, .Tab)
		case 0x0a, 0x0d:
			ground_emit_key(d, events, .Enter)
		case 0x00:
			// Ctrl+Space / NUL。
			ground_emit_key(d, events, .Rune, ' ', {.Ctrl})
		case 0x01 ..= 0x07, 0x0b, 0x0c, 0x0e ..= 0x1a:
			ground_emit_key(d, events, .Rune, rune(int('a') + int(b) - 1), {.Ctrl})
		case 0x1c:
			ground_emit_key(d, events, .Rune, '\\', {.Ctrl})
		case 0x1d:
			ground_emit_key(d, events, .Rune, ']', {.Ctrl})
		case 0x1e:
			ground_emit_key(d, events, .Rune, '^', {.Ctrl})
		case 0x1f:
			ground_emit_key(d, events, .Rune, '_', {.Ctrl})
		case:
			ground_emit_key(d, events, .Rune, rune(b))
		}
		return
	}

	// 新的多字节 UTF-8 序列。非法起始字节整体丢弃，绝不插入缓冲区。
	need := utf8_sequence_length(b)
	if need == 0 {
		d.alt_pending = false
		emit_key(events, .Ignore)
		return
	}
	d.utf8_need = need
	d.utf8_buf[0] = b
	d.utf8_len = 1
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
	final := d.seq[d.seq_len - 1]
	body := d.seq[:d.seq_len - 1]
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
	case 'Z':
		// backtab。legacy 下这是 Shift+Tab 的标准编码。
		emit_key(events, .Tab, 0, {.Shift})
	case 'E':
		// 小键盘 5（NumLock 关闭）的 Begin 键。
		emit_key(events, .Ignore)
	case '~':
		handle_csi_tilde(d, &p, events)
	case 'P' ..= 'S':
		// F1-F4；编辑器暂不使用，保持可诊断。
		emit_unsupported(events)
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

	switch code {
	case 13:
		emit_key(events, .Enter, 0, mods)
	case 27:
		emit_key(events, .Escape, 0, mods)
	case 127, 8:
		emit_key(events, .Backspace, 0, mods)
	case 9:
		emit_key(events, .Tab, 0, mods)
	case 32 ..= 0x10ffff:
		// PUA 是 kitty 的功能键号段；未识别的功能键不能当正文插入。
		if code >= 0xe000 && code <= 0xf8ff {
			emit_unsupported(events)
		} else {
			emit_key(events, .Rune, rune(code), mods)
		}
	case:
		emit_unsupported(events)
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
		emit_key(events, .Enter, 0, mods)
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
	case 57421:
		emit_key(events, .Page_Up, 0, mods)
	case 57422:
		emit_key(events, .Page_Down, 0, mods)
	case 57423:
		emit_key(events, .Home, 0, mods)
	case 57424:
		emit_key(events, .End, 0, mods)
	case 57425:
		emit_key(events, .Insert, 0, mods)
	case 57426:
		emit_key(events, .Delete, 0, mods)
	case 57427:
		// KP_BEGIN：输入框没有对应动作。
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
// 第二个参数是 modifier code。
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
// Super/Hyper/Meta 不在编辑器支持范围内：宁可丢掉，也不能当成无修饰键插入。
KITTY_MODIFIER_SUPPORTED :: 1 | 2 | 4 | 64 | 128

decode_modifier :: proc(code: int) -> (mods: Key_Mods, ok: bool) {
	// 空字段（CSI ...;u）表示使用默认值 1，等价于无修饰。
	if code == 0 {
		return {}, true
	}
	bits := code - 1
	if bits < 0 || bits > 0xff {
		return {}, false
	}
	if bits & ~int(KITTY_MODIFIER_SUPPORTED) != 0 {
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
	case 2:
		emit_key(events, .Insert, 0, mods)
	case 5:
		emit_key(events, .Page_Up, 0, mods)
	case 6:
		emit_key(events, .Page_Down, 0, mods)
	case 200:
		d.mode = .Paste
		clear(&d.paste)
		d.paste_match = 0
		d.paste_overflow = false
	case 201:
		// 粘贴终止符出现在粘贴模式之外：忽略。
		emit_key(events, .Ignore)
	case 57427:
		// kitty 的 KP_BEGIN 另一种编码：CSI 57427 ~。
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

// 粘贴终止符可能跨 chunk，而且部分匹配失败时要把它当正文补回缓冲区。
paste_byte :: proc(d: ^Decoder, b: u8, events: ^[dynamic]Event) {
	term := PASTE_TERMINATOR
	for {
		if d.paste_match < len(term) && b == term[d.paste_match] {
			d.paste_match += 1
			if d.paste_match == len(term) {
				// 完整终止符本身不属于粘贴内容，先清掉匹配计数再落地。
				d.paste_match = 0
				emit_paste(d, events)
			}
			return
		}

		if d.paste_match > 0 {
			append_paste_bytes(d, term[:d.paste_match])
			d.paste_match = 0
			continue
		}

		append_paste_byte(d, b)
		return
	}
}

append_paste_byte :: proc(d: ^Decoder, b: u8) {
	if len(d.paste) >= MAX_PASTE_BYTES {
		d.paste_overflow = true
		return
	}
	append(&d.paste, b)
}

append_paste_bytes :: proc(d: ^Decoder, bytes: string) {
	for i in 0 ..< len(bytes) {
		append_paste_byte(d, bytes[i])
	}
}

flush_paste_match :: proc(d: ^Decoder) {
	if d.paste_match > 0 {
		term := PASTE_TERMINATOR
		append_paste_bytes(d, term[:d.paste_match])
		d.paste_match = 0
	}
}

emit_paste :: proc(d: ^Decoder, events: ^[dynamic]Event) {
	flush_paste_match(d)

	text := ""
	if len(d.paste) > 0 {
		// 统一换行：CRLF 和孤立 CR 都变成 LF，编辑器内部只认 \n。
		out := make([dynamic]u8, 0, len(d.paste))
		i := 0
		for i < len(d.paste) {
			b := d.paste[i]
			if b == '\r' {
				append(&out, '\n')
				if i + 1 < len(d.paste) && d.paste[i + 1] == '\n' {
					i += 2
				} else {
					i += 1
				}
			} else if b == 0x7f || (b < 0x20 && b != '\n' && b != '\t') {
				// 丢弃 ESC/BEL 等 C0 控制字符，避免重绘时注入终端转义序列。
				i += 1
			} else {
				append(&out, b)
				i += 1
			}
		}
		cloned, err := strings.clone_from_bytes(out[:], context.allocator)
		if err == nil {
			text = cloned
		}
		delete(out)
	}

	append(events, Event(Paste{text = text, truncated = d.paste_overflow}))
	clear(&d.paste)
	d.paste_match = 0
	d.paste_overflow = false
	reset_sequence(d)
}
