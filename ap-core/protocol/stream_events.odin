package protocol

import "core:encoding/json"
import "core:time"

// stream-json 增量事件的构造。写侧（ap-cli）与读侧（Stream_Event）共用同一
// 组键名，避免两处各自手写字面量后无声漂移。

now_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1_000_000
}

// 所有增量事件共享 {"type":"message_update","ts":...,"delta":{}} 信封。
// delta 必须完整构造后再赋给 obj：Odin 的 map header 按值复制，
// 从 obj["delta"] 取出再原地写入不会反映到 obj 上。
make_message_update :: proc() -> json.Object {
	obj := make(json.Object)
	obj["type"] = json.String(EVENT_MESSAGE_UPDATE)
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

// chunk 必须已经过 UTF-8 清洗；清洗依赖 platform，留在调用方。
make_tool_update_event :: proc(tool_call_id, chunk: string) -> json.Object {
	obj := make(json.Object)
	obj["type"] = json.String(EVENT_TOOL_EXECUTION_UPDATE)
	obj["ts"] = json.Integer(now_ms())
	obj["tool_call_id"] = json.String(tool_call_id)
	obj["chunk"] = json.String(chunk)
	return obj
}
