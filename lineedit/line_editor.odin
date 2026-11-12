package lineedit

import "core:os"
import "core:strings"

PASTE_FLUSH_MS :: 150
ESC_TIMEOUT_MS :: 20

Read_Status :: enum {
	Ok,
	Eof,
	Cancel,
	Error,
}

// 返回的 string 只需在当前这一帧内有效；编辑器不会释放它。
Hint_Proc :: proc(ctx: rawptr, line: string, cursor: int) -> string

Config :: struct {
	max_input:       int,
	history_max:     int,
	color:           bool,
	mask:            bool,
	bracketed_paste: bool,
	kitty:           bool,
	hint:            Hint_Proc,
	hint_ctx:        rawptr,
	completer:       Completer,
}

DEFAULT_CONFIG :: Config {
	max_input = MAX_INPUT,
	history_max = DEFAULT_HISTORY_MAX_LEN,
	color = true,
	bracketed_paste = true,
	kitty = true,
}

config_default :: proc() -> Config {
	return DEFAULT_CONFIG
}

Feed_Status :: enum {
	Continue,
	Submitted,
	Canceled,
	Eof,
	Error,
}

Line_Editor :: struct {
	transport: Transport,
	config:    Config,
	decoder:   Decoder,
	editor:    Editor,
	history:   History,
	renderer:   Renderer,
	completion: Completion_Menu,
	out:        [dynamic]u8,
	pipe_buf:   [dynamic]u8,
	prompt:     string,
	cfg:       Render_Config,
	cols:      int,
	rows:      int,
	raw:       bool,
	inited:    bool,
	active:    bool,
}

line_editor_init_transport :: proc(le: ^Line_Editor, transport: Transport, config := DEFAULT_CONFIG) -> bool {
	if le == nil || le.inited {
		return false
	}
	if transport.read == nil || transport.write == nil || transport.size == nil ||
	   transport.enter_raw == nil || transport.leave_raw == nil {
		return false
	}

	le^ = {}
	le.transport = transport
	le.config = config
	if le.config.max_input <= 0 {
		le.config.max_input = MAX_INPUT
	}
	if le.config.history_max < 0 {
		le.config.history_max = 0
	}

	decoder_init(&le.decoder)
	editor_init(&le.editor, le.config.max_input)
	history_init(&le.history, le.config.history_max)
	render_init(&le.renderer)
	le.out = make([dynamic]u8, 0, 256)
	le.pipe_buf = make([dynamic]u8, 0, 256)

	le.inited = true
	_ = line_editor_enter_raw(le)
	return true
}

// 进入/离开 raw 模式可以成对调用，方便调用方在两轮输入之间正常打印。
line_editor_enter_raw :: proc(le: ^Line_Editor) -> bool {
	if le == nil || !le.inited {
		return false
	}
	if le.raw {
		return true
	}
	le.raw = le.transport.enter_raw(le.transport.ctx)
	if le.raw {
		if le.config.kitty {
			line_editor_write_string(le, "\x1b[>1u")
		}
		if le.config.bracketed_paste {
			line_editor_write_string(le, "\x1b[?2004h")
		}
	}
	return le.raw
}

line_editor_leave_raw :: proc(le: ^Line_Editor) {
	if le == nil || !le.inited || !le.raw {
		return
	}
	if le.config.kitty {
		line_editor_write_string(le, "\x1b[<u")
	}
	if le.config.bracketed_paste {
		line_editor_write_string(le, "\x1b[?2004l")
	}
	le.transport.leave_raw(le.transport.ctx)
	le.raw = false
}

line_editor_init_file :: proc(
	le: ^Line_Editor,
	input, output: ^os.File,
	config := DEFAULT_CONFIG,
) -> bool {
	if le == nil || le.inited {
		return false
	}
	return line_editor_init_transport(le, file_transport_make(input, output), config)
}

line_editor_destroy :: proc(le: ^Line_Editor) {
	if le == nil || !le.inited {
		return
	}

	line_editor_leave_raw(le)

	line_editor_completion_clear(le)
	decoder_destroy(&le.decoder)
	editor_destroy(&le.editor)
	history_destroy(&le.history)
	delete(le.out)
	delete(le.pipe_buf)
	delete(le.prompt)
	if le.transport.destroy != nil {
		le.transport.destroy(le.transport.ctx)
	}
	le^ = {}
}

