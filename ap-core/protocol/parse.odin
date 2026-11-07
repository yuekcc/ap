package protocol

import "core:encoding/json"
import "core:strings"

// 宽松解析一行 stream-json：非法 JSON 或缺 type 都返回 false。
//
// 分配契约：返回结构里的字符串与 json.Value 都从 context.temp_allocator
// 分配，只在下一次 temp 重置前有效。调用方必须在处理完一行后
// free_all(context.temp_allocator)，需要保留的字段（如 session_id）自己
// clone 到长期分配器。漏掉重置会让长 turn 的内存无界增长。
parse_stream_event :: proc(line: string) -> (Stream_Event, bool) {
	if len(strings.trim_space(line)) == 0 {
		return {}, false
	}
	ev: Stream_Event
	if err := json.unmarshal(transmute([]byte)line, &ev, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil {
		return {}, false
	}
	if len(ev.type) == 0 {
		return {}, false
	}
	return ev, true
}

json_string_field :: proc(obj: json.Object, key: string) -> (string, bool) {
	value, ok := obj[key]
	if !ok {
		return "", false
	}
	text, is_string := value.(json.String)
	if !is_string {
		return "", false
	}
	return string(text), true
}

content_string :: proc(value: json.Value) -> (string, bool) {
	if s, ok := value.(json.String); ok {
		return string(s), true
	}
	return "", false
}
