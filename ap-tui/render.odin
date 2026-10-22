package tui

import "core:fmt"
import "core:os"
import "core:strings"

RESET      :: "\x1b[0m"
BOLD       :: "\x1b[1m"
DIM        :: "\x1b[2m"
RED        :: "\x1b[31m"
GREEN      :: "\x1b[32m"
YELLOW     :: "\x1b[33m"
CYAN       :: "\x1b[36m"

Event_Mode :: enum {
	Live,
	History,
}

Renderer :: struct {
	out:                   ^os.File,
	color:                 bool,
	project:               ^Project,
	at_line_start:         bool,
	assistant_active:      bool,
	message_had_text_delta: bool,
	tool_active:           bool,
	tool_had_update:       bool,
}

write_text :: proc(r: ^Renderer, text: string) {
	if len(text) == 0 {
		return
	}
	_ = write_all(r.out, transmute([]byte)text)
	r.at_line_start = text[len(text) - 1] == '\n'
}

write_escape :: proc(r: ^Renderer, code: string) {
	if !r.color || len(code) == 0 {
		return
	}
	_ = write_all(r.out, transmute([]byte)code)
}

paint :: proc(r: ^Renderer, code, text: string) {
	if len(text) == 0 {
		return
	}
	write_escape(r, code)
	write_text(r, text)
	write_escape(r, RESET)
}

ensure_line_start :: proc(r: ^Renderer) {
	if !r.at_line_start {
		write_text(r, "\n")
	}
}

note :: proc(r: ^Renderer, text: string) {
	finish_assistant(r)
	ensure_line_start(r)
	paint(r, DIM, text)
	ensure_line_start(r)
}

user_message :: proc(r: ^Renderer, text: string) {
	ensure_line_start(r)
	write_text(r, "\n")
	paint(r, BOLD + CYAN, "› ")
	write_text(r, text)
	ensure_line_start(r)
}

assistant_text :: proc(r: ^Renderer, text: string) {
	if len(text) == 0 {
		return
	}
	if !r.assistant_active {
		ensure_line_start(r)
		paint(r, BOLD + GREEN, "● ")
		r.assistant_active = true
	}
	write_text(r, text)
}

finish_assistant :: proc(r: ^Renderer) {
	if r.assistant_active {
		ensure_line_start(r)
		r.assistant_active = false
	}
}

// 工具输出按两格缩进、暗色显示；跨 chunk 维护行首状态。
write_indented_dim :: proc(r: ^Renderer, text: string) {
	if len(text) == 0 {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&b)

	at_start := r.at_line_start
	for i in 0 ..< len(text) {
		ch := text[i]
		if at_start && ch != '\n' {
			strings.write_string(&b, "  ")
			at_start = false
		}
		strings.write_byte(&b, ch)
		if ch == '\n' {
			at_start = true
		}
	}
	paint(r, DIM, strings.to_string(b))
	r.at_line_start = at_start
}

tool_start :: proc(r: ^Renderer, name, args: string) {
	finish_assistant(r)
	ensure_line_start(r)
	paint(r, BOLD + YELLOW, "⚙ ")
	write_text(r, name)
	if len(args) > 0 {
		write_text(r, " ")
		paint(r, DIM, fmt.tprintf("(%s)", args))
	}
	ensure_line_start(r)
	r.tool_active = true
	r.tool_had_update = false
}

tool_update :: proc(r: ^Renderer, chunk: string) {
	if !r.tool_active || len(chunk) == 0 {
		return
	}
	r.tool_had_update = true
	write_indented_dim(r, chunk)
}

tool_end :: proc(
	r: ^Renderer,
	ok: bool,
	content: string,
	has_content: bool,
	err: string,
	duration_ms: Maybe(int),
	exit_code: Maybe(int),
) {
	if !r.tool_active {
		return
	}

	if ok && !r.tool_had_update && has_content && len(content) > 0 {
		preview, truncated := preview_content(content)
		write_indented_dim(r, preview)
		if truncated {
			write_indented_dim(r, "… (truncated; full content is in the transcript)\n")
		}
	}

	ensure_line_start(r)
	paint(r, DIM, "  ")
	if ok {
		paint(r, GREEN, "✓")
	} else {
		paint(r, RED, "✗")
	}

	meta := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&meta)
	if ms, has := duration_ms.?; has {
		fmt.sbprintf(&meta, " %dms", ms)
	}
	if code, has := exit_code.?; has {
		fmt.sbprintf(&meta, " exit %d", code)
	}
	if strings.builder_len(meta) > 0 {
		paint(r, DIM, strings.to_string(meta))
	}
	if !ok && len(err) > 0 {
		paint(r, RED, fmt.tprintf(" %s", err))
	}
	ensure_line_start(r)
	r.tool_active = false
}

render_error :: proc(r: ^Renderer, scope, message: string, retryable: bool) {
	finish_assistant(r)
	ensure_line_start(r)
	if retryable {
		paint(r, YELLOW, "… ")
	} else {
		paint(r, BOLD + RED, "! ")
	}
	if len(scope) > 0 {
		paint(r, YELLOW if retryable else RED, fmt.tprintf("[%s] ", scope))
	}
	paint(r, YELLOW if retryable else RED, message)
	ensure_line_start(r)
}

render_turn_end :: proc(r: ^Renderer, stop_reason: string) {
	if len(stop_reason) == 0 || stop_reason == "stop" || stop_reason == "tool_use" {
		return
	}
	finish_assistant(r)
	ensure_line_start(r)
	write_text(r, "\n")
	paint(r, YELLOW, fmt.tprintf("turn ended: %s", stop_reason))
	ensure_line_start(r)
}

render_event :: proc(r: ^Renderer, ev: Event, mode: Event_Mode) {
	switch ev.type {
	case "user_message":
		if mode == .History {
			user_message(r, user_message_text(ev))
		}
	case "message_start":
		if mode == .Live {
			finish_assistant(r)
			r.message_had_text_delta = false
		}
	case "message_update":
		if mode == .Live {
			if text, ok := ev.delta.text.?; ok && len(text) > 0 {
				assistant_text(r, text)
				r.message_had_text_delta = true
			}
			// reasoning 在 phase 1 不展示。
		}
	case "message_end":
		if mode == .History || !r.message_had_text_delta {
			for text in message_texts(ev, r.project) {
				assistant_text(r, text)
			}
		}
		finish_assistant(r)
		r.message_had_text_delta = false
	case "tool_execution_start":
		tool_start(r, ev.name, tool_args_text(ev, r.project))
	case "tool_execution_update":
		if mode == .Live {
			tool_update(r, ev.chunk)
		}
	case "tool_execution_end":
		content, has_content := tool_result_text(ev, r.project)
		err := ""
		if e, ok := ev.error.?; ok {
			err = e
		}
		tool_end(r, ev.ok, content, has_content, err, ev.duration_ms, ev.exit_code)
	case "error":
		render_error(r, ev.scope, ev.message, ev.retryable)
	case "cancel":
		note(r, fmt.tprintf("cancelled [%s]", ev.scope))
	case "turn_end":
		render_turn_end(r, ev.stop_reason)
	case:
		// session_start / session_end / turn_start / step_start 等不直接展示。
	}
}
