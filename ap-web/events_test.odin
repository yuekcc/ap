package main

import "core:testing"

@(test)
test_parse_stream_events :: proc(t: ^testing.T) {
	ev, ok := parse_event_line(`{"type":"message_update","message_id":"m1","delta":{"text":"hi"}}`)
	testing.expect(t, ok)
	testing.expect_value(t, ev.type, "message_update")
	testing.expect_value(t, ev.message_id, "m1")
	text, has_text := ev.delta.text.?
	testing.expect(t, has_text)
	testing.expect_value(t, text, "hi")

	start, ok2 := parse_event_line(`{"type":"session_start","session_id":"ses_x","content":"sys","parent_session_id":null}`)
	testing.expect(t, ok2)
	testing.expect_value(t, start.session_id, "ses_x")
	_, has_parent := start.parent_session_id.?
	testing.expect(t, !has_parent)
}

@(test)
test_parse_event_line_rejects_blank_and_typeless :: proc(t: ^testing.T) {
	_, blank := parse_event_line("   ")
	testing.expect(t, !blank)

	_, no_type := parse_event_line(`{"session_id":"ses_x"}`)
	testing.expect(t, !no_type)
}
