package aptui

import lineedit "../lineedit"

import "core:os"
import "core:strings"

// Input 把行编辑交给 lineedit。raw 只在每条 prompt 期间打开：
// turn 运行期间恢复 cooked mode，Ctrl+C 仍然是内核 SIGINT。
Input :: struct {
	editor:    lineedit.Line_Editor,
	stdin_tty: bool,
	inited:    bool,
}

Tui_Command :: struct {
	text:        string,
	description: string,
}

TUI_COMMANDS := [?]Tui_Command {
	{"/new", "丢弃当前 session，下一条提示词新建 session"},
	{"/session", "显示当前 session id"},
	{"/help", "显示命令列表"},
	{"/quit", "退出"},
	{"/exit", "退出（/quit 同义）"},
}

// 只补全整行都是斜杠命令的情况；带空格或参数后不再补全。
tui_complete :: proc(ctx: rawptr, line: string, cursor: int, out: ^[dynamic]lineedit.Completion) {
	_, _ = ctx, cursor
	token := strings.trim_left_space(line)
	if len(token) == 0 || token[0] != '/' {
		return
	}
	for i in 0 ..< len(token) {
		switch token[i] {
		case ' ', '\t', '\n', '\r':
			return
		}
	}
	for cmd in TUI_COMMANDS {
		if !strings.has_prefix(cmd.text, token) {
			continue
		}
		text, err := strings.clone(cmd.text)
		if err != nil {
			continue
		}
		desc, derr := strings.clone(cmd.description)
		if derr != nil {
			delete(text)
			continue
		}
		append(out, lineedit.Completion{text = text, description = desc})
	}
}

input_init :: proc(input: ^Input) -> bool {
	input^ = {}
	input.stdin_tty = os.is_tty(os.stdin)
	input.inited = lineedit.line_editor_init_file(&input.editor, os.stdin, os.stdout)
	if input.inited {
		input.editor.config.completer = lineedit.Completer{complete = tui_complete}
	}
	return input.inited
}

input_destroy :: proc(input: ^Input) {
	if input.inited {
		lineedit.line_editor_destroy(&input.editor)
		input.inited = false
	}
}

// 一轮 turn 之后先空一行，再画下一条提示符；只在本轮真的跑过 ap 时生效。
// raw 下 OPOST 被关闭，不能经 renderer 写裸 \n。
write_turn_gap :: proc(app: ^App, input: ^Input) {
	if !app.prompt_gap {
		return
	}
	app.prompt_gap = false

	if input.inited && input.editor.raw {
		if !app.renderer.at_line_start {
			lineedit.line_editor_write_string(&input.editor, "\r\n")
		}
		lineedit.line_editor_write_string(&input.editor, "\r\n")
		app.renderer.at_line_start = true
		return
	}

	ensure_line_start(&app.renderer)
	write_text(&app.renderer, "\n")
}

read_prompt :: proc(app: ^App, input: ^Input) -> (text: string, eof: bool) {
	if input.inited {
		// 每轮 prompt 前进入 raw；begin/read_line 也会自动进入，这里是幂等的。
		_ = lineedit.line_editor_enter_raw(&input.editor)
	}
	write_turn_gap(app, input)

	if input.inited && input.editor.raw {
		// 上一段输出不一定停在行首；raw 下补 \r\n 后再画 prompt。
		if !app.renderer.at_line_start {
			lineedit.line_editor_write_string(&input.editor, "\r\n")
		}
		app.renderer.at_line_start = false

		prompt := "› "
		if app.renderer.color {
			prompt = BOLD + CYAN + "› " + RESET
		}

		line, status := lineedit.line_editor_read_line(&input.editor, prompt)
		switch status {
		case .Ok:
			text = strings.clone(line, context.temp_allocator)
			delete(line)
			app.renderer.at_line_start = true
			lineedit.line_editor_leave_raw(&input.editor)
			return text, false
		case .Cancel, .Eof, .Error:
			app.renderer.at_line_start = true
			lineedit.line_editor_leave_raw(&input.editor)
			return "", true
		}
	}

	// 非 tty：lineedit 的 pipe 模式不画提示符，由 renderer 补。
	write_prompt(app)
	line, status := lineedit.line_editor_read_line(&input.editor, "")
	switch status {
	case .Ok:
		text = strings.clone(line, context.temp_allocator)
		delete(line)
		if input.stdin_tty {
			app.renderer.at_line_start = true
		} else {
			ensure_line_start(&app.renderer)
		}
		return text, false
	case .Cancel, .Eof, .Error:
		return "", true
	}
	return "", true
}
