package client

import protocol "../protocol"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_format_tool_args :: proc(t: ^testing.T) {
	value: json.Value
	args_json := `{"file_path":"ap/main.odin","limit":20,"ok":true}`
	err := json.unmarshal(transmute([]byte)args_json, &value)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, format_args(value, nil), "file_path=ap/main.odin, limit=20, ok=true")
}

@(test)
test_preview_content_truncates :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 10 {
		fmt.sbprintf(&b, "line %d\n", i)
	}
	out, truncated := preview_content(strings.to_string(b))
	testing.expect(t, !truncated)
	testing.expect(t, strings.contains(out, "line 9"))

	_, truncated_many_lines := preview_content(strings.repeat("x\n", 300, context.temp_allocator))
	testing.expect(t, truncated_many_lines)

	long := strings.repeat("y", 30000, context.temp_allocator)
	out_long, truncated_bytes := preview_content(long)
	testing.expect(t, truncated_bytes)
	testing.expect(t, len(out_long) <= 20000)
}

@(test)
test_message_texts_resolves_inline_and_preview :: proc(t: ^testing.T) {
	ev, ok := protocol.parse_stream_event(`{"type":"message_end","content":[{"type":"text","text":"a"},{"type":"text","text_preview":"b"}]}`)
	testing.expect(t, ok)
	texts := message_texts(ev, nil)
	testing.expect_value(t, len(texts), 2)
	testing.expect_value(t, texts[0], "a")
	testing.expect_value(t, texts[1], "b")
}
