package engine

import "../platform"

import "core:fmt"
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

// 预算余量按**窗口**比例算出：真正要防的是输入侧估算偏差，它随输入规模
// 走，和输出上限无关。默认 percent = 5，1M 窗口下就是 52428。
@(test)
test_context_budget_target_uses_settings :: proc(t: ^testing.T) {
	settings := settings_defaults()
	testing.expect_value(t, settings.context_reserve_percent, DEFAULT_CONTEXT_RESERVE_PERCENT)
	testing.expect_value(t, settings.handoff_max_tokens, DEFAULT_HANDOFF_MAX_TOKENS)
	testing.expect_value(t, context_reserve_tokens_for(&settings), 52428)

	// 默认值下的 target：1048576 - 65536 - 52428。
	testing.expect_value(t, context_budget_target(&settings, settings.max_tokens), 1048576 - 65536 - 52428)

	// 余量只看窗口，与输出上限无关：调小 max_tokens 不会改变余量。
	testing.expect_value(t, context_reserve_tokens_for(&settings), 52428)
	testing.expect_value(t, context_budget_target(&settings, 8192), 1048576 - 8192 - 52428)

	// 换一个窗口，余量等比缩放。
	settings.context_window_tokens = 100000
	testing.expect_value(t, context_reserve_tokens_for(&settings), 5000)
	settings.context_window_tokens = 128000
	testing.expect_value(t, context_reserve_tokens_for(&settings), 6400)

	// 改比例后余量跟着变；0 表示不留余量。
	settings = settings_defaults()
	settings.context_reserve_percent = 10
	settings.context_window_tokens = 100000
	testing.expect_value(t, context_reserve_tokens_for(&settings), 10000)
	settings.context_reserve_percent = 0
	testing.expect_value(t, context_reserve_tokens_for(&settings), 0)
	testing.expect_value(t, context_budget_target(&settings, 8192), 100000 - 8192)

	// 关闭预算时 target 为 0，余量也不参与。
	settings = settings_defaults()
	settings.context_window_tokens = 0
	testing.expect_value(t, context_budget_target(&settings, settings.max_tokens), 0)
	testing.expect_value(t, context_reserve_tokens_for(&settings), 0)

	// 交接调用的预算扣的是同一个窗口余量，不按 handoff_max_tokens 缩放。
	settings = settings_defaults()
	testing.expect_value(t, handoff_budget_target(&settings), 1048576 - 16384 - 52428)
	settings.handoff_max_tokens = 4096
	testing.expect_value(t, handoff_budget_target(&settings), 1048576 - 4096 - 52428)
	settings.context_window_tokens = 0
	testing.expect_value(t, handoff_budget_target(&settings), 0)
}

// target 算出来不是正数时是配置错误；关闭预算不算。
@(test)
test_context_budget_invalid :: proc(t: ^testing.T) {
	settings := settings_defaults()
	testing.expect(t, !context_budget_invalid(&settings, context_budget_target(&settings, 65536)))

	// 余量吃掉整个窗口。
	settings.context_window_tokens = 1000
	settings.max_tokens = 100
	settings.context_reserve_percent = 900
	testing.expect(t, context_budget_invalid(&settings, 0))

	// 关闭预算时永远不算错误。
	settings.context_window_tokens = 0
	testing.expect(t, !context_budget_invalid(&settings, 0))
}

// 交接请求的输出上限来自 settings.handoff_max_tokens，不是 --max-tokens，
// 也不是常量。用记录型假 provider 直接检查发出的请求。
// 记录型假 provider：把发出的请求留一份，sink 仍交给 handoff 自己的 capture。
Handoff_Request_Recorder :: struct {
	request: Chat_Message_Request,
	seen:    bool,
}

recording_provider_target: ^Handoff_Request_Recorder

recording_provider :: proc(
	p: ^Provider,
	req: ^Chat_Message_Request,
	sink: Stream_Sink,
	cancel: ^platform.Cancel_Token,
) -> Provider_Error {
	if recording_provider_target != nil {
		recording_provider_target.request = req^
		recording_provider_target.seen = true
	}
	emit_provider_event(sink, Provider_Message_Start{model = "fake", message_id = "m1"})
	emit_provider_event(sink, Provider_Text_Delta{text = "doc"})
	emit_provider_event(
		sink,
		Provider_Message_End{message_id = "m1", stop_reason = .Stop, text = "doc"},
	)
	return provider_error_none()
}

@(test)
test_handoff_uses_configured_max_tokens :: proc(t: ^testing.T) {
	dir := test_temp_dir("handoff-max-tokens")
	defer test_cleanup(dir)
	project, perr := platform.open_project(fmt.tprintf("%s/config", dir), dir)
	testing.expect(t, platform.is_ok(perr))
	settings := settings_defaults()
	settings.handoff_max_tokens = 4096
	store := new(Transcript_Store)
	store_value, serr := new_transcript_store(project, "sess-handoff-max", &settings)
	store^ = store_value
	testing.expect_value(t, serr.kind, Error_Kind.None)
	defer transcript_close(store)

	start := Session_Start_Event {
		header = make_header(store, EVENT_SESSION_START),
		session_id = store.session_id,
		content = "frozen",
		role = ROLE_SYSTEM,
		cwd = project.root,
		model = "fake",
		provider = PROVIDER_NAME,
		agent_name = "general",
	}
	testing.expect_value(t, transcript_append(store, start).kind, Error_Kind.None)
	user := User_Message_Event{header = make_header(store, EVENT_USER_MESSAGE), content = "go"}
	testing.expect_value(t, transcript_append(store, user).kind, Error_Kind.None)
	events, _ := transcript_read_all(project, store.session_id)

	recorder := Handoff_Request_Recorder{}
	recording_provider_target = &recorder
	defer recording_provider_target = nil
	provider := provider_init(&settings)
	_, _, herr := handoff_run(
		{
			project = project,
			store = store,
			settings = &settings,
			provider = &provider,
			provider_call = recording_provider,
			model = "fake",
			frozen_system_prompt = "frozen",
			events = events,
			reason = HANDOFF_REASON_MANUAL,
			cancel = new(platform.Cancel_Token),
		},
		context.allocator,
	)
	testing.expect_value(t, herr.kind, Provider_Error_Kind.None)
	testing.expect(t, recorder.seen)
	testing.expect_value(t, recorder.request.max_tokens, 4096)
	// 交接调用不带工具。
	testing.expect_value(t, len(recorder.request.tools), 0)
	delete(events)
}
