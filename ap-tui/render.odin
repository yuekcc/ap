package aptui

import client "../ap-core/client"
import protocol "../ap-core/protocol"

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
	project:               ^client.Project,
	at_line_start:         bool,
	assistant_active:      bool,
	message_had_text_delta: bool,
	tool_active:           bool,
}

write_text :: proc(r: ^Renderer, text: string) {
	if len(text) == 0 {
		return
	}
	_ = client.write_all(r.out, transmute([]byte)text)
	r.at_line_start = text[len(text) - 1] == '\n'
}

write_escape :: proc(r: ^Renderer, code: string) {
	if !r.color || len(code) == 0 {
		return
	}
	_ = client.write_all(r.out, transmute([]byte)code)
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

// 工具调用占两行：start 时写调用行，end 时另起一行缩进两格写状态。
tool_start :: proc(r: ^Renderer, name, args: string) {
	finish_assistant(r)
	ensure_line_start(r)
	paint(r, BOLD + YELLOW, "◆ ")
	write_text(r, name)
	if len(args) > 0 {
		write_text(r, " ")
		paint(r, DIM, fmt.tprintf("(%s)", args))
	}
	r.tool_active = true
}

// 工具输出不进终端：只保留耗时、结果状态和错误，完整结果在 transcript 里。
tool_end :: proc(r: ^Renderer, ok: bool, err: string, duration_ms: Maybe(int), exit_code: Maybe(int)) {
	if !r.tool_active {
		return
	}

	// 状态固定另起一行并缩进两格，避免长参数行被终端硬折行后状态落在行首。
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
		trimmed, _ := client.truncate_utf8(err, 200)
		oneline, _ := strings.replace_all(trimmed, "\n", " ", context.temp_allocator)
		paint(r, RED, fmt.tprintf(" %s", oneline))
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
	// handoff 不是失败：本轮正常结束，新 session 由 CLI 创建并把 id 写到 stderr。
	if len(stop_reason) == 0 ||
	   stop_reason == protocol.STOP_REASON_STOP ||
	   stop_reason == protocol.STOP_REASON_TOOL_USE ||
	   stop_reason == protocol.STOP_REASON_HANDOFF {
		return
	}
	finish_assistant(r)
	ensure_line_start(r)
	write_text(r, "\n")
	paint(r, YELLOW, fmt.tprintf("turn ended: %s", stop_reason))
	ensure_line_start(r)
}

render_event :: proc(r: ^Renderer, ev: protocol.Stream_Event, mode: Event_Mode) {
	switch ev.type {
	case protocol.EVENT_USER_MESSAGE:
		if mode == .History {
			user_message(r, client.user_message_text(ev))
		}
	case protocol.EVENT_MESSAGE_START:
		if mode == .Live {
			finish_assistant(r)
			r.message_had_text_delta = false
		}
	case protocol.EVENT_MESSAGE_UPDATE:
		if mode == .Live {
			if text, ok := ev.delta.text.?; ok && len(text) > 0 {
				assistant_text(r, text)
				r.message_had_text_delta = true
			}
			// reasoning 在 phase 1 不展示。
		}
	case protocol.EVENT_MESSAGE_END:
		if mode == .History || !r.message_had_text_delta {
			for text in client.message_texts(ev, r.project) {
				assistant_text(r, text)
			}
		}
		finish_assistant(r)
		r.message_had_text_delta = false
	case protocol.EVENT_TOOL_EXECUTION_START:
		tool_start(r, ev.name, client.tool_args_text(ev, r.project))
	case protocol.EVENT_TOOL_EXECUTION_END:
		err := ""
		if e, ok := ev.error.?; ok {
			err = e
		}
		tool_end(r, ev.ok, err, ev.duration_ms, ev.exit_code)
	case protocol.EVENT_ERROR:
		render_error(r, ev.scope, ev.message, ev.retryable)
	case protocol.EVENT_CANCEL:
		note(r, fmt.tprintf("cancelled [%s]", ev.scope))
	case protocol.EVENT_TURN_END:
		render_turn_end(r, ev.stop_reason)
	case:
		// session_start / session_end / turn_start / step_start 等不直接展示。
	}
}