// 开始一行。prompt 会被复制，调用方之后可以释放自己的字符串。
line_editor_begin :: proc(le: ^Line_Editor, prompt: string) -> bool {
	if le == nil || !le.inited || le.active {
		return false
	}
	if !le.raw && !line_editor_enter_raw(le) {
		return false
	}

	editor_reset(&le.editor)
	history_reset(&le.history)
	decoder_reset(&le.decoder)
	render_init(&le.renderer)
	line_editor_completion_clear(le)

	delete(le.prompt)
	cloned, err := strings.clone(prompt, context.allocator)
	if err != nil {
		return false
	}
	le.prompt = cloned

	le.cfg = Render_Config {
		prompt       = le.prompt,
		prefix_width = display_width(le.prompt),
		color        = le.config.color,
		mask         = le.config.mask,
	}
	le.active = true
	line_editor_redraw_current(le)
	return true
}

// 外部事件循环在 stdin 可读时调用。返回 Submitted 时 line 由调用方释放。
line_editor_feed :: proc(le: ^Line_Editor, data: []u8) -> (line: string, status: Feed_Status) {
	if le == nil || !le.active {
		return "", .Error
	}
	events := decode_feed(&le.decoder, data)
	return line_editor_process_events(le, &events)
}

// 外部事件循环在 poll 超时后调用，用于落地孤立的 ESC 或冲刷粘贴。
line_editor_timeout :: proc(le: ^Line_Editor) -> (line: string, status: Feed_Status) {
	if le == nil || !le.active {
		return "", .Error
	}
	events := decode_timeout(&le.decoder)
	return line_editor_process_events(le, &events)
}

// 返回 -1 表示可以无限等；否则用作 poll/select 的超时毫秒数。
line_editor_poll_timeout :: proc(le: ^Line_Editor) -> int {
	if le == nil || !le.active {
		return -1
	}
	if decoder_state(&le.decoder) == .Paste {
		return PASTE_FLUSH_MS
	}
	if decoder_incomplete(&le.decoder) {
		return ESC_TIMEOUT_MS
	}
	return -1
}

line_editor_resize :: proc(le: ^Line_Editor) -> bool {
	if le == nil || !le.active {
		return false
	}
	line_editor_redraw_current(le)
	return true
}

// 隐藏当前编辑块，允许调用方在中间打印异步输出；随后用 show 重新画出来。
// 异步输出最好以 \r\n 结尾，否则 show 会从当前光标位置继续画。
line_editor_hide :: proc(le: ^Line_Editor) -> bool {
	if le == nil || !le.active {
		return false
	}
	line_editor_abort(le)
	return true
}

line_editor_show :: proc(le: ^Line_Editor) -> bool {
	if le == nil || !le.active {
		return false
	}
	line_editor_redraw_current(le)
	return true
}

// 外部取消/信号路径用这个清掉正在编辑的块。
line_editor_abort_line :: proc(le: ^Line_Editor) {
	if le == nil || !le.active {
		return
	}
	line_editor_completion_clear(le)
	line_editor_abort(le)
	le.active = false
}

line_editor_redraw_current :: proc(le: ^Line_Editor) {
	le.cols, le.rows = le.transport.size(le.transport.ctx)
	if le.cols <= 0 {
		le.cols = 80
	}
	if le.rows <= 0 {
		le.rows = 24
	}
	line_editor_update_render_cfg(le, &le.cfg)
	line_editor_redraw(le, le.cfg, le.cols, le.rows)
}

line_editor_update_render_cfg :: proc(le: ^Line_Editor, cfg: ^Render_Config) {
	cfg.hint = ""
	if le.completion.active && len(le.completion.items) > 0 {
		cfg.menu = le.completion.items[:]
		cfg.menu_selected = le.completion.selected
	} else {
		cfg.menu = nil
		cfg.menu_selected = -1
	}
	if !le.completion.active && le.config.hint != nil && !le.config.mask {
		cfg.hint = le.config.hint(le.config.hint_ctx, editor_text(&le.editor), le.editor.cursor)
	}
}

line_editor_completion_clear :: proc(le: ^Line_Editor) {
	for c in le.completion.items {
		delete(c.text)
		delete(c.description)
	}
	delete(le.completion.items)
	le.completion = {}
}

line_editor_completion_apply :: proc(le: ^Line_Editor) {
	idx := le.completion.selected
	if idx < 0 || idx >= len(le.completion.items) {
		return
	}
	start := le.completion.token_start
	if start < 0 || start > le.editor.cursor {
		start = editor_token_start(le.editor.buffer[:], le.editor.cursor)
	}
	editor_remove_range(&le.editor, start, le.editor.cursor)
	editor_insert_text(&le.editor, le.completion.items[idx].text)
}

