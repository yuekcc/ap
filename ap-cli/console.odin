package apcli

import platform "../ap-core/platform"
import protocol "../ap-core/protocol"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// text 输出格式的 stderr 渲染器：视觉语言与 ap-tui 的实时渲染保持一致。
//
// stdout 的契约不变：turn 结束后一次性输出干净结果。这里只处理人类可读的
// 进度——工具调用行、缩进的工具输出、✓/✗ 状态、错误与 turn 结束提示。
// 换行只发生在完整行之间，所以 `ap -p ... 2>&1` 也能读。
//
// 与 ap-tui 的差异：
//   - assistant 文本不在这里流式显示（答案最后统一走 stdout）
//   - json / stream-json 格式不使用本渲染器，stderr 仍是 markdown 进度行
//
// 展示规则（参数格式化、结果预览截断）与 ap-core/client/history.odin 一致；
// ap-cli 不允许 import ap-core/client，因此保留一份等价实现。

CONSOLE_RESET  :: "\x1b[0m"
CONSOLE_BOLD   :: "\x1b[1m"
CONSOLE_DIM    :: "\x1b[2m"
CONSOLE_RED    :: "\x1b[31m"
CONSOLE_GREEN  :: "\x1b[32m"
CONSOLE_YELLOW :: "\x1b[33m"
CONSOLE_CYAN   :: "\x1b[36m"

// 工具结果预览窗口：超过就换成「完整内容在 transcript」的提示。
CONSOLE_PREVIEW_MAX_LINES :: 200
CONSOLE_PREVIEW_MAX_BYTES :: 20000
// 工具参数只显示一行摘要。
CONSOLE_ARGS_MAX_BYTES :: 240
// loop 的重试已经在 error 事件里报过，进度行不再重复。
CONSOLE_RETRY_PREFIX :: "[retry] "

Console :: struct {
	out:             ^os.File,
	project:         platform.Project,
	color:           bool,
	at_line_start:   bool,
	tool_active:     bool,
	tool_had_update: bool,
}

console_init :: proc(c: ^Console, out: ^os.File, project: platform.Project, color: bool) {
	c.out = out
	c.project = project
	c.color = color
	c.at_line_start = true
	c.tool_active = false
	c.tool_had_update = false
}

console_write :: proc(c: ^Console, text: string) {
	if c.out == nil || len(text) == 0 {
		return
	}
	if !platform.write_all(c.out, transmute([]byte)text) {
		return
	}
	c.at_line_start = text[len(text) - 1] == '\n'
}

console_escape :: proc(c: ^Console, code: string) {
	if !c.color || len(code) == 0 {
		return
	}
	console_write(c, code)
}

console_paint :: proc(c: ^Console, code, text: string) {
	if len(text) == 0 {
		return
	}
	console_escape(c, code)
	console_write(c, text)
	console_escape(c, CONSOLE_RESET)
}

console_ensure_line_start :: proc(c: ^Console) {
	if c.out != nil && !c.at_line_start {
		console_write(c, "\n")
	}
}

// 缩进两格、暗色的原始块；跨 chunk 维护行首状态，避免缩进落在行中。
console_write_indented_dim :: proc(c: ^Console, text: string) {
	if c.out == nil || len(text) == 0 {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&b)

	at_start := c.at_line_start
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
	console_paint(c, CONSOLE_DIM, strings.to_string(b))
	c.at_line_start = at_start
}

console_tool_start :: proc(c: ^Console, name, args: string) {
	if c.out == nil {
		return
	}
	console_ensure_line_start(c)
	console_paint(c, CONSOLE_BOLD + CONSOLE_YELLOW, "◆ ")
	console_write(c, name)
	if len(args) > 0 {
		console_write(c, " ")
		console_paint(c, CONSOLE_DIM, fmt.tprintf("(%s)", args))
	}
	console_ensure_line_start(c)
	c.tool_active = true
	c.tool_had_update = false
}

console_tool_update :: proc(c: ^Console, chunk: string) {
	if !c.tool_active || len(chunk) == 0 {
		return
	}
	c.tool_had_update = true
	console_write_indented_dim(c, chunk)
}

