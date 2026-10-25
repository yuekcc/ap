package main

import "../internal"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

// 直接调用 app_handle_request，不经过 socket：路由/JSON/错误体都能逐字节断言。
api_call :: proc(app: ^App, method: Http_Method, path: string, query := "", body := "") -> Http_Response {
	request := Http_Request {
		method = method,
		path   = path,
		query  = query,
		body   = transmute([]byte)body,
	}
	response := Http_Response {
		status  = 200,
		headers = make([dynamic]Http_Header, 0, 4, context.temp_allocator),
	}
	app_handle_request(rawptr(app), &request, &response)
	return response
}

api_response_text :: proc(response: ^Http_Response) -> string {
	return string(response.body)
}

api_json_field :: proc(t: ^testing.T, body: string, key: string) -> (json.Value, bool) {
	value, err := json.parse_string(body, .JSON, true, context.temp_allocator)
	if err != nil {
		testing.expectf(t, false, "response is not JSON: %s", body)
		return nil, false
	}
	obj, is_object := value.(json.Object)
	if !is_object {
		testing.expectf(t, false, "response is not a JSON object: %s", body)
		return nil, false
	}
	field, has := obj[key]
	return field, has
}

// 只读 fixture：project 目录直接指到临时目录，方便塞 fake transcript/blob。
api_fixture_setup :: proc(t: ^testing.T, app: ^App, dir: string) {
	app.project = Project {
		config_dir = dir,
		root       = dir,
		hash       = "test",
		dir        = dir,
		blobs_dir  = fmt.aprintf("%s/blobs", dir),
	}
	app.cwd = dir
	app.config_dir = dir
	app.options = Web_Options {
		model     = "some-model",
		max_steps = 3,
	}
	api_register_routes()
	sse_hub_init(&app.hub)
	runner_init(app)
}

@(test)
test_api_health_and_config :: proc(t: ^testing.T) {
	dir := test_temp_dir("api-basic")
	defer os.remove_all(dir)

	app: App
	api_fixture_setup(t, &app, dir)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	health := api_call(&app, .Get, "/api/health")
	testing.expect_value(t, health.status, 200)
	testing.expect_value(t, api_response_text(&health), `{"ok":true,"version":"0.1.0"}`)
	content_type, has_type := header_value(health.headers[:], "content-type")
	testing.expect(t, has_type)
	testing.expect(t, strings.contains(content_type, "application/json"))

	config := api_call(&app, .Get, "/api/config")
	testing.expect_value(t, config.status, 200)
	config_body := api_response_text(&config)
	model, _ := api_json_field(t, config_body, "model")
	testing.expect_value(t, model.(json.String), json.String("some-model"))
	agent, _ := api_json_field(t, config_body, "agent")
	_, agent_is_null := agent.(json.Null)
	testing.expect(t, agent_is_null)
	cwd, _ := api_json_field(t, config_body, "cwd")
	testing.expect_value(t, cwd.(json.String), json.String(app.cwd))
	platform, _ := api_json_field(t, config_body, "platform")
	testing.expect_value(t, platform.(json.String), json.String(platform_name()))
}

// 404 与 405 都必须是统一的 JSON 错误体，而不是 text/plain。
@(test)
test_api_unknown_path_and_method_mismatch :: proc(t: ^testing.T) {
	dir := test_temp_dir("api-errors")
	defer os.remove_all(dir)

	app: App
	api_fixture_setup(t, &app, dir)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	missing := api_call(&app, .Get, "/api/nope")
	testing.expect_value(t, missing.status, 404)
	testing.expect_value(t, api_response_text(&missing), `{"error":{"code":"not_found","message":"no such API endpoint"}}`)

	wrong_method := api_call(&app, .Post, "/api/health")
	testing.expect_value(t, wrong_method.status, 405)
	testing.expect_value(
		t,
		api_response_text(&wrong_method),
		`{"error":{"code":"method_not_allowed","message":"method not allowed for this endpoint"}}`,
	)
}

