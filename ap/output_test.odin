package ap

import "platform"
import "core:encoding/json"
import "core:strings"
import "core:testing"

@(test)
test_text_delta_event_has_nested_delta :: proc(t: ^testing.T) {
	obj := make_text_delta_event("msg-1", "hi")
	testing.expect_value(t, obj["type"].(json.String), json.String("message_update"))
	testing.expect_value(t, obj["message_id"].(json.String), json.String("msg-1"))
	delta := obj["delta"].(json.Object)
	testing.expect_value(t, delta["text"].(json.String), json.String("hi"))

	data, err := platform.json_marshal_utf8(obj)
	testing.expect_value(t, err, nil)
	testing.expect(t, strings.contains(string(data), `"delta":{"text":"hi"}`))
}

@(test)
test_reasoning_delta_event_has_nested_delta :: proc(t: ^testing.T) {
	obj := make_reasoning_delta_event("msg-1", "thinking")
	delta := obj["delta"].(json.Object)
	testing.expect_value(t, delta["reasoning"].(json.String), json.String("thinking"))
}

@(test)
test_tool_delta_event_has_nested_delta :: proc(t: ^testing.T) {
	obj := make_tool_delta_event(2, "", "", `{"file`)
	delta := obj["delta"].(json.Object)
	call := delta["tool_call"].(json.Object)
	testing.expect_value(t, call["index"].(json.Integer), json.Integer(2))
	testing.expect_value(t, call["args_delta"].(json.String), json.String(`{"file`))
	_, has_id := call["id"]
	_, has_name := call["name"]
	testing.expect(t, !has_id)
	testing.expect(t, !has_name)

	obj_with_name := make_tool_delta_event(0, "call_1", "read_file", "")
	call_with_name := obj_with_name["delta"].(json.Object)["tool_call"].(json.Object)
	testing.expect_value(t, call_with_name["id"].(json.String), json.String("call_1"))
	testing.expect_value(t, call_with_name["name"].(json.String), json.String("read_file"))
}
