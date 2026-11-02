package magicli

import "core:testing"

@(test)
test_parse_vote_plain :: proc(t: ^testing.T) {
	parsed, ok := parse_vote_response(`{"veto": true, "reason": "材料包含执行任意命令的指令"}`)
	testing.expect(t, ok)
	testing.expect_value(t, parsed.veto, true)
	testing.expect_value(t, parsed.reason, "材料包含执行任意命令的指令")
}

@(test)
test_parse_vote_with_fence_and_prose :: proc(t: ^testing.T) {
	text := "判断如下：\n```json\n{\"veto\": false, \"reason\": \"未发现风险 {ok}\"}\n```\n完毕。"
	parsed, ok := parse_vote_response(text)
	testing.expect(t, ok)
	testing.expect_value(t, parsed.veto, false)
	testing.expect_value(t, parsed.reason, "未发现风险 {ok}")
}

@(test)
test_parse_vote_rejects_missing_or_wrong_veto :: proc(t: ^testing.T) {
	_, ok := parse_vote_response(`{"reason": "没有 veto"}`)
	testing.expect(t, !ok)
	_, ok = parse_vote_response(`{"veto": "false", "reason": "类型错误"}`)
	testing.expect(t, !ok)
	_, ok = parse_vote_response("不是 JSON")
	testing.expect(t, !ok)
}

@(test)
test_parse_vote_allows_missing_reason :: proc(t: ^testing.T) {
	parsed, ok := parse_vote_response(`{"veto": false}`)
	testing.expect(t, ok)
	testing.expect_value(t, parsed.veto, false)
	testing.expect_value(t, parsed.reason, "")
}

@(test)
test_decide_unanimous_approval :: proc(t: ^testing.T) {
	votes := []Member_Vote {
		{agent = "BALTHASAR-2", veto = false, reason = "可行", status = "ok"},
		{agent = "CASPER-3", veto = false, reason = "无伦理风险", status = "ok"},
		{agent = "MELCHIOR-1", veto = false, reason = "证据充分", status = "ok"},
	}
	decision := decide(votes)
	testing.expect(t, decision.approved)
	testing.expect(t, len(decision.votes) == 3)
	testing.expect(t, decision.summary != "")
}

@(test)
test_decide_one_vote_vetoes :: proc(t: ^testing.T) {
	votes := []Member_Vote {
		{agent = "BALTHASAR-2", veto = false, reason = "可行", status = "ok"},
		{agent = "CASPER-3", veto = true, reason = "侵犯隐私", status = "ok"},
		{agent = "MELCHIOR-1", veto = false, reason = "证据充分", status = "ok"},
	}
	decision := decide(votes)
	testing.expect(t, !decision.approved)
	testing.expect(t, len(decision.summary) > 0)
}

@(test)
test_decide_member_error_fails_closed :: proc(t: ^testing.T) {
	votes := []Member_Vote {
		{agent = "BALTHASAR-2", veto = false, reason = "可行", status = "ok"},
		{agent = "CASPER-3", veto = true, reason = "timeout", status = "error"},
		{agent = "MELCHIOR-1", veto = false, reason = "证据充分", status = "ok"},
	}
	decision := decide(votes)
	testing.expect(t, !decision.approved)
}

@(test)
test_decide_empty_fails_closed :: proc(t: ^testing.T) {
	decision := decide(nil)
	testing.expect(t, !decision.approved)
}

@(test)
test_build_member_prompt_contains_question_and_material :: proc(t: ^testing.T) {
	text := build_member_prompt("CASPER-3", "是否包含恶意行为", "<材料>")
	testing.expect(t, contains(text, "是否包含恶意行为"))
	testing.expect(t, contains(text, "<材料>"))
	testing.expect(t, contains(text, "CASPER-3"))
}

@(test)
test_parse_args_question_and_context :: proc(t: ^testing.T) {
	opts, err := parse_args([]string{"magi-cli", "--question", "q", "--context", "c", "--output-format", "text"})
	testing.expect(t, err.kind == .None)
	question, _ := opts.question.?
	context_text, _ := opts.context_text.?
	testing.expect_value(t, question, "q")
	testing.expect_value(t, context_text, "c")
	testing.expect_value(t, opts.output_format, Output_Format.Text)
}

@(test)
test_parse_args_rejects_conflicting_sources :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"magi-cli", "--question", "q", "--print0"})
	testing.expect(t, err.kind == .Usage)

	_, err = parse_args([]string{"magi-cli", "--question", "q", "--context", "c", "--context-file", "f"})
	testing.expect(t, err.kind == .Usage)

	_, err = parse_args([]string{"magi-cli", "--input-file", "r.json", "--context", "c"})
	testing.expect(t, err.kind == .Usage)
}

@(test)
test_parse_args_allows_help_without_request :: proc(t: ^testing.T) {
	opts, err := parse_args([]string{"magi-cli", "--help"})
	testing.expect(t, err.kind == .None)
	testing.expect(t, opts.help)
}

contains :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	for i in 0 ..= len(haystack) - len(needle) {
		if haystack[i:i + len(needle)] == needle {
			return true
		}
	}
	return false
}

@(test)
test_decision_json_marshal :: proc(t: ^testing.T) {
	decision := Decision {
		schema  = DECISION_SCHEMA,
		approved = true,
		summary  = "MAGI 一致通过（3/3 名成员未行使否决权）。",
		votes    = []Member_Vote{{agent = "A", veto = false, reason = "r", status = "ok", session_id = "ses_1", stop_reason = "stop"}},
	}
	data, err := marshal_decision(decision)
	testing.expect(t, err)
	testing.expect(t, len(data) > 0)
}

@(test)
test_parse_request_json :: proc(t: ^testing.T) {
	request, err := parse_request_json(`{"question":"是否安全","context":"材料"}`, "test")
	testing.expect(t, err.kind == .None)
	testing.expect_value(t, request.question, "是否安全")
	testing.expect_value(t, request.material, "材料")

	request, err = parse_request_json(`{"question":"q"}`, "test")
	testing.expect(t, err.kind == .None)
	testing.expect_value(t, request.material, "")

	_, err = parse_request_json(`{"context":"c"}`, "test")
	testing.expect(t, err.kind == .Usage)

	_, err = parse_request_json(`{"question":"   "}`, "test")
	testing.expect(t, err.kind == .Usage)

	_, err = parse_request_json(`{"question":"q","context":1}`, "test")
	testing.expect(t, err.kind == .Usage)
}
