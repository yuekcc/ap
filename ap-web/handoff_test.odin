package apweb

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// 交接（handoff）在 web 侧复用 turn 通道：同一套单飞、SSE 与取消，
// 只是 ap 子进程换成 --handoff；因此这里验证的是「什么时候允许、怎么转发」。

@(test)
test_turn_handoff_requires_started_session :: proc(t: ^testing.T) {
	dir := test_temp_dir("handoff-slot")
	defer os.remove_all(dir)

	app: App
	api_fixture_setup(t, &app, dir)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	created := api_call(&app, .Post, "/api/session/new")
	testing.expect_value(t, created.status, 200)
	key_value, has_key := api_json_field(t, api_response_text(&created), "session_key")
	testing.expect(t, has_key)
	key := string(key_value.(json.String))

	// 新 slot 还没有真实 session id，ap 的 --handoff 无处可交接。
	response := api_call(
		&app,
		.Post,
		"/api/turn",
		"",
		strings.concatenate({`{"handoff":true,"session_key":"`, key, `"}`}, context.temp_allocator),
	)
	testing.expect_value(t, response.status, 409)
	testing.expect(t, strings.contains(api_response_text(&response), `"code":"handoff_unavailable"`))

	// 聚焦提示词走命令行，超过 8KB 直接拒绝，不再往下传。
	too_large := strings.repeat("a", MAX_HANDOFF_PROMPT_BYTES + 1, context.temp_allocator)
	too_large_body := strings.concatenate(
		{`{"handoff":true,"session_key":"`, key, `","prompt":"`, too_large, `"}`},
		context.temp_allocator,
	)
	large := api_call(&app, .Post, "/api/turn", "", too_large_body)
	testing.expectf(t, large.status == 413, "large: %d %s", large.status, api_response_text(&large))
	testing.expect(t, strings.contains(api_response_text(&large), `"code":"prompt_too_large"`))
}

// 空提示词的 handoff 也是合法请求：只生成交接文档、不跑 turn。
@(test)
test_turn_handoff_runs_on_existing_session :: proc(t: ^testing.T) {
	dir := test_temp_dir("handoff-run")
	defer os.remove_all(dir)

	app: App
	runner_test_setup(t, &app, dir)
	if len(app.agent_bin) == 0 {
		return
	}
	api_register_routes()
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	created := api_call(&app, .Post, "/api/session/new")
	testing.expect_value(t, created.status, 200)
	key_value, has_key := api_json_field(t, api_response_text(&created), "session_key")
	testing.expect(t, has_key)
	key := string(key_value.(json.String))

	// 先跑一轮，让 fake agent 报出真实 session id（handoff 需要 -s）。
	first := api_call(
		&app,
		.Post,
		"/api/turn",
		"",
		strings.concatenate({`{"prompt":"hello","session_key":"`, key, `"}`}, context.temp_allocator),
	)
	testing.expectf(t, first.status == 202, "first: %d %s", first.status, api_response_text(&first))
	testing.expect(t, test_wait_key_idle(&app, key, 10 * time.Second), "first turn did not finish")

	sub: Sse_Subscriber
	testing.expect(t, sse_hub_subscribe(&app.hub, &sub, 512))
	defer sse_hub_unsubscribe(&app.hub, &sub)

	second := api_call(
		&app,
		.Post,
		"/api/turn",
		"",
		strings.concatenate({`{"handoff":true,"session_key":"`, key, `"}`}, context.temp_allocator),
	)
	testing.expect_value(t, second.status, 202)
	testing.expect(t, test_wait_key_idle(&app, key, 10 * time.Second), "handoff did not finish")

	// 交接后 slot 的 session id 换成新 session；前端靠这条 session_start 切换。
	state := runner_state(&app, key, context.temp_allocator)
	testing.expect_value(t, state.session_id, "ses_handoff_new")

	frames := test_drain_frames(&sub)
	defer delete(frames)
	testing.expect(t, strings.contains(frames, `"session_id":"ses_handoff_new"`))
	testing.expect(t, strings.contains(frames, `"stop_reason":"handoff"`))
}