line_editor_completion_step :: proc(le: ^Line_Editor, delta: int) -> bool {
	n := len(le.completion.items)
	if !le.completion.active || n == 0 {
		return false
	}
	if le.completion.selected < 0 {
		if delta > 0 {
			le.completion.selected = 0
		} else {
			le.completion.selected = n - 1
		}
	} else {
		x := (le.completion.selected + delta) % n
		if x < 0 {
			x += n
		}
		le.completion.selected = x
	}
	line_editor_completion_apply(le)
	return true
}

line_editor_start_completion :: proc(le: ^Line_Editor, backward: bool) -> bool {
	line_editor_completion_clear(le)
	if le.config.mask || le.config.completer.complete == nil {
		return false
	}

	le.config.completer.complete(
		le.config.completer.ctx,
		editor_text(&le.editor),
		le.editor.cursor,
		&le.completion.items,
	)

	n := len(le.completion.items)
	if n == 0 {
		line_editor_completion_clear(le)
		return false
	}

	le.completion.token_start = editor_token_start(le.editor.buffer[:], le.editor.cursor)
	if n == 1 {
		le.completion.selected = 0
		line_editor_completion_apply(le)
		line_editor_completion_clear(le)
		return true
	}

	token := string(le.editor.buffer[le.completion.token_start:le.editor.cursor])
	prefix := le.completion.items[0].text
	for i in 1 ..< n {
		prefix = common_prefix(prefix, le.completion.items[i].text)
	}
	if len(prefix) > len(token) && strings.has_prefix(prefix, token) {
		editor_remove_range(&le.editor, le.completion.token_start, le.editor.cursor)
		editor_insert_text(&le.editor, prefix)
	}

	le.completion.active = true
	le.completion.selected = -1
	if backward {
		_ = line_editor_completion_step(le, -1)
	}
	return true
}

key_is_complete :: proc(key: Key) -> bool {
	if key.kind == .Tab && .Shift not_in key.mods {
		return true
	}
	if key.kind == .Rune && .Ctrl in key.mods && (key.r == 'i' || key.r == 'I') {
		return true
	}
	return false
}

key_is_complete_prev :: proc(key: Key) -> bool {
	return key.kind == .Tab && .Shift in key.mods
}

line_editor_process_events :: proc(
	le: ^Line_Editor,
	events: ^[dynamic]Event,
) -> (line: string, status: Feed_Status) {
	submitted := false
	canceled := false
	want_eof := false
	changed := false

	for ev in events^ {
		switch e in ev {
		case Key:
			if le.completion.active {
				if key_is_complete(e) {
					if line_editor_completion_step(le, 1) {
						changed = true
					}
					continue
				}
				if key_is_complete_prev(e) {
					if line_editor_completion_step(le, -1) {
						changed = true
					}
					continue
				}
				#partial switch e.kind {
				case .Up:
					if line_editor_completion_step(le, -1) {
						changed = true
					}
					continue
				case .Down:
					if line_editor_completion_step(le, 1) {
						changed = true
					}
					continue
				case .Escape:
					// 菜单打开时 Esc 只关菜单，不清空输入。
					line_editor_completion_clear(le)
					changed = true
					continue
				case:
					line_editor_completion_clear(le)
					changed = true
				}
			}

			switch editor_apply_key(&le.editor, e, le.cols, le.cfg.prefix_width) {
			case .Submit:
				submitted = true
			case .Cancel:
				canceled = true
			case .Eof:
				want_eof = true
			case .History_Prev:
				line_editor_completion_clear(le)
				if text, ok := history_prev(&le.history, editor_text(&le.editor)); ok {
					editor_set_text(&le.editor, text)
					changed = true
				}
			case .History_Next:
				line_editor_completion_clear(le)
				if text, ok := history_next(&le.history, editor_text(&le.editor)); ok {
					editor_set_text(&le.editor, text)
					changed = true
				}
			case .Redraw:
				changed = true
			case .Complete:
				if le.config.completer.complete != nil {
					if line_editor_start_completion(le, false) {
						changed = true
					}
				} else {
					// 没有补全器时 Tab 插入一个制表符。
					editor_insert_rune(&le.editor, '\t')
					changed = true
				}
			case .Complete_Prev:
				if le.config.completer.complete != nil {
					if line_editor_start_completion(le, true) {
						changed = true
					}
				}
			case .None:
				// 普通文本输入、删除、光标移动都返回 None；除明确无动作的键外都重绘。
				if e.kind != .Ignore && e.kind != .Insert {
					changed = true
				}
			}
		case Paste:
			line_editor_completion_clear(le)
			editor_insert_text(&le.editor, e.text)
			changed = true
		case Unsupported:
		}
		if submitted || canceled || want_eof {
			break
		}
	}
	events_destroy(events)

	if canceled {
		line_editor_completion_clear(le)
		line_editor_abort(le)
		le.active = false
		return "", .Canceled
	}
	if want_eof {
		line_editor_completion_clear(le)
		line_editor_abort(le)
		le.active = false
		return "", .Eof
	}
	if submitted {
		// 同一 chunk 里可能同时到达文本和 Enter：提交前补画最后一次缓冲区。
		// 菜单和提示词不留在最终行上。
		line_editor_completion_clear(le)
		line_editor_update_render_cfg(le, &le.cfg)
		le.cfg.hint = ""
		line_editor_redraw(le, le.cfg, le.cols, le.rows)
		current := editor_text(&le.editor)
		text, err := strings.clone(current, context.allocator)
		if err != nil {
			line_editor_abort(le)
			le.active = false
			return "", .Error
		}
		line_editor_finish(le)
		if len(strings.trim_space(current)) > 0 {
			history_add(&le.history, current)
		}
		history_reset(&le.history)
		le.active = false
		return text, .Submitted
	}
	if changed {
		line_editor_redraw_current(le)
	}
	return "", .Continue
}

