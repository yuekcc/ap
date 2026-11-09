package engine

import "core:strings"
import "core:testing"

@(test)
test_estimate_text_tokens :: proc(t: ^testing.T) {
	testing.expect_value(t, estimate_text_tokens(""), 0)
	// 纯 ASCII：4 字节 1 token，余数向上取整。
	testing.expect_value(t, estimate_text_tokens("abcd"), 1)
	testing.expect_value(t, estimate_text_tokens("abcde"), 2)
	// 纯 CJK：3 字节 1 token（“中文” 是 6 字节）。
	testing.expect_value(t, estimate_text_tokens("中文"), 2)
	testing.expect_value(t, estimate_text_tokens("中"), 1)
	// 混合：ascii 4 字节 + 非 ascii 3 字节 = 1 + 1。
	testing.expect_value(t, estimate_text_tokens("abcd中"), 2)
	// 单字节非 ASCII（2 字节的 UTF-8 字符）仍走非 ascii 分支。
	testing.expect_value(t, estimate_text_tokens("é"), 1)
}

@(test)
test_estimate_counts_message_structure :: proc(t: ^testing.T) {
	msg := Chat_Message{role = ROLE_TOOL, content = "abcd", tool_call_id = "call_1"}
	// 4 结构 + 1 content + 2 tool_call_id（7 字节向上取整到 2）。
	testing.expect_value(t, estimate_message_tokens(msg), 4 + 1 + 2)

	call := Chat_Tool_Call {
		id = "c1",
		type = "function",
		function = Chat_Tool_Function{name = "bash", arguments = "{}"},
	}
	with_call := Chat_Message{role = ROLE_ASSISTANT, tool_calls = []Chat_Tool_Call{call}}
	expected := 4 + ESTIMATE_TOOL_CALL_OVERHEAD + 1 + 1 + 1
	testing.expect_value(t, estimate_message_tokens(with_call), expected)
}

@(test)
test_calibration_percent :: proc(t: ^testing.T) {
	// 没有观测值时不校准。
	testing.expect_value(t, calibration_percent_from(0, 0), 100)
	testing.expect_value(t, calibration_percent_from(1000, 0), 100)
	// 正常观测。
	testing.expect_value(t, calibration_percent_from(1000, 1030), 103)
	// 下限与上限钳制。
	testing.expect_value(t, calibration_percent_from(1000, 10), CALIBRATION_MIN_PERCENT)
	testing.expect_value(t, calibration_percent_from(1000, 9000), CALIBRATION_MAX_PERCENT)
	testing.expect_value(t, calibrate_tokens(1000, 100), 1000)
	testing.expect_value(t, calibrate_tokens(1000, 200), 2000)
}

@(test)
test_elide_keeps_recent_and_small_and_failed :: proc(t: ^testing.T) {
	// 构造 10 个大结果：最近 6 个必须保留；中间一个失败结果必须保留；
	// 一个小结果必须保留。
	messages := make([dynamic]Chat_Message, 0, 16)
	slots := make([dynamic]Tool_Result_Slot, 0, 16)
	big := strings.repeat("x", ELIDE_MIN_BYTES)
	for i in 0 ..< 10 {
		content := big
		ok := true
		if i == 1 {
			ok = false
			content = strings.concatenate([]string{"failed: ", big})
		}
		if i == 2 {
			content = "small"
		}
		append(&messages, Chat_Message{role = ROLE_TOOL, content = content, tool_call_id = "c"})
		append(
			&slots,
			Tool_Result_Slot{message_index = i, name = "bash", ok = ok, bytes = len(content)},
		)
	}
	base := estimate_messages_tokens(messages[:])
	result := elide_tool_results(messages[:], slots[:], 1, 100, base, context.allocator)
	// 可省略候选是 0,3,4,5,6,7,8,9，去掉最近 6 个后只剩 0,3。
	testing.expect_value(t, result.elided_results, 2)
	testing.expect_value(t, messages[0].content.?, elided_stub("bash", len(big)))
	testing.expect(t, strings.has_prefix(messages[1].content.?, "failed: "))
	testing.expect_value(t, messages[2].content.?, "small")
	testing.expect_value(t, messages[3].content.?, elided_stub("bash", len(big)))
	testing.expect_value(t, messages[9].content.?, big)
	testing.expect(t, result.elided_bytes > 0)
}

