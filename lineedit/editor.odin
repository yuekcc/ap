package lineedit

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

MAX_INPUT :: 1 << 20

// 编辑模型：buffer 是 UTF-8 字节串，cursor 是始终落在 rune 边界上的字节偏移。
// desired_col 只在连续上下移动之间保留可视列号，任何水平移动或编辑都会清掉它。
Editor :: struct {
	buffer:      [dynamic]u8,
	cursor:      int,
	desired_col: int,
	max_len:     int,
}

editor_init :: proc(e: ^Editor, max_len := MAX_INPUT) {
	e^ = {}
	e.max_len = max_len
	e.buffer = make([dynamic]u8, 0, 256)
	e.desired_col = -1
}

editor_destroy :: proc(e: ^Editor) {
	delete(e.buffer)
	e^ = {}
}

editor_text :: proc(e: ^Editor) -> string {
	return string(e.buffer[:])
}

editor_is_empty :: proc(e: ^Editor) -> bool {
	return len(e.buffer) == 0
}

editor_reset :: proc(e: ^Editor) {
	clear(&e.buffer)
	e.cursor = 0
	e.desired_col = -1
}

// 直接设置光标时清掉垂直移动的期望列；位置夹到合法范围。
editor_set_cursor :: proc(e: ^Editor, pos: int) {
	p := pos
	if p < 0 {
		p = 0
	}
	if p > len(e.buffer) {
		p = len(e.buffer)
	}
	e.cursor = p
	e.desired_col = -1
}

// 插入文本。CRLF 和孤立 CR 归一成 LF；超过 max_len 时只插入能放下的完整 rune，
// 返回 true 表示发生了截断。空输入返回 false。
editor_insert_text :: proc(e: ^Editor, text: string) -> bool {
	data := transmute([]u8)text
	if len(data) == 0 {
		return false
	}

	normalized: [dynamic]u8
	defer delete(normalized)
	has_cr := false
	for b in data {
		if b == '\r' {
			has_cr = true
			break
		}
	}
	if has_cr {
		normalized = make([dynamic]u8, 0, len(data))
		i := 0
		for i < len(data) {
			if data[i] == '\r' {
				append(&normalized, '\n')
				if i + 1 < len(data) && data[i + 1] == '\n' {
					i += 2
				} else {
					i += 1
				}
			} else {
				append(&normalized, data[i])
				i += 1
			}
		}
		data = normalized[:]
	}

	available := e.max_len - len(e.buffer)
	if available <= 0 {
		return true
	}

	keep := min(available, len(data))
	// 不要切在 UTF-8 rune 中间。
	for keep > 0 && keep < len(data) && (data[keep] & 0xc0) == 0x80 {
		keep -= 1
	}
	if keep == 0 {
		return true
	}

	editor_insert_bytes(e, data[:keep])
	return keep < len(data)
}

editor_insert_rune :: proc(e: ^Editor, r: rune) -> bool {
	buf, size := utf8.encode_rune(r)
	return editor_insert_text(e, string(buf[:size]))
}

editor_insert_bytes :: proc(e: ^Editor, data: []u8) {
	if len(data) == 0 {
		return
	}
	old_len := len(e.buffer)
	resize(&e.buffer, old_len + len(data))
	copy(e.buffer[e.cursor + len(data):], e.buffer[e.cursor:old_len])
	copy(e.buffer[e.cursor:], data)
	e.cursor += len(data)
	e.desired_col = -1
}

editor_remove_range :: proc(e: ^Editor, start, end: int) {
	if start >= end || start < 0 || end > len(e.buffer) {
		return
	}
	copy(e.buffer[start:], e.buffer[end:])
	resize(&e.buffer, len(e.buffer) - (end - start))
	e.cursor = start
	e.desired_col = -1
}

editor_prev_rune_start :: proc(buf: []u8, pos: int) -> int {
	if pos <= 0 {
		return 0
	}
	_, size := utf8.decode_last_rune_in_bytes(buf[:pos])
	if size <= 0 || size > pos {
		return pos - 1
	}
	return pos - size
}

