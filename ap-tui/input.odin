package aptui

import "core:bufio"
import "core:strings"

PASTE_FLUSH_MS :: 150
ESC_TIMEOUT_MS :: 20

// Input 把两条输入路径收在一起：raw 编辑框（term != nil）与 pipe/测试用的 bufio 回退。
Input :: struct {
	term:      ^Term,
	reader:    bufio.Reader,
	stdin_tty: bool,
}

read_prompt :: proc(app: ^App, input: ^Input) -> (text: string, eof: bool) {
	if input.term != nil {
		return read_prompt_raw(app, input.term)
	}

	write_prompt(app)
	line, at_eof := read_line(&input.reader)
	// TTY 下回车已经由终端换行；管道输入没有回显，需要自己补一个换行。
	if input.stdin_tty {
		app.renderer.at_line_start = true
	} else {
		ensure_line_start(&app.renderer)
	}
	return line, at_eof
}

read_prompt_raw :: proc(app: ^App, term: ^Term) -> (text: string, eof: bool) {
	ed: Editor
	editor_init(&ed)
	defer editor_destroy(&ed)

	decoder: Decoder
	defer decoder_destroy(&decoder)

	view := Editor_View {
		out   = app.renderer.out,
		color = app.renderer.color,
	}

	// raw 下 OPOST 被关闭，换行必须自带 \r。
	if !app.renderer.at_line_start {
		term_write(term, "\r\n")
	}
	app.renderer.at_line_start = false

	cols, rows := term_size(term)
	editor_view_draw(&view, &ed, cols, rows)

	prefix_width := editor_prefix_width()
	buf: [4096]u8
	submitted := false

	for !submitted {
		timeout := -1
		if decoder.mode == .Paste {
			// 终止符被截断时，不能把已收到的粘贴内容永远挂住。
			timeout = PASTE_FLUSH_MS
		} else if !term.kitty && decoder_incomplete(&decoder) {
			timeout = ESC_TIMEOUT_MS
		}

		n, timed_out, at_eof := term_read_chunk(term, buf[:], timeout)
		if at_eof {
			editor_view_abort(&view)
			app.renderer.at_line_start = true
			return "", true
		}

		events: [dynamic]Event
		if timed_out {
			events = decode_timeout(&decoder)
		} else {
			events = decode_feed(&decoder, buf[:n])
		}

		quit := false
		for ev in events {
			switch evt in ev {
			case Key:
				switch editor_apply_key(&ed, evt, cols, prefix_width) {
				case .Submit:
					submitted = true
				case .Quit:
					quit = true
				case .None:
				}
			case Paste:
				editor_insert_text(&ed, evt.text)
			case Unsupported:
			}
			if submitted || quit {
				break
			}
		}
		had_events := len(events) > 0
		events_destroy(&events)

		if quit {
			editor_view_abort(&view)
			app.renderer.at_line_start = true
			return "", true
		}
		if submitted {
			break
		}
		// 分片粘贴在终止符到达前不产生事件，也就不会反复重绘。
		if !had_events {
			continue
		}

		// 每次重绘重新取尺寸；窗口缩放后按新宽度布局。
		cols, rows = term_size(term)
		prefix_width = editor_prefix_width()
		editor_view_draw(&view, &ed, cols, rows)
	}

	// 提交：先把最后一次按键后的缓冲区完整画出来，再移动到块底下一行。
	cols, rows = term_size(term)
	editor_view_draw(&view, &ed, cols, rows)
	// trim 只用于判断是否为空；提交内容保留原样（包括 Ctrl+Enter 换行与行尾空格）。
	text = strings.clone(editor_text(&ed), context.temp_allocator)
	editor_view_finish(&view)
	app.renderer.at_line_start = true
	return text, false
}
