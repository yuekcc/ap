package aptui

import client "../ap-core/client"
import protocol "../ap-core/protocol"

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

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
	// 本轮收到过 cancel 事件。取消不单独上屏，由结束行统一收尾。
	cancelled:             bool,
	glow:                  Glow_Config,
	// 最后一条 assistant 消息的原始 Markdown，供 /copy 使用。
	last_assistant_text:   string,
}

write_text :: proc(r: ^Renderer, text: string) {
	if len(text) == 0 {
		return
	}
	if !client.write_all(r.out, transmute([]byte)text) {
		// 写失败时终端实际状态没变，渲染器状态也不能跟着变，否则后续每个
		// ensure_line_start 都基于错误的前提。
		return
	}
	r.at_line_start = text[len(text) - 1] == '\n'
}

write_escape :: proc(r: ^Renderer, code: string) {
	if !r.color || len(code) == 0 {
		return
	}
	// 颜色转义写失败不影响布局状态（at_line_start 只由可见文本更新）。
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

// message_text 把 message_end 里的文本块拼成一段 Markdown。多个文本块之间
// 空一行，让 glow 按独立段落渲染。
message_text :: proc(r: ^Renderer, ev: protocol.Stream_Event) -> string {
	texts := client.message_texts(ev, r.project)
	if len(texts) == 0 {
		return ""
	}
	if len(texts) == 1 {
		return texts[0]
	}
	b := strings.builder_make(context.temp_allocator)
	for text, i in texts {
		if i > 0 {
			strings.write_string(&b, "\n\n")
		}
		strings.write_string(&b, text)
	}
	return strings.to_string(b)
}

// 记住最后一条 assistant 文本供 /copy。没有正文的消息（例如整轮只有工具
// 调用）不覆盖上一条，避免 /copy 因为最近一条为空而失效。
remember_assistant_text :: proc(r: ^Renderer, text: string) {
	if len(text) == 0 {
		return
	}
	cloned, err := strings.clone(text, context.allocator)
	if err != nil {
		return
	}
	if len(r.last_assistant_text) > 0 {
		delete(r.last_assistant_text, context.allocator)
	}
	r.last_assistant_text = cloned
}

// glow 模式下 assistant 文本不再逐 delta 输出：等 message_end 拿到完整
// Markdown 后一次渲染。失败时退回原始文本，并关闭本次进程内的开关，
// 避免每条消息都白起一次进程、重复报错。
assistant_markdown :: proc(r: ^Renderer, text: string) {
	if len(text) == 0 {
		return
	}
	render := r.glow.render
	if render == nil {
		render = run_glow
	}
	rendered, err := render(text, r.glow.width, r.color)
	if !client.is_ok(err) {
		r.glow.enabled = false
		note(r, fmt.tprintf("glow failed; showing raw output: %s", err.message))
		assistant_text(r, text)
		return
	}
	body := strings.trim(rendered, "\r\n")
	if len(body) == 0 {
		return
	}
	ensure_line_start(r)
	paint(r, BOLD + GREEN, "● ")
	write_text(r, body)
	ensure_line_start(r)
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

// 整轮耗时的可读形式。一轮可能跑几分钟，按粒度换单位，避免出现
// 六位数毫秒这种难读的数。
format_elapsed :: proc(elapsed: time.Duration) -> string {
	// 先转成纯整数：fmt 认出 Duration 时会自己补单位，%d 会打出 "3ns"。
	d := i64(elapsed)
	if d < 0 {
		d = 0
	}
	ms := d / i64(time.Millisecond)
	if ms < 1000 {
		return fmt.tprintf("%dms", ms)
	}
	seconds := d / i64(time.Second)
	if seconds < 60 {
		tenths := (d % i64(time.Second)) / i64(100 * time.Millisecond)
		return fmt.tprintf("%d.%ds", seconds, tenths)
	}
	if seconds < 3600 {
		return fmt.tprintf("%dm%02ds", seconds / 60, seconds % 60)
	}
	return fmt.tprintf("%dh%02dm", seconds / 3600, (seconds % 3600) / 60)
}

// 每轮结束的一行纯文本：首轮顺带报出新 session，其余轮只报耗时。
// 不加符号，方便复制和在记录里阅读。取消的轮次把原因并进同一行，
// 避免「取消 / turn ended / 退出码 / stderr」重复说同一件事。
turn_summary_line :: proc(
	new_session_id: string,
	elapsed: time.Duration,
	cancelled: bool,
) -> string {
	base := fmt.tprintf("turn %s", format_elapsed(elapsed))
	if len(new_session_id) > 0 {
		base = fmt.tprintf("using session: %s (%s)", new_session_id, format_elapsed(elapsed))
	}
	if cancelled {
		return fmt.tprintf("%s · cancelled", base)
	}
	return base
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
	// cancelled 由 cancel 事件（重放）或结束行（实时）表达，这里不重复。
	if len(stop_reason) == 0 ||
	   stop_reason == protocol.STOP_REASON_STOP ||
	   stop_reason == protocol.STOP_REASON_TOOL_USE ||
	   stop_reason == protocol.STOP_REASON_HANDOFF ||
	   stop_reason == protocol.STOP_REASON_CANCELLED {
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
				// glow 模式只收集最终文本，原始 delta 不直接上屏。
				if !r.glow.enabled {
					assistant_text(r, text)
				}
				r.message_had_text_delta = true
			}
			// reasoning 在 phase 1 不展示。
		}
	case protocol.EVENT_MESSAGE_END:
		text := message_text(r, ev)
		remember_assistant_text(r, text)
		if r.glow.enabled {
			assistant_markdown(r, text)
		} else if mode == .History || !r.message_had_text_delta {
			for part in client.message_texts(ev, r.project) {
				assistant_text(r, part)
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
		// 实时取消交给结束行统一收尾，不再单独占一行。历史重放没有结束行，
		// 不打个标记就看不出这一轮是被取消的。
		if mode == .History {
			note(r, fmt.tprintf("cancelled [%s]", ev.scope))
		} else {
			r.cancelled = true
		}
	case protocol.EVENT_TURN_END:
		render_turn_end(r, ev.stop_reason)
	case:
		// session_start / session_end / turn_start / step_start 等不直接展示。
	}
}
