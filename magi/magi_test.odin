package magi

import apcore "../ap-core"

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

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

// magi 复用 ap 的 settings.json：新增的预算字段要能读入，并参与同一套校验。
// 投票成员没有交接，但预算余量仍会影响 target，所以非法值必须在启动时报错。
@(test)
test_settings_context_budget_fields :: proc(t: ^testing.T) {
	base := os.get_env("TEMP", context.allocator)
	if len(base) == 0 {
		base = os.get_env("TMPDIR", context.allocator)
	}
	dir := fmt.tprintf("%s/ap-magi-budget-%d", base, time.time_to_unix_nano(time.now()))
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	write_settings(
		fmt.tprintf("%s/settings.json", dir),
		`{"model":"m","api_key":"k","context_reserve_tokens":4096,"handoff_max_tokens":2048}`,
	)
	loaded, err := load_settings(dir)
	testing.expect_value(t, err.kind, apcore.Error_Kind.None)
	testing.expect_value(t, loaded.sdk.context_reserve_tokens, 4096)
	testing.expect_value(t, loaded.sdk.handoff_max_tokens, 2048)

	// 余量吃掉整个窗口是配置错误。
	write_settings(
		fmt.tprintf("%s/settings.json", dir),
		`{"model":"m","api_key":"k","context_window_tokens":70000,"max_tokens":65536,"context_reserve_tokens":8192}`,
	)
	_, err2 := load_settings(dir)
	testing.expect_value(t, err2.kind, apcore.Error_Kind.Usage)
}

// 测试用的 settings.json 写入；magi 包没有共享的测试辅助。
write_settings :: proc(path, content: string) {
	if err := os.write_entire_file_from_bytes(path, transmute([]byte)content); err != nil {
		panic("cannot write test settings.json")
	}
}