@(test)
test_api_session_pointer_new_and_resume :: proc(t: ^testing.T) {
	dir := test_temp_dir("api-session")
	defer os.remove_all(dir)

	app: App
	api_fixture_setup(t, &app, dir)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	current := api_call(&app, .Get, "/api/session/current")
	testing.expect_value(t, current.status, 200)
	testing.expect_value(
		t,
		api_response_text(&current),
		`{"session_id":null,"running":false,"turn":null}`,
	)

	resume := api_call(&app, .Post, "/api/session/resume", "", `{"session_id":"ses_abc"}`)
	testing.expect_value(t, resume.status, 200)
	testing.expect_value(t, api_response_text(&resume), `{"session_id":"ses_abc"}`)

	current2 := api_call(&app, .Get, "/api/session/current")
	testing.expect(t, strings.contains(api_response_text(&current2), `"session_id":"ses_abc"`))

	new_session := api_call(&app, .Post, "/api/session/new")
	testing.expect_value(t, new_session.status, 200)
	testing.expect_value(t, api_response_text(&new_session), `{"session_id":null}`)

	current3 := api_call(&app, .Get, "/api/session/current")
	testing.expect(t, strings.contains(api_response_text(&current3), `"session_id":null`))

	bad := api_call(&app, .Post, "/api/session/resume", "", `{}`)
	testing.expect_value(t, bad.status, 400)
	testing.expect(t, strings.contains(api_response_text(&bad), `"code":"invalid_request"`))

	malformed := api_call(&app, .Post, "/api/session/resume", "", `not json`)
	testing.expect_value(t, malformed.status, 400)
	testing.expect(t, strings.contains(api_response_text(&malformed), `"code":"invalid_json"`))
}

@(test)
test_api_cwd_and_pick_placeholder :: proc(t: ^testing.T) {
	dir := test_temp_dir("api-cwd")
	defer os.remove_all(dir)

	app: App
	api_fixture_setup(t, &app, dir)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	cwd := api_call(&app, .Get, "/api/cwd")
	testing.expect_value(t, cwd.status, 200)
	testing.expect(t, strings.contains(api_response_text(&cwd), `"cwd":`))

	pick := api_call(&app, .Post, "/api/cwd/pick")
	testing.expect_value(t, pick.status, 501)
	testing.expect(t, strings.contains(api_response_text(&pick), `"code":"not_implemented"`))

	testing.expect(t, picker_begin(&app))
	busy := api_call(&app, .Post, "/api/cwd/pick")
	testing.expect_value(t, busy.status, 409)
	testing.expect(t, strings.contains(api_response_text(&busy), `"code":"picker_busy"`))
	picker_end(&app)
}

@(test)
test_api_sessions_list :: proc(t: ^testing.T) {
	dir := test_temp_dir("api-sessions")
	defer os.remove_all(dir)

	app: App
	api_fixture_setup(t, &app, dir)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)
	os.make_directory_all(app.project.dir)

	test_write_file(
		session_file(app.project, "ses_old"),
		`{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_old"}` + "\n" +
		`{"v":1,"seq":1,"ts":2,"type":"turn_start","turn":1}` + "\n",
	)
	test_write_file(
		session_file(app.project, "ses_new"),
		`{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_new"}` + "\n" +
		`{"v":1,"seq":1,"ts":2,"type":"turn_start","turn":1}` + "\n" +
		`{"v":1,"seq":2,"ts":3,"type":"turn_end","turn":1,"stop_reason":"stop"}` + "\n" +
		`{"v":1,"seq":3,"ts":4,"type":"turn_start","turn":2}` + "\n",
	)

	response := api_call(&app, .Get, "/api/sessions")
	testing.expect_value(t, response.status, 200)

	entries: []Api_Session_Entry
	err := json.unmarshal(response.body, &entries, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expectf(t, err == nil, "cannot parse sessions response: %v", err)
	testing.expect_value(t, len(entries), 2)

	turns_by_id := make(map[string]int, context.temp_allocator)
	for entry in entries {
		turns_by_id[entry.session_id] = entry.turns
		testing.expect(t, entry.ts > 0)
	}
	testing.expect_value(t, turns_by_id["ses_old"], 1)
	testing.expect_value(t, turns_by_id["ses_new"], 2)
}

HISTORY_BLOB_TEXT :: "resolved text\n"
HISTORY_ARGS_BLOB :: `{"file_path":"x.txt"}`