editor_next_rune_end :: proc(buf: []u8, pos: int) -> int {
	if pos >= len(buf) {
		return len(buf)
	}
	_, size := utf8.decode_rune_in_bytes(buf[pos:])
	if size <= 0 {
		size = 1
	}
	end := pos + size
	if end > len(buf) {
		return len(buf)
	}
	return end
}

editor_backspace :: proc(e: ^Editor) {
	if e.cursor <= 0 {
		return
	}
	start := editor_prev_rune_start(e.buffer[:], e.cursor)
	editor_remove_range(e, start, e.cursor)
}

editor_delete :: proc(e: ^Editor) {
	if e.cursor >= len(e.buffer) {
		return
	}
	end := editor_next_rune_end(e.buffer[:], e.cursor)
	editor_remove_range(e, e.cursor, end)
}

editor_left :: proc(e: ^Editor) {
	if e.cursor <= 0 {
		return
	}
	e.cursor = editor_prev_rune_start(e.buffer[:], e.cursor)
	e.desired_col = -1
}

editor_right :: proc(e: ^Editor) {
	if e.cursor >= len(e.buffer) {
		return
	}
	e.cursor = editor_next_rune_end(e.buffer[:], e.cursor)
	e.desired_col = -1
}

// Ctrl+←/→、Alt+←/→：按空白分词移动，路径算一个词。
editor_word_left :: proc(e: ^Editor) {
	e.cursor = editor_word_start(e.buffer[:], e.cursor)
	e.desired_col = -1
}

editor_word_right :: proc(e: ^Editor) {
	e.cursor = editor_word_end(e.buffer[:], e.cursor)
	e.desired_col = -1
}

// 先跳过光标前的空白，再退到前一个词的词首。
editor_word_start :: proc(buf: []u8, pos: int) -> int {
	i := pos
	for i > 0 {
		r, _ := utf8.decode_last_rune_in_bytes(buf[:i])
		if !editor_is_space(r) {
			break
		}
		i = editor_prev_rune_start(buf, i)
	}
	for i > 0 {
		r, _ := utf8.decode_last_rune_in_bytes(buf[:i])
		if editor_is_space(r) {
			break
		}
		i = editor_prev_rune_start(buf, i)
	}
	return i
}

// 先跳过当前空白，再走到下一个词的词尾。与 readline 的 forward-word 一致。
editor_word_end :: proc(buf: []u8, pos: int) -> int {
	i := pos
	for i < len(buf) {
		r, _ := utf8.decode_rune_in_bytes(buf[i:])
		if !editor_is_space(r) {
			break
		}
		i = editor_next_rune_end(buf, i)
	}
	for i < len(buf) {
		r, _ := utf8.decode_rune_in_bytes(buf[i:])
		if editor_is_space(r) {
			break
		}
		i = editor_next_rune_end(buf, i)
	}
	return i
}

// Ctrl+Home / Ctrl+End：整个缓冲区开头或结尾。
editor_buffer_start :: proc(e: ^Editor) {
	e.cursor = 0
	e.desired_col = -1
}

editor_buffer_end :: proc(e: ^Editor) {
	e.cursor = len(e.buffer)
	e.desired_col = -1
}

editor_line_start :: proc(e: ^Editor) -> int {
	i := e.cursor
	for i > 0 && e.buffer[i - 1] != '\n' {
		i -= 1
	}
	return i
}

editor_line_end :: proc(e: ^Editor) -> int {
	i := e.cursor
	for i < len(e.buffer) && e.buffer[i] != '\n' {
		i += 1
	}
	return i
}

editor_home :: proc(e: ^Editor) {
	e.cursor = editor_line_start(e)
	e.desired_col = -1
}

editor_end :: proc(e: ^Editor) {
	e.cursor = editor_line_end(e)
	e.desired_col = -1
}

// Ctrl+K：删到当前逻辑行行尾（不含换行）。
editor_kill_to_end :: proc(e: ^Editor) {
	end := editor_line_end(e)
	if e.cursor >= end {
		return
	}
	editor_remove_range(e, e.cursor, end)
}

// Ctrl+U：删到当前逻辑行行首（不含行首换行）。
editor_kill_to_start :: proc(e: ^Editor) {
	start := editor_line_start(e)
	if e.cursor <= start {
		return
	}
	editor_remove_range(e, start, e.cursor)
}

