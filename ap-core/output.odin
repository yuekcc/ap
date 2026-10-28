package apcore

import "engine"
import "platform"
import "protocol"
import "core:encoding/json"
import "core:time"

Output_State :: struct {
	format: Output_Format,
}

output_write_json :: proc(obj: json.Object) {
	data, err := platform.json_marshal_utf8(obj)
	if err != nil {
		return
	}
	write_stdout(data)
	write_stdout(transmute([]byte)string("\n"))
}

now_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1_000_000
}

output_transcript :: proc(user: rawptr, event: protocol.Transcript_Event) {
	out := (^Output_State)(user)
	if out.format != .Stream_Json {
		return
	}
	write_stdout(transmute([]byte)event.line)
	write_stdout(transmute([]byte)string("\n"))
}

// 所有增量事件共享 {"type":"message_update","ts":...,"delta":{}} 信封。
// delta 必须完整构造后再赋给 obj：Odin 的 map header 按值复制，
// 从 obj["delta"] 取出再原地写入不会反映到 obj 上。
make_message_update :: proc() -> json.Object {
	obj := make(json.Object)
	obj["type"] = json.String("message_update")
	obj["ts"] = json.Integer(now_ms())
	return obj
}

make_text_delta_event :: proc(message_id, text: string) -> json.Object {
	obj := make_message_update()
	obj["message_id"] = json.String(message_id)
	delta := make(json.Object)
	delta["text"] = json.String(text)
	obj["delta"] = delta
	return obj
}

make_reasoning_delta_event :: proc(message_id, text: string) -> json.Object {
	obj := make_message_update()
	obj["message_id"] = json.String(message_id)
	delta := make(json.Object)
	delta["reasoning"] = json.String(text)
	obj["delta"] = delta
	return obj
}

make_tool_delta_event :: proc(index: int, id, name, args_delta: string) -> json.Object {
	obj := make_message_update()
	call := make(json.Object)
	call["index"] = json.Integer(index)
	if len(id) > 0 {
		call["id"] = json.String(id)
	}
	if len(name) > 0 {
		call["name"] = json.String(name)
	}
	call["args_delta"] = json.String(args_delta)
	delta := make(json.Object)
	delta["tool_call"] = call
	obj["delta"] = delta
	return obj
}

output_text_delta :: proc(user: rawptr, message_id, text: string) {
	out := (^Output_State)(user)
	if out.format != .Stream_Json {
		return
	}
	output_write_json(make_text_delta_event(message_id, text))
}

output_reasoning_delta :: proc(user: rawptr, message_id, text: string) {
	out := (^Output_State)(user)
	if out.format != .Stream_Json {
		return
	}
	output_write_json(make_reasoning_delta_event(message_id, text))
}

output_tool_delta :: proc(user: rawptr, index: int, id, name, args_delta: string) {
	out := (^Output_State)(user)
	if out.format != .Stream_Json {
		return
	}
	output_write_json(make_tool_delta_event(index, id, name, args_delta))
}

output_tool_update :: proc(user: rawptr, tool_call_id, chunk: string) {
	out := (^Output_State)(user)
	if out.format == .Stream_Json {
		obj := make(json.Object)
		obj["type"] = json.String("tool_execution_update")
		obj["ts"] = json.Integer(now_ms())
		obj["tool_call_id"] = json.String(tool_call_id)
		obj["chunk"] = json.String(platform.sanitize_utf8(transmute([]byte)chunk))
		output_write_json(obj)
	} else {
		write_stderr(transmute([]byte)chunk)
	}
}

output_progress :: proc(user: rawptr, line: string) {
	write_stderr(transmute([]byte)line)
	write_stderr(transmute([]byte)string("\n"))
}

make_loop_emitter :: proc(out: ^Output_State) -> engine.Emitter {
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

output_final :: proc(out: ^Output_State, session_id: string, result: engine.Turn_Result) {
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
