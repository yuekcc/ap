package protocol

import "core:encoding/json"
import "core:strings"

// 宽松解析一行 stream-json：非法 JSON 或缺 type 都返回 false。
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
