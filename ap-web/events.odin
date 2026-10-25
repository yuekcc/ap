package main

import "../internal"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

Usage :: internal.Usage

Tool_Call_Delta :: struct {
	index:      int    `json:"index"`,
	id:         string `json:"id"`,
	name:       string `json:"name"`,
	args_delta: string `json:"args_delta"`,
}

Delta :: struct {
	text:      Maybe(string)          `json:"text"`,
	reasoning: Maybe(string)          `json:"reasoning"`,
	tool_call: Maybe(Tool_Call_Delta) `json:"tool_call"`,
}

// stream-json 的 transcript/stream 事件在本程序里共用一个宽松结构。
// content 在不同事件里可能是 string、array 或 null，所以用 json.Value 承载。
Event :: struct {
	using _: internal.Event_Header,

	session_id:          string         `json:"session_id"`,
	parent_session_id:   Maybe(string)  `json:"parent_session_id"`,
	parent_tool_call_id: Maybe(string)  `json:"parent_tool_call_id"`,

	role:       string `json:"role"`,
	message_id: string `json:"message_id"`,
	model:      string `json:"model"`,
	delta:      Delta  `json:"delta"`,

	content:     json.Value    `json:"content"`,
	stop_reason: string        `json:"stop_reason"`,
	usage:       Usage         `json:"usage"`,
	reasoning:   Maybe(string) `json:"reasoning"`,

	tool_call_id: string       `json:"tool_call_id"`,
	name:         string       `json:"name"`,
	args:         json.Value   `json:"args"`,
	args_ref:     Maybe(string) `json:"args_ref"`,
	args_bytes:   Maybe(int)    `json:"args_bytes"`,
	args_preview: Maybe(string) `json:"args_preview"`,

	ok:              bool          `json:"ok"`,
	content_ref:     Maybe(string) `json:"content_ref"`,
	content_bytes:   Maybe(int)    `json:"content_bytes"`,
	content_preview: Maybe(string) `json:"content_preview"`,
	error:           Maybe(string) `json:"error"`,
	duration_ms:     Maybe(int)    `json:"duration_ms"`,
	exit_code:       Maybe(int)    `json:"exit_code"`,

	scope:     string        `json:"scope"`,
	kind:      Maybe(string) `json:"kind"`,
	message:   string        `json:"message"`,
	retryable: bool          `json:"retryable"`,
	attempt:   int           `json:"attempt"`,

	target_id: Maybe(string) `json:"target_id"`,
	reason:    string        `json:"reason"`,
	chunk:     string        `json:"chunk"`,

	turn: int `json:"turn"`,
	step: int `json:"step"`,
}

parse_event_line :: proc(line: string) -> (Event, bool) {
	if len(strings.trim_space(line)) == 0 {
		return {}, false
	}
	ev: Event
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

event_text_block :: proc(block: json.Object, project: ^Project) -> (string, bool) {
	if typ, ok := json_string_field(block, "type"); !ok || typ != "text" {
		return "", false
	}
	if text, ok := json_string_field(block, "text"); ok {
		return text, true
	}
	if ref, ok := json_string_field(block, "text_ref"); ok && project != nil {
		if data, err := blob_read(project^, ref, context.temp_allocator); is_ok(err) {
			return string(data), true
		}
	}
	if preview, ok := json_string_field(block, "text_preview"); ok {
		return preview, true
	}
	return "", false
}

message_texts :: proc(ev: Event, project: ^Project) -> []string {
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	blocks, ok := ev.content.(json.Array)
	if !ok {
		return out[:]
	}
	for block in blocks {
		obj, is_obj := block.(json.Object)
		if !is_obj {
			continue
		}
		if text, is_text := event_text_block(obj, project); is_text {
			append(&out, text)
		}
	}
	return out[:]
}

user_message_text :: proc(ev: Event) -> string {
	text, _ := content_string(ev.content)
	return text
}

truncate_utf8 :: proc(text: string, max_bytes: int) -> (string, bool) {
	if max_bytes <= 0 || len(text) <= max_bytes {
		return text, false
	}
	n := max_bytes
	for n > 0 && (text[n] & 0xc0) == 0x80 {
		n -= 1
	}
	return text[:n], true
}

truncate_lines :: proc(text: string, max_lines: int) -> (string, bool) {
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

// 工具结果只展示一个有限的窗口，完整内容仍在 transcript / blob 里。
preview_content :: proc(text: string) -> (string, bool) {
	MAX_LINES :: 200
	MAX_BYTES :: 20000
	out, lines_truncated := truncate_lines(text, MAX_LINES)
	out2, bytes_truncated := truncate_utf8(out, MAX_BYTES)
	return out2, lines_truncated || bytes_truncated
}

single_line :: proc(text: string) -> string {
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

format_args :: proc(value: json.Value, project: ^Project) -> string {
	obj, ok := value.(json.Object)
	if !ok {
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
	out, _ := truncate_utf8(strings.to_string(b), 240)
	return out
}

// 工具参数超过阈值时会落 blob。这里只需要展示用，优先 inline args，其次 blob。
tool_args_text :: proc(ev: Event, project: ^Project) -> string {
	if ref, ok := ev.args_ref.?; ok && project != nil {
		if data, err := blob_read(project^, ref, context.temp_allocator); is_ok(err) {
			out, _ := truncate_utf8(string(data), 240)
			return single_line(out)
		}
	}
	if preview, ok := ev.args_preview.?; ok {
		out, _ := truncate_utf8(preview, 240)
		return single_line(out)
	}
	return single_line(format_args(ev.args, project))
}

tool_result_text :: proc(ev: Event, project: ^Project) -> (string, bool) {
	if ref, ok := ev.content_ref.?; ok && project != nil {
		if data, err := blob_read(project^, ref, context.temp_allocator); is_ok(err) {
			return string(data), true
		}
	}
	if text, ok := content_string(ev.content); ok {
		return text, true
	}
	if preview, ok := ev.content_preview.?; ok {
		return preview, true
	}
	return "", false
}