console_tool_end :: proc(
	c: ^Console,
	ok: bool,
	content: string,
	has_content: bool,
	err: string,
	duration_ms: Maybe(int),
	exit_code: Maybe(int),
) {
	if c.out == nil || !c.tool_active {
		return
	}

	// 没有增量输出时补一个结果预览，实时 bash 流就不再重复整份输出。
	if ok && !c.tool_had_update && has_content && len(content) > 0 {
		preview, truncated := console_preview_content(content)
		console_write_indented_dim(c, preview)
		if truncated {
			console_write_indented_dim(c, "… (truncated; full content is in the transcript)\n")
		}
	}

	console_ensure_line_start(c)
	console_paint(c, CONSOLE_DIM, "  ")
	if ok {
		console_paint(c, CONSOLE_GREEN, "✓")
	} else {
		console_paint(c, CONSOLE_RED, "✗")
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
		console_paint(c, CONSOLE_DIM, strings.to_string(meta))
	}
	if !ok && len(err) > 0 {
		console_paint(c, CONSOLE_RED, fmt.tprintf(" %s", err))
	}
	console_ensure_line_start(c)
	c.tool_active = false
}

console_error :: proc(c: ^Console, scope, message: string, retryable: bool) {
	if c.out == nil {
		return
	}
	console_ensure_line_start(c)
	color := CONSOLE_YELLOW if retryable else CONSOLE_RED
	if retryable {
		console_paint(c, CONSOLE_YELLOW, "… ")
	} else {
		console_paint(c, CONSOLE_BOLD + CONSOLE_RED, "! ")
	}
	if len(scope) > 0 {
		console_paint(c, color, fmt.tprintf("[%s] ", scope))
	}
	console_paint(c, color, message)
	console_ensure_line_start(c)
}

console_note :: proc(c: ^Console, text: string) {
	if c.out == nil || len(text) == 0 {
		return
	}
	console_ensure_line_start(c)
	console_write_indented_dim(c, fmt.tprintf("%s\n", text))
	console_ensure_line_start(c)
}

console_turn_end :: proc(c: ^Console, stop_reason: string) {
	if c.out == nil {
		return
	}
	if len(stop_reason) == 0 || stop_reason == "stop" || stop_reason == "tool_use" {
		return
	}
	console_ensure_line_start(c)
	console_write(c, "\n")
	console_paint(c, CONSOLE_YELLOW, fmt.tprintf("turn ended: %s", stop_reason))
	console_ensure_line_start(c)
}

// 进度回调：text 模式下 .Line 是子代理输出与重试提示，.Block 已由事件渲染替代。
console_progress_line :: proc(c: ^Console, line: string) {
	if len(line) == 0 {
		return
	}
	if strings.has_prefix(line, CONSOLE_RETRY_PREFIX) {
		// 重试已经由 error 事件以 `…` 报过，避免同一件事出现两遍。
		return
	}
	console_note(c, line)
}

// transcript 事件负责工具行、错误与 turn 结束；其余事件在 text 模式下不展示。
console_transcript_line :: proc(c: ^Console, line: string) {
	ev, ok := protocol.parse_stream_event(line)
	if !ok {
		return
	}
	switch ev.type {
	case "tool_execution_start":
		console_tool_start(c, ev.name, console_args_text(c, ev))
	case "tool_execution_end":
		content, has_content := console_result_text(c, ev)
		err := ""
		if value, has_err := ev.error.?; has_err {
			err = value
		}
		console_tool_end(c, ev.ok, content, has_content, err, ev.duration_ms, ev.exit_code)
	case "error":
		console_error(c, ev.scope, ev.message, ev.retryable)
	case "cancel":
		console_note(c, fmt.tprintf("cancelled [%s]", ev.scope))
	case "turn_end":
		console_turn_end(c, ev.stop_reason)
	case:
		// session_start / step_start / message_* / user_message 不直接展示。
	}
}

console_finish :: proc(c: ^Console) {
	console_ensure_line_start(c)
	c.tool_active = false
}

// ---- 展示辅助：与 ap-core/client/history.odin 同规则 ----

