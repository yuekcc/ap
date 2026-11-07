package apcli

import apcore "../ap-core"
import platform "../ap-core/platform"
import protocol "../ap-core/protocol"
import "core:encoding/json"

Output_State :: struct {
	format: Output_Format,
	// stderr 的 markdown 排版状态：`json` / `stream-json` 使用，块与块之间恰好一个空行。
	stderr_wrote:     bool, // 已向 stderr 写过内容
	stderr_line_open: bool, // 上一行还没换行
	stderr_spaced:    bool, // 上一个块已用空行收尾
	stderr_in_block:  bool, // 正处在工具输出的原始块中
	// text 格式的 stderr 交给 ap-tui 风格的渲染器。
	console:          Console,
}

output_write_json :: proc(obj: json.Object) {
	data, err := platform.json_marshal_utf8(obj)
	if err != nil {
		return
	}
	write_stdout(data)
	write_stdout(transmute([]byte)string("\n"))
}

output_transcript :: proc(user: rawptr, event: protocol.Transcript_Event) {
	out := (^Output_State)(user)
	switch out.format {
	case .Stream_Json:
		write_stdout(transmute([]byte)event.line)
		write_stdout(transmute([]byte)string("\n"))
	case .Text:
		// text 只把人类可读的进度写到 stderr；结果仍然统计到 turn 后一次性输出。
		console_transcript_line(&out.console, event.line)
	case .Json:
	}
}

output_text_delta :: proc(user: rawptr, message_id, text: string) {
	out := (^Output_State)(user)
	if out.format != .Stream_Json {
		return
	}
	output_write_json(protocol.make_text_delta_event(message_id, text))
}

output_reasoning_delta :: proc(user: rawptr, message_id, text: string) {
	out := (^Output_State)(user)
	if out.format != .Stream_Json {
		return
	}
	output_write_json(protocol.make_reasoning_delta_event(message_id, text))
}

output_tool_delta :: proc(user: rawptr, index: int, id, name, args_delta: string) {
	out := (^Output_State)(user)
	if out.format != .Stream_Json {
		return
	}
	output_write_json(protocol.make_tool_delta_event(index, id, name, args_delta))
}

// stderr 按 markdown 排版：每个块前留一个空行，必要时先给上一行收尾。
stderr_begin_block :: proc(out: ^Output_State) {
	if !out.stderr_wrote {
		return
	}
	if out.stderr_line_open {
		stderr_write_string("\n")
		out.stderr_line_open = false
	}
	if !out.stderr_spaced {
		stderr_write_string("\n")
	}
	out.stderr_spaced = false
}

// 开始一个原始块（工具输出等）：块首留空行，块内不再干预。
stderr_begin_raw :: proc(out: ^Output_State) {
	if out.stderr_in_block {
		return
	}
	stderr_begin_block(out)
	out.stderr_in_block = true
}

// 独立块：标题行、状态行，单独成段并空行收尾。
output_block :: proc(out: ^Output_State, line: string) {
	if len(line) == 0 {
		return
	}
	stderr_begin_block(out)
	stderr_write_string(line)
	stderr_write_string("\n")
	stderr_write_string("\n")
	out.stderr_wrote = true
	out.stderr_line_open = false
	out.stderr_spaced = true
	out.stderr_in_block = false
}

// 流式内容：块内原样透传，不做换行干预。
output_raw :: proc(out: ^Output_State, chunk: string) {
	if len(chunk) == 0 {
		return
	}
	stderr_begin_raw(out)
	stderr_write_string(chunk)
	out.stderr_wrote = true
	out.stderr_line_open = chunk[len(chunk) - 1] != '\n'
	out.stderr_spaced = false
}

// 行式内容：子代理输出等逐行文本，同一块内连续追加。
output_line :: proc(out: ^Output_State, line: string) {
	if len(line) == 0 {
		return
	}
	stderr_begin_raw(out)
	if out.stderr_line_open {
		stderr_write_string("\n")
	}
	stderr_write_string(line)
	stderr_write_string("\n")
	out.stderr_wrote = true
	out.stderr_line_open = false
	out.stderr_spaced = false
}

output_tool_update :: proc(user: rawptr, tool_call_id, chunk: string) {
	out := (^Output_State)(user)
	switch out.format {
	case .Stream_Json:
		output_write_json(
			protocol.make_tool_update_event(tool_call_id, platform.sanitize_utf8(transmute([]byte)chunk)),
		)
	case .Text:
		console_tool_update(&out.console, chunk)
	case .Json:
	}
}

output_progress :: proc(user: rawptr, style: apcore.Progress_Style, line: string) {
	out := (^Output_State)(user)
	if out.format == .Text {
		// text 已经由 transcript 事件渲染工具行与错误；这里只剩子代理输出等行式内容。
		if style == .Line {
			console_progress_line(&out.console, line)
		}
		return
	}
	switch style {
	case .Block:
		output_block(out, line)
	case .Line:
		output_line(out, line)
	}
}

make_loop_emitter :: proc(out: ^Output_State) -> apcore.Emitter {
	return {
		user = out,
		on_transcript = output_transcript,
		on_text_delta = output_text_delta,
		on_reasoning_delta = output_reasoning_delta,
		on_tool_delta = output_tool_delta,
		on_tool_update = output_tool_update,
		on_progress = output_progress,
	}
}

Final_Json :: struct {
	session_id:  string,
	result:      string,
	stop_reason: Maybe(string),
	num_steps:   int,
	usage:       protocol.Usage,
}

output_final :: proc(out: ^Output_State, session_id: string, result: apcore.Turn_Result) {
	switch out.format {
	case .Text:
		if len(result.result_text) == 0 {
			return
		}
		write_stdout(transmute([]byte)result.result_text)
		if result.result_text[len(result.result_text) - 1] != '\n' {
			write_stdout(transmute([]byte)string("\n"))
		}
	case .Json:
		var_stop: Maybe(string)
		if len(result.stop_reason) > 0 {
			var_stop = result.stop_reason
		}
		payload := Final_Json {
			session_id = session_id,
			result = result.result_text,
			stop_reason = var_stop,
			num_steps = result.num_steps,
			usage = result.usage,
		}
		data, err := platform.json_marshal_utf8(payload)
		if err != nil {
			return
		}
		write_stdout(data)
		write_stdout(transmute([]byte)string("\n"))
	case .Stream_Json:
	}
}