// Ctrl+W：按空白分词删掉前一个词。
editor_delete_word :: proc(e: ^Editor) {
	start := editor_word_start(e.buffer[:], e.cursor)
	if start == e.cursor {
		return
	}
	editor_remove_range(e, start, e.cursor)
}

// ↑↓ 按可视行移动，尽量保持列号；首行再上、末行再下为 no-op。
editor_up :: proc(e: ^Editor, cols, prefix_width: int) -> bool {
	return editor_move_vertical(e, -1, cols, prefix_width)
}

editor_down :: proc(e: ^Editor, cols, prefix_width: int) -> bool {
	return editor_move_vertical(e, 1, cols, prefix_width)
}

editor_move_vertical :: proc(e: ^Editor, delta, cols, prefix_width: int) -> bool {
	l := layout(e.buffer[:], e.cursor, cols, prefix_width)
	defer layout_destroy(&l)

	target := l.cursor_row + delta
	if target < 0 || target >= len(l.rows) {
		return false
	}
	desired := e.desired_col
	if desired < 0 {
		desired = l.cursor_col - prefix_width
	}
	if desired < 0 {
		desired = 0
	}
	offset, _ := editor_offset_for_column(e.buffer[:], l.rows[target], desired)
	e.cursor = offset
	// 保留目标列（而不是被短行 clamp 后的列），这样回到长行时能恢复。
	e.desired_col = desired
	return true
}

// 返回 target row 内、显示列不超过 desired 的最后一个字节偏移，以及实际列号。
editor_offset_for_column :: proc(buf: []u8, row: Row, desired: int) -> (offset: int, col: int) {
	if desired <= 0 {
		return row.start, 0
	}
	i := row.start
	end := row.start + row.len
	c := 0
	for i < end {
		it := utf8.decode_grapheme_iterator_make(string(buf[i:end]))
		text, g, ok := utf8.decode_grapheme_iterate(&it)
		if !ok || len(text) == 0 {
			break
		}
		w := g.width
		if w < 0 {
			w = 0
		}
		if text == "\t" {
			w = TAB_WIDTH - (c % TAB_WIDTH)
		}
		if c + w > desired {
			break
		}
		c += w
		i += len(text)
	}
	return i, c
}

// 编辑器对外只返回语义动作；提交、退出、重绘、补全、history 由上层决定怎么处理。
Edit_Action :: enum {
	None,
	Submit,
	Cancel,
	Eof,
	Redraw,
	Complete,
	Complete_Prev,
	History_Prev,
	History_Next,
}

editor_apply_key :: proc(e: ^Editor, key: Key, cols, prefix_width: int) -> Edit_Action {
	switch key.kind {
	case .Rune:
		return editor_apply_rune_key(e, key)
	case .Tab:
		if .Shift in key.mods {
			return .Complete_Prev
		}
		return .Complete
	case .Enter:
		// Ctrl/Shift/Alt+Enter 插入换行；普通 Enter 提交。
		if .Ctrl in key.mods || .Shift in key.mods || .Alt in key.mods {
			editor_insert_rune(e, '\n')
			return .None
		}
		return .Submit
	case .Backspace:
		if .Ctrl in key.mods || .Alt in key.mods {
			editor_delete_word(e)
		} else {
			editor_backspace(e)
		}
		return .None
	case .Delete:
		editor_delete(e)
		return .None
	case .Left:
		if .Ctrl in key.mods || .Alt in key.mods {
			editor_word_left(e)
		} else {
			editor_left(e)
		}
		return .None
	case .Right:
		if .Ctrl in key.mods || .Alt in key.mods {
			editor_word_right(e)
		} else {
			editor_right(e)
		}
		return .None
	case .Up:
		if editor_up(e, cols, prefix_width) {
			return .None
		}
		return .History_Prev
	case .Down:
		if editor_down(e, cols, prefix_width) {
			return .None
		}
		return .History_Next
	case .Home:
		if .Ctrl in key.mods || .Alt in key.mods {
			editor_buffer_start(e)
		} else {
			editor_home(e)
		}
		return .None
	case .End:
		if .Ctrl in key.mods || .Alt in key.mods {
			editor_buffer_end(e)
		} else {
			editor_end(e)
		}
		return .None
	case .Page_Up:
		return .History_Prev
	case .Page_Down:
		return .History_Next
	case .Insert:
		return .None
	case .Escape:
		// 与 ap-tui 旧编辑器一致：Esc 清空当前输入，不直接退出。
		editor_reset(e)
		return .None
	case .Ignore:
		return .None
	}
	return .None
}

