package tui

import protocol "../ap/protocol"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

Usage :: protocol.Usage
Tool_Call_Delta :: protocol.Tool_Call_Delta
Delta :: protocol.Delta

// stream-json 的 transcript/stream 事件在客户端里共用一个宽松结构。
Event :: protocol.Stream_Event

parse_event_line :: protocol.parse_stream_event
json_string_field :: protocol.json_string_field
content_string :: protocol.content_string

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
