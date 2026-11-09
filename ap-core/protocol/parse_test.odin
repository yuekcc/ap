package protocol

import "core:encoding/json"
import "core:strings"
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

// handoff 是新增的持久事件类型。没登记进 event_type_known 的话，恢复时会被
// 当未知事件丢掉；没登记进 event_type_canonical 的话，Event.type 会指向
// 解析缓冲，调用方释放后就成了悬垂指针。
@(test)
test_handoff_event_is_known_and_canonical :: proc(t: ^testing.T) {
	testing.expect(t, event_type_known(EVENT_HANDOFF))
	testing.expect_value(t, event_type_canonical(EVENT_HANDOFF), EVENT_HANDOFF)
	testing.expect_value(t, STOP_REASON_HANDOFF, "handoff")
	testing.expect_value(t, HANDOFF_REASON_BUDGET_EXHAUSTED, "budget_exhausted")
	testing.expect_value(t, HANDOFF_REASON_CONTEXT_TOO_LONG, "context_too_long")
	testing.expect_value(t, HANDOFF_REASON_MANUAL, "manual")
}

// turn_end.context 只用于观测，缺失时序列化成 null，旧读取方忽略即可。
@(test)
test_turn_end_context_roundtrip :: proc(t: ^testing.T) {
	ev := Turn_End_Event {
		turn = 1,
		stop_reason = STOP_REASON_HANDOFF,
		context_info = Turn_Context {
			estimated_tokens = 121340,
			limit_tokens = 950272,
			elided_results = 4,
			elided_bytes = 183422,
			calibration_percent = 103,
		},
	}
	data, err := json.marshal(ev)
	testing.expect(t, err == nil)
	text := string(data)
	testing.expect(t, strings.contains(text, `"context":{"estimated_tokens":121340`))
	testing.expect(t, strings.contains(text, `"stop_reason":"handoff"`))

	back: Turn_End_Event
	uerr := json.unmarshal_string(text, &back)
	testing.expect_value(t, uerr, nil)
	ctx, has_ctx := back.context_info.?
	testing.expect(t, has_ctx)
	testing.expect_value(t, ctx.calibration_percent, 103)

	empty_data, _ := json.marshal(Turn_End_Event{turn = 2})
	testing.expect(t, strings.contains(string(empty_data), `"context":null`))
}