@(test)
test_elide_stops_at_target :: proc(t: ^testing.T) {
	// 目标足够大时一条都不省略。
	messages := make([dynamic]Chat_Message, 0, 8)
	slots := make([dynamic]Tool_Result_Slot, 0, 8)
	big := strings.repeat("x", ELIDE_MIN_BYTES * 2)
	for i in 0 ..< 8 {
		append(&messages, Chat_Message{role = ROLE_TOOL, content = big})
		append(
			&slots,
			Tool_Result_Slot{message_index = i, name = "bash", ok = true, bytes = len(big)},
		)
	}
	base := estimate_messages_tokens(messages[:])
	// target 的 80% 已经大于 base，不需要省略。
	wide := elide_tool_results(messages[:], slots[:], base * 2, 100, base, context.allocator)
	testing.expect_value(t, wide.elided_results, 0)

	// 收紧目标后只省略刚好够的那几条。
	tight := elide_tool_results(
		messages[:],
		slots[:],
		base / 4,
		100,
		base,
		context.allocator,
	)
	testing.expect(t, tight.elided_results > 0)
	testing.expect(t, tight.elided_results <= 2)
}

@(test)
test_elide_is_deterministic :: proc(t: ^testing.T) {
	make_messages :: proc() -> ([dynamic]Chat_Message, [dynamic]Tool_Result_Slot) {
		messages := make([dynamic]Chat_Message, 0, 16)
		slots := make([dynamic]Tool_Result_Slot, 0, 16)
		for i in 0 ..< 12 {
			content := strings.repeat("y", ELIDE_MIN_BYTES + i)
			append(&messages, Chat_Message{role = ROLE_TOOL, content = content, tool_call_id = "c"})
			append(
				&slots,
				Tool_Result_Slot{message_index = i, name = "read_file", ok = true, bytes = len(content)},
			)
		}
		return messages, slots
	}
	first_msgs, first_slots := make_messages()
	defer { delete(first_msgs); delete(first_slots) }
	second_msgs, second_slots := make_messages()
	defer { delete(second_msgs); delete(second_slots) }

	base := estimate_messages_tokens(first_msgs[:])
	a := elide_tool_results(first_msgs[:], first_slots[:], base / 2, 100, base, context.allocator)
	// 用不同的分配顺序再算一次：候选遍历按消息顺序，结果必须逐字节相同。
	other := make([]byte, 128)
	defer delete(other)
	b := elide_tool_results(second_msgs[:], second_slots[:], base / 2, 100, base, context.allocator)
	testing.expect_value(t, a.elided_results, b.elided_results)
	testing.expect_value(t, string(messages_bytes(first_msgs[:])), string(messages_bytes(second_msgs[:])))
}

@(test)
test_elided_stub_text_is_fixed :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		elided_stub("bash", 4096),
		"[tool output elided: bash, 4096 bytes. Re-run the tool or re-read the file if you need it again.]",
	)
}

@(test)
test_handoff_system_prompt_appends_and_keeps_prefix :: proc(t: ^testing.T) {
	composed := handoff_system_prompt("frozen prompt", context.allocator)
	defer delete(composed)
	testing.expect(t, strings.has_prefix(composed, "frozen prompt\n\n"))
	testing.expect(t, strings.has_suffix(composed, HANDOFF_PROMPT))
}

// 冻结 prompt 是稳定前缀：交接请求的 system 消息以主请求的 system prompt
// 逐字节开头，改前缀会让整份 prompt cache 失效。
@(test)
test_handoff_system_prompt_uses_frozen_prefix :: proc(t: ^testing.T) {
	frozen := "frozen prompt\n"
	composed := handoff_system_prompt(frozen, context.allocator)
	defer delete(composed)
	testing.expect(t, strings.has_prefix(composed, frozen))
}

@(test)
test_handoff_user_message_shape :: proc(t: ^testing.T) {
	text := handoff_user_message("ses_1", "doc")
	testing.expect_value(t, text, "## 上一会话交接\n来源 session: ses_1\n\ndoc")
}