@(test)
test_api_history_resolves_refs_and_truncates :: proc(t: ^testing.T) {
	dir := test_temp_dir("api-history")
	defer os.remove_all(dir)

	app: App
	api_fixture_setup(t, &app, dir)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)
	os.make_directory_all(app.project.blobs_dir)

	text_sha := internal.sha256_hex(transmute([]byte)string(HISTORY_BLOB_TEXT))
	args_sha := internal.sha256_hex(transmute([]byte)string(HISTORY_ARGS_BLOB))
	test_write_file(blob_file(app.project, text_sha), HISTORY_BLOB_TEXT)
	test_write_file(blob_file(app.project, args_sha), HISTORY_ARGS_BLOB)

	big := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 300 {
		fmt.sbprintf(&big, "line-%03d\n", i)
	}
	big_text := strings.to_string(big)
	big_sha := internal.sha256_hex(transmute([]byte)big_text)
	test_write_file(blob_file(app.project, big_sha), big_text)

	missing_sha := strings.repeat("0", 64, context.temp_allocator)

	transcript := strings.concatenate(
		{
			`{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_hist"}`,
			"\n",
			`{"v":1,"seq":1,"ts":2,"type":"user_message","content":"hi"}`,
			"\n",
			`{"v":1,"seq":2,"ts":3,"type":"message_end","message_id":"m1","role":"assistant","content":[{"type":"text","text_ref":"`,
			text_sha,
			`"},{"type":"text","text_ref":"`,
			missing_sha,
			`","text_preview":"fallback preview"}]}`,
			"\n",
			`{"v":1,"seq":3,"ts":4,"type":"tool_execution_start","tool_call_id":"c1","name":"read_file","args_ref":"`,
			args_sha,
			`"}`,
			"\n",
			`{"v":1,"seq":4,"ts":5,"type":"tool_execution_end","tool_call_id":"c1","ok":true,"content_ref":"`,
			big_sha,
			`","content_bytes":2700}`,
			"\n",
		},
		context.temp_allocator,
	)
	test_write_file(session_file(app.project, "ses_hist"), transcript)

	response := api_call(&app, .Get, "/api/history", "session_id=ses_hist")
	testing.expect_value(t, response.status, 200)

	history: Api_History
	err := json.unmarshal(response.body, &history, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expectf(t, err == nil, "cannot parse history: %v", err)
	testing.expect_value(t, len(history.events), 5)

	message_end, has_message_end := history_event(history.events, "message_end")
	testing.expect(t, has_message_end)
	blocks, blocks_ok := message_end["content"].(json.Array)
	testing.expect(t, blocks_ok)
	if len(blocks) == 2 {
		first, _ := blocks[0].(json.Object)
		text, text_ok := json_string_field(first, "text")
		testing.expect(t, text_ok)
		testing.expect_value(t, text, HISTORY_BLOB_TEXT)

		second, _ := blocks[1].(json.Object)
		fallback, fallback_ok := json_string_field(second, "text")
		testing.expect(t, fallback_ok)
		testing.expect_value(t, fallback, "fallback preview")
	}

	tool_start, has_tool_start := history_event(history.events, "tool_execution_start")
	testing.expect(t, has_tool_start)
	args_text, args_ok := json_string_field(tool_start, "args_text")
	testing.expect(t, args_ok)
	testing.expect_value(t, args_text, HISTORY_ARGS_BLOB)
	args_preview, args_preview_ok := json_string_field(tool_start, "args_preview")
	testing.expect(t, args_preview_ok)
	testing.expect_value(t, args_preview, HISTORY_ARGS_BLOB)

	tool_end, has_tool_end := history_event(history.events, "tool_execution_end")
	testing.expect(t, has_tool_end)
	// 截断时不再内联完整 content，前端据此显示「已截断」提示。
	_, has_inline_content := tool_end["content"]
	testing.expect(t, !has_inline_content)
	content_preview, preview_ok := json_string_field(tool_end, "content_preview")
	testing.expect(t, preview_ok)
	testing.expect(t, strings.contains(content_preview, "line-199\n"))
	testing.expect(t, !strings.contains(content_preview, "line-200\n"))
	truncated, truncated_ok := tool_end["content_truncated"].(json.Boolean)
	testing.expect(t, truncated_ok)
	testing.expect_value(t, bool(truncated), true)

	missing := api_call(&app, .Get, "/api/history", "session_id=ses_missing")
	testing.expect_value(t, missing.status, 404)
	testing.expect(t, strings.contains(api_response_text(&missing), `"code":"session_not_found"`))

	no_param := api_call(&app, .Get, "/api/history")
	testing.expect_value(t, no_param.status, 400)
}

history_event :: proc(events: []json.Value, typ: string) -> (json.Object, bool) {
	for event in events {
		obj, is_object := event.(json.Object)
		if !is_object {
			continue
		}
		if value, has := json_string_field(obj, "type"); has && value == typ {
			return obj, true
		}
	}
	return nil, false
}