console_truncate_utf8 :: proc(text: string, max_bytes: int) -> (string, bool) {
	if max_bytes <= 0 || len(text) <= max_bytes {
		return text, false
	}
	n := max_bytes
	for n > 0 && (text[n] & 0xc0) == 0x80 {
		n -= 1
	}
	return text[:n], true
}

console_truncate_lines :: proc(text: string, max_lines: int) -> (string, bool) {
	if max_lines <= 0 {
		return text, false
	}
	line := 1
	for i in 0 ..< len(text) {
		if text[i] == '\n' {
			line += 1
			if line > max_lines {
				return text[:i + 1], true
			}
		}
	}
	return text, false
}

console_preview_content :: proc(text: string) -> (string, bool) {
	out, lines_truncated := console_truncate_lines(text, CONSOLE_PREVIEW_MAX_LINES)
	trimmed, bytes_truncated := console_truncate_utf8(out, CONSOLE_PREVIEW_MAX_BYTES)
	return trimmed, lines_truncated || bytes_truncated
}

console_single_line :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&b)
	blank := false
	for r in text {
		if r == '\n' || r == '\r' || r == '\t' {
			if !blank {
				strings.write_byte(&b, ' ')
				blank = true
			}
			continue
		}
		strings.write_rune(&b, r)
		blank = false
	}
	return strings.trim_space(strings.to_string(b))
}

console_format_args :: proc(value: json.Value) -> string {
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return ""
	}
	keys := make([dynamic]string, 0, len(obj), context.temp_allocator)
	for key in obj {
		append(&keys, key)
	}
	// 稳定输出，便于阅读与测试。
	for i in 1 ..< len(keys) {
		j := i
		for j > 0 && keys[j] < keys[j - 1] {
			keys[j], keys[j - 1] = keys[j - 1], keys[j]
			j -= 1
		}
	}

	b := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&b)
	for key, i in keys {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, key)
		strings.write_byte(&b, '=')
		switch v in obj[key] {
		case json.String:
			strings.write_string(&b, string(v))
		case json.Integer:
			fmt.sbprintf(&b, "%d", int(v))
		case json.Boolean:
			strings.write_string(&b, "true" if bool(v) else "false")
		case json.Null:
			strings.write_string(&b, "null")
		case json.Array, json.Float, json.Object:
			fmt.sbprintf(&b, "%v", v)
		}
	}
	out, _ := console_truncate_utf8(strings.to_string(b), CONSOLE_ARGS_MAX_BYTES)
	return out
}

console_args_text :: proc(c: ^Console, ev: protocol.Stream_Event) -> string {
	if ref, has_ref := ev.args_ref.?; has_ref {
		if data, err := platform.blob_read(c.project, ref, context.temp_allocator); platform.is_ok(err) {
			out, _ := console_truncate_utf8(string(data), CONSOLE_ARGS_MAX_BYTES)
			return console_single_line(out)
		}
	}
	if preview, has_preview := ev.args_preview.?; has_preview {
		out, _ := console_truncate_utf8(preview, CONSOLE_ARGS_MAX_BYTES)
		return console_single_line(out)
	}
	return console_single_line(console_format_args(ev.args))
}

console_result_text :: proc(c: ^Console, ev: protocol.Stream_Event) -> (string, bool) {
	if ref, has_ref := ev.content_ref.?; has_ref {
		if data, err := platform.blob_read(c.project, ref, context.temp_allocator); platform.is_ok(err) {
			return string(data), true
		}
	}
	if text, has_text := protocol.content_string(ev.content); has_text {
		return text, true
	}
	if preview, has_preview := ev.content_preview.?; has_preview {
		return preview, true
	}
	return "", false
}

// 与 ap-tui 一致：stderr 不是 TTY 或设置了 NO_COLOR 时关闭 ANSI 颜色。
console_color_enabled :: proc() -> bool {
	if !platform.is_terminal_stderr() {
		return false
	}
	buf: [128]u8
	if no_color, err := os.lookup_env(buf[:], "NO_COLOR"); err == nil {
		return len(no_color) == 0
	}
	return true
}
