package protocol

import "core:testing"

@(test)
test_parse_stream_events :: proc(t: ^testing.T) {
	ev, ok := parse_stream_event(`{"type":"message_update","message_id":"m1","delta":{"text":"hi"}}`)
	testing.expect(t, ok)
	testing.expect_value(t, ev.type, "message_update")
	testing.expect_value(t, ev.message_id, "m1")
	text, has_text := ev.delta.text.?
	testing.expect(t, has_text)
	testing.expect_value(t, text, "hi")

	start, ok2 := parse_stream_event(`{"type":"session_start","session_id":"ses_x","content":"sys","parent_session_id":null}`)
	testing.expect(t, ok2)
	testing.expect_value(t, start.session_id, "ses_x")
	_, has_parent := start.parent_session_id.?
	testing.expect(t, !has_parent)
}

@(test)
test_parse_stream_event_rejects_blank_and_typeless :: proc(t: ^testing.T) {
	_, blank := parse_stream_event("   ")
	testing.expect(t, !blank)

	_, no_type := parse_stream_event(`{"session_id":"ses_x"}`)
	testing.expect(t, !no_type)
}

@(test)
test_usage_add_and_has_any :: proc(t: ^testing.T) {
	a := Usage{input_tokens = 3, total_tokens = 3}
	b := Usage{output_tokens = 4, total_tokens = 4}
	sum := usage_add(a, b)
	testing.expect_value(t, sum.input_tokens.?, 3)
	testing.expect_value(t, sum.output_tokens.?, 4)
	testing.expect_value(t, sum.total_tokens.?, 7)
	_, no_cached := sum.cached_tokens.?
	testing.expect(t, !no_cached)
	testing.expect(t, usage_has_any(sum))
	testing.expect(t, !usage_has_any(Usage{}))
}