@(test)
test_api_turn_validation_and_single_flight :: proc(t: ^testing.T) {
	dir := test_temp_dir("api-turn")
	defer os.remove_all(dir)

	app: App
	runner_test_setup(t, &app, dir)
	if len(app.agent_bin) == 0 {
		return
	}
	api_register_routes()
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	empty := api_call(&app, .Post, "/api/turn", "", `{"prompt":"   "}`)
	testing.expect_value(t, empty.status, 400)
	testing.expect(t, strings.contains(api_response_text(&empty), `"code":"prompt_empty"`))

	bad_json := api_call(&app, .Post, "/api/turn", "", `nope`)
	testing.expect_value(t, bad_json.status, 400)
	testing.expect(t, strings.contains(api_response_text(&bad_json), `"code":"invalid_json"`))

	too_large_prompt := strings.repeat("a", MAX_PROMPT_BYTES + 1, context.temp_allocator)
	too_large_body := strings.concatenate({`{"prompt":"`, too_large_prompt, `"}`}, context.temp_allocator)
	too_large := api_call(&app, .Post, "/api/turn", "", too_large_body)
	testing.expect_value(t, too_large.status, 413)
	testing.expect(t, strings.contains(api_response_text(&too_large), `"code":"prompt_too_large"`))

	bad_steps := api_call(&app, .Post, "/api/turn", "", `{"prompt":"hi","max_steps":0}`)
	testing.expect_value(t, bad_steps.status, 400)

	started := api_call(&app, .Post, "/api/turn", "", `{"prompt":"[scenario:cancel]"}`)
	testing.expect_value(t, started.status, 202)
	testing.expect_value(t, api_response_text(&started), `{"accepted":true}`)

	testing.expect(t, test_wait_session(&app, "ses_cancel", 10 * time.Second), "agent did not start")

	current := api_call(&app, .Get, "/api/session/current")
	testing.expect(t, strings.contains(api_response_text(&current), `"running":true`))
	testing.expect(t, strings.contains(api_response_text(&current), `"session_id":"ses_cancel"`))
	testing.expect(t, strings.contains(api_response_text(&current), `"turn":1`))

	busy := api_call(&app, .Post, "/api/turn", "", `{"prompt":"second"}`)
	testing.expect_value(t, busy.status, 409)
	testing.expect(t, strings.contains(api_response_text(&busy), `"code":"turn_running"`))

	resume := api_call(&app, .Post, "/api/session/resume", "", `{"session_id":"ses_other"}`)
	testing.expect_value(t, resume.status, 409)
	testing.expect(t, strings.contains(api_response_text(&resume), `"code":"turn_running"`))

	pick := api_call(&app, .Post, "/api/cwd/pick")
	testing.expect_value(t, pick.status, 409)
	testing.expect(t, strings.contains(api_response_text(&pick), `"code":"turn_running"`))

	cancelled := api_call(&app, .Delete, "/api/turn")
	testing.expect_value(t, cancelled.status, 202)
	testing.expect_value(t, api_response_text(&cancelled), `{"cancelled":true}`)
	testing.expect(t, test_wait_runner_idle(&app, 10 * time.Second), "cancel did not stop turn")

	idle_cancel := api_call(&app, .Delete, "/api/turn")
	testing.expect_value(t, idle_cancel.status, 202)
	testing.expect_value(t, api_response_text(&idle_cancel), `{"cancelled":false}`)
}

// SSE 端点：注册 hub → 头部 chunked → 广播帧 → hub 关停后收尾。
Sse_Test_Broadcaster :: struct {
	hub: ^Sse_Hub,
}

sse_test_broadcast_once :: proc(user: rawptr) {
	state := (^Sse_Test_Broadcaster)(user)
	start := time.tick_now()
	for sse_hub_subscriber_count(state.hub) == 0 && time.tick_since(start) < 5 * time.Second {
		time.sleep(2 * time.Millisecond)
	}
	_ = sse_hub_broadcast(state.hub, "ap", `{"type":"message_update"}`)
	time.sleep(10 * time.Millisecond)
	sse_hub_destroy(state.hub)
}

@(test)
test_api_events_streams_hub_frames :: proc(t: ^testing.T) {
	dir := test_temp_dir("api-events")
	defer os.remove_all(dir)

	app: App
	api_fixture_setup(t, &app, dir)
	defer runner_shutdown(&app)

	transport := test_transport("GET /api/events HTTP/1.1\r\n\r\n")
	state := Sse_Test_Broadcaster{hub = &app.hub}
	handle := thread.create_and_start_with_data(rawptr(&state), sse_test_broadcast_once)
	testing.expect(t, handle != nil)
	defer thread.join(handle)

	serve_connection(
		{user = &transport, recv = test_transport_recv, send = test_transport_send},
		app_handle_request,
		&app,
	)

	out := test_transport_output(&transport)
	testing.expect(t, strings.has_prefix(out, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(out, "Content-Type: text/event-stream\r\n"))
	testing.expect(t, strings.contains(out, "Transfer-Encoding: chunked\r\n"))
	testing.expect(t, strings.contains(out, "data: {\"type\":\"message_update\"}\n"))
	testing.expect(t, strings.has_suffix(out, "0\r\n\r\n"))
}