line_editor_read_line :: proc(le: ^Line_Editor, prompt: string) -> (line: string, status: Read_Status) {
	if le == nil || !le.inited {
		return "", .Error
	}
	if !le.raw {
		return read_pipe_line(le)
	}
	if !line_editor_begin(le, prompt) {
		return "", .Error
	}

	buf: [4096]u8
	for {
		timeout := line_editor_poll_timeout(le)
		n, timed_out, eof := le.transport.read(le.transport.ctx, buf[:], timeout)
		if eof {
			line_editor_abort_line(le)
			return "", .Eof
		}

		got: string
		feed: Feed_Status
		if timed_out {
			got, feed = line_editor_timeout(le)
		} else {
			got, feed = line_editor_feed(le, buf[:n])
		}

		switch feed {
		case .Continue:
		case .Submitted:
			return got, .Ok
		case .Canceled:
			return "", .Cancel
		case .Eof:
			return "", .Eof
		case .Error:
			return "", .Error
		}
	}
}

line_editor_redraw :: proc(le: ^Line_Editor, cfg: Render_Config, cols, rows: int) {
	clear(&le.out)
	render_frame(&le.renderer, &le.out, &le.editor, cfg, cols, rows)
	line_editor_write(le, le.out[:])
}

line_editor_finish :: proc(le: ^Line_Editor) {
	clear(&le.out)
	render_finish(&le.renderer, &le.out)
	line_editor_write(le, le.out[:])
}

line_editor_abort :: proc(le: ^Line_Editor) {
	clear(&le.out)
	render_abort(&le.renderer, &le.out)
	line_editor_write(le, le.out[:])
}

line_editor_write :: proc(le: ^Line_Editor, data: []u8) {
	if len(data) == 0 {
		return
	}
	_ = le.transport.write(le.transport.ctx, data)
}

line_editor_write_string :: proc(le: ^Line_Editor, s: string) {
	if len(s) == 0 {
		return
	}
	line_editor_write(le, transmute([]u8)s)
}

// 非 tty（管道/CI）不走 raw/渲染，直接按行读取。保留跨 read_line 的剩余字节。
read_pipe_line :: proc(le: ^Line_Editor) -> (line: string, status: Read_Status) {
	for {
		for i in 0 ..< len(le.pipe_buf) {
			if le.pipe_buf[i] != '\n' {
				continue
			}
			end := i
			if end > 0 && le.pipe_buf[end - 1] == '\r' {
				end -= 1
			}
			text, err := strings.clone_from_bytes(le.pipe_buf[:end], context.allocator)
			if err != nil {
				return "", .Error
			}
			remaining := len(le.pipe_buf) - (i + 1)
			copy(le.pipe_buf[:], le.pipe_buf[i + 1:])
			resize(&le.pipe_buf, remaining)
			return text, .Ok
		}

		tmp: [4096]u8
		n, _, eof := le.transport.read(le.transport.ctx, tmp[:], -1)
		if n > 0 {
			for j in 0 ..< n {
				append(&le.pipe_buf, tmp[j])
			}
		}
		if eof {
			if len(le.pipe_buf) == 0 {
				return "", .Eof
			}
			end := len(le.pipe_buf)
			if end > 0 && le.pipe_buf[end - 1] == '\r' {
				end -= 1
			}
			text, err := strings.clone_from_bytes(le.pipe_buf[:end], context.allocator)
			if err != nil {
				return "", .Error
			}
			clear(&le.pipe_buf)
			return text, .Ok
		}
	}
}