// Rune 上的 Ctrl/Alt 只做绑定动作；没绑定的组合绝不能退化成正文插入。
editor_apply_rune_key :: proc(e: ^Editor, key: Key) -> Edit_Action {
	if .Ctrl in key.mods {
		switch unicode.to_lower(key.r) {
		case 'a':
			editor_home(e)
		case 'b':
			editor_left(e)
		case 'c':
			if editor_is_empty(e) {
				return .Cancel
			}
			editor_reset(e)
		case 'd':
			if editor_is_empty(e) {
				return .Eof
			}
			editor_delete(e)
		case 'e':
			editor_end(e)
		case 'f':
			editor_right(e)
		case 'h':
			editor_backspace(e)
		case 'i':
			return .Complete
		case 'j', 'm':
			// readline 兼容：Ctrl+J / Ctrl+M 仍视为提交；kitty 下它们与 Enter 可区分，
			// 但多行输入用 Shift/Ctrl/Alt+Enter。
			return .Submit
		case 'k':
			editor_kill_to_end(e)
		case 'l':
			return .Redraw
		case 'n':
			return .History_Next
		case 'p':
			return .History_Prev
		case 'u':
			editor_kill_to_start(e)
		case 'w':
			editor_delete_word(e)
		case:
			return .None
		}
		return .None
	}

	if .Alt in key.mods {
		switch unicode.to_lower(key.r) {
		case 'b':
			editor_word_left(e)
		case 'f':
			editor_word_right(e)
		case 'd':
			editor_delete_word_forward(e)
		case:
			return .None
		}
		return .None
	}

	editor_insert_rune(e, key.r)
	return .None
}

editor_set_text :: proc(e: ^Editor, text: string) {
	clear(&e.buffer)
	e.cursor = 0
	e.desired_col = -1
	editor_insert_text(e, text)
	e.cursor = len(e.buffer)
	e.desired_col = -1
}

editor_delete_word_forward :: proc(e: ^Editor) {
	end := editor_word_end(e.buffer[:], e.cursor)
	if end == e.cursor {
		return
	}
	editor_remove_range(e, e.cursor, end)
}

// 当前光标所在 token 的起点（只按空白分词，不跳过空白）。
editor_token_start :: proc(buf: []u8, pos: int) -> int {
	i := pos
	if i > len(buf) {
		i = len(buf)
	}
	for i > 0 {
		r, _ := utf8.decode_last_rune_in_bytes(buf[:i])
		if editor_is_space(r) {
			break
		}
		i = editor_prev_rune_start(buf, i)
	}
	return i
}

common_prefix :: proc(a, b: string) -> string {
	i := 0
	j := 0
	for i < len(a) && j < len(b) {
		ra, sa := utf8.decode_rune(a[i:])
		rb, sb := utf8.decode_rune(b[j:])
		if ra != rb {
			break
		}
		i += sa
		j += sb
	}
	return a[:i]
}

// 单候选直接替换 token；多候选插入最长公共前缀，前缀没有变长就返回 false。
editor_apply_completions :: proc(e: ^Editor, completions: []Completion) -> bool {
	if len(completions) == 0 {
		return false
	}

	text := completions[0].text
	token_start := editor_token_start(e.buffer[:], e.cursor)
	token := string(e.buffer[token_start:e.cursor])

	if len(completions) > 1 {
		prefix := text
		for c in completions[1:] {
			prefix = common_prefix(prefix, c.text)
			if len(prefix) == 0 {
				break
			}
		}
		if len(prefix) <= len(token) || !strings.has_prefix(prefix, token) {
			return false
		}
		text = prefix
	}

	if len(text) == 0 {
		return false
	}
	editor_remove_range(e, token_start, e.cursor)
	e.cursor = token_start
	editor_insert_text(e, text)
	return true
}

editor_is_space :: proc(r: rune) -> bool {
	switch r {
	case ' ', '\t', '\n', '\r', '\v', '\f':
		return true
	}
	return false
}
