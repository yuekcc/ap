package aptui

import "core:strings"
import "core:unicode/utf8"

MAX_INPUT :: 1 << 20
TRUNCATED_NOTICE :: "\n[input truncated]"

// 编辑模型：buffer 是 UTF-8 字节串，cursor 是始终落在 rune 边界上的字节偏移。
// desired_col 只在连续上下移动之间保留可视列号，任何水平移动或编辑都会清掉它。
Editor :: struct {
	buffer:      [dynamic]u8,
	cursor:      int,
	desired_col: int,
}

editor_init :: proc(e: ^Editor, allocator := context.allocator) {
	e.buffer = make([dynamic]u8, 0, 256, allocator)
	e.cursor = 0
	e.desired_col = -1
}

editor_destroy :: proc(e: ^Editor) {
	delete(e.buffer)
	e^ = {}
}

editor_text :: proc(e: ^Editor) -> string {
	return string(e.buffer[:])
}

editor_reset :: proc(e: ^Editor) {
	clear(&e.buffer)
	e.cursor = 0
	e.desired_col = -1
}

editor_insert_rune :: proc(e: ^Editor, r: rune) {
	buf, size := utf8.encode_rune(r)
	editor_insert_limited(e, buf[:size])
}

// 返回是否发生了截断。粘贴文本里的 \r 会被丢掉，\n 保留。
editor_insert_text :: proc(e: ^Editor, text: string) -> bool {
	data := transmute([]u8)text
	has_cr := false
	for b in data {
		if b == '\r' {
			has_cr = true
			break
		}
	}
	if !has_cr {
		return editor_insert_limited(e, data)
	}
	filtered: [dynamic]u8
	defer delete(filtered)
	for b in data {
		if b != '\r' {
			append(&filtered, b)
		}
	}
	return editor_insert_limited(e, filtered[:])
}

editor_insert_limited :: proc(e: ^Editor, data: []u8) -> bool {
	available := MAX_INPUT - len(e.buffer)
	if available <= 0 {
		return len(data) > 0
	}
	if len(data) <= available {
		editor_insert_bytes(e, data)
		return false
	}

	notice := TRUNCATED_NOTICE
	if available <= len(notice) {
		// 剩余空间连提示都放不下，直接丢弃。
		return true
	}
	keep := available - len(notice)
	// 不要把 UTF-8 rune 切成两半。
	for keep > 0 && keep < len(data) && (data[keep] & 0xc0) == 0x80 {
		keep -= 1
	}
	editor_insert_bytes(e, data[:keep])
	editor_insert_bytes(e, transmute([]u8)notice)
	return true
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

// Ctrl+W：先跳过光标前的空白，再删到前一个空白或行首。以空白分词，路径算一个词。
editor_delete_word :: proc(e: ^Editor) {
	if e.cursor <= 0 {
		return
	}
	i := e.cursor
	for i > 0 {
		r, _ := utf8.decode_last_rune_in_bytes(e.buffer[:i])
		if !editor_is_space(r) {
			break
		}
		i = editor_prev_rune_start(e.buffer[:], i)
	}
	start := i
	for start > 0 {
		r, _ := utf8.decode_last_rune_in_bytes(e.buffer[:start])
		if editor_is_space(r) {
			break
		}
		start = editor_prev_rune_start(e.buffer[:], start)
	}
	if start == e.cursor {
		return
	}
	editor_remove_range(e, start, e.cursor)
}

editor_is_empty :: proc(e: ^Editor) -> bool {
	return len(e.buffer) == 0
}

// Ctrl+C 且缓冲区为空 → 退出；Enter 且 trim 后非空 → 提交。其余按键原地处理。
Editor_Action :: enum {
	None,
	Submit,
	Quit,
}

editor_apply_key :: proc(e: ^Editor, key: Key, cols, prefix_width: int) -> Editor_Action {
	switch key.kind {
	case .Rune:
		editor_insert_rune(e, key.r)
	case .Backspace:
		editor_backspace(e)
	case .Delete:
		editor_delete(e)
	case .Left:
		editor_left(e)
	case .Right:
		editor_right(e)
	case .Up:
		editor_up(e, cols, prefix_width)
	case .Down:
		editor_down(e, cols, prefix_width)
	case .Home, .Ctrl_A:
		editor_home(e)
	case .End, .Ctrl_E:
		editor_end(e)
	case .Ctrl_K:
		editor_kill_to_end(e)
	case .Ctrl_U:
		editor_kill_to_start(e)
	case .Ctrl_W:
		editor_delete_word(e)
	case .Ctrl_Enter:
		editor_insert_rune(e, '\n')
	case .Enter:
		if len(strings.trim_space(editor_text(e))) > 0 {
			return .Submit
		}
		// trim 后为空则不提交，重绘空提示符。
		editor_reset(e)
	case .Ctrl_C:
		if editor_is_empty(e) {
			return .Quit
		}
		editor_reset(e)
	case .Escape:
		editor_reset(e)
	case .Ignore:
	}
	return .None
}

editor_is_space :: proc(r: rune) -> bool {
	switch r {
	case ' ', '\t', '\n', '\r', '\v', '\f':
		return true
	}
	return false
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
	defer delete(l.rows)

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
		r, size := utf8.decode_rune_in_bytes(buf[i:])
		if size <= 0 {
			size = 1
		}
		w := rune_width(r)
		if c + w > desired {
			break
		}
		c += w
		i += size
	}
	return i, c
}
