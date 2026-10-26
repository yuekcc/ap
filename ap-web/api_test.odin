package main

import "../ap/platform"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import sync_chan "core:sync/chan"
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

// 编码失败不能把 2xx 和一句错误 JSON 混在一起：调用方会把它当成成功响应。
@(test)
test_api_json_encoding_failure_returns_500 :: proc(t: ^testing.T) {
	response := Http_Response {
		status  = 200,
		headers = make([dynamic]Http_Header, 0, 4, context.temp_allocator),
	}
	// core:encoding/json 不支持函数类型，用它触发编码失败。
	api_json(&response, 200, proc() {})
	testing.expect_value(t, response.status, 500)
	testing.expect_value(
		t,
		api_response_text(&response),
		`{"error":{"code":"internal_error","message":"cannot encode response"}}`,
	)
	content_type, has_type := header_value(response.headers[:], "content-type")
	testing.expect(t, has_type)
	testing.expect(t, strings.contains(content_type, "application/json"))
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
		`{"session_key":null,"session_id":null,"cwd":null,"running":false,"turn":null}`,
	)

	resume := api_call(&app, .Post, "/api/session/resume", "", `{"session_id":"ses_abc"}`)
	testing.expect_value(t, resume.status, 200)
	resume_body := api_response_text(&resume)
	testing.expect(t, strings.contains(resume_body, `"session_id":"ses_abc"`))
	testing.expect(t, strings.contains(resume_body, `"session_key":"ses_abc"`))
	resume_cwd, has_resume_cwd := api_json_field(t, resume_body, "cwd")
	testing.expect(t, has_resume_cwd)
	testing.expect_value(t, resume_cwd.(json.String), json.String(dir))

	current2 := api_call(&app, .Get, "/api/session/current")
	testing.expect(t, strings.contains(api_response_text(&current2), `"session_id":"ses_abc"`))
	testing.expect(t, strings.contains(api_response_text(&current2), `"session_key":"ses_abc"`))

	new_session := api_call(&app, .Post, "/api/session/new")
	testing.expect_value(t, new_session.status, 200)
	new_body := api_response_text(&new_session)
	testing.expect(t, strings.contains(new_body, `"session_id":null`))
	key_value, has_key := api_json_field(t, new_body, "session_key")
	testing.expect(t, has_key)
	testing.expect(t, strings.has_prefix(key_value.(json.String), WEB_SLOT_PREFIX))

	current3 := api_call(&app, .Get, "/api/session/current")
	testing.expect(t, strings.contains(api_response_text(&current3), `"session_id":null`))
	testing.expect(t, strings.contains(api_response_text(&current3), `"session_key":"web_new_`))

	// 带 session_key 查询时返回对应 session 的运行态，而不是「最近活跃」。
	by_key := api_call(&app, .Get, "/api/session/current", "session_key=ses_abc")
	testing.expect(t, strings.contains(api_response_text(&by_key), `"session_id":"ses_abc"`))
	testing.expect(t, strings.contains(api_response_text(&by_key), `"session_key":"ses_abc"`))

	bad := api_call(&app, .Post, "/api/session/resume", "", `{}`)
	testing.expect_value(t, bad.status, 400)
	testing.expect(t, strings.contains(api_response_text(&bad), `"code":"invalid_request"`))

	malformed := api_call(&app, .Post, "/api/session/resume", "", `not json`)
	testing.expect_value(t, malformed.status, 400)
	testing.expect(t, strings.contains(api_response_text(&malformed), `"code":"invalid_json"`))
}

@(test)
test_api_cwd :: proc(t: ^testing.T) {
	dir := test_temp_dir("api-cwd")
	defer os.remove_all(dir)

	app: App
	api_fixture_setup(t, &app, dir)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	cwd := api_call(&app, .Get, "/api/cwd")
	testing.expect_value(t, cwd.status, 200)
	testing.expect(t, strings.contains(api_response_text(&cwd), `"cwd":`))
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

// 造一个 ap project：真实 root + config_dir/projects/<hash>/path.txt + project 目录。
test_make_project :: proc(t: ^testing.T, config_dir, root: string) -> Project {
	os.make_directory_all(root)
	canonical, canonical_err := canonicalize_path(root, true)
	testing.expect_value(t, canonical_err.message, "")
	project, project_err := open_project(config_dir, canonical)
	testing.expect_value(t, project_err.message, "")
	os.make_directory_all(project.dir)
	test_write_file(fmt.tprintf("%s/path.txt", project.dir), canonical)
	return project
}

// 多工作目录：/api/projects 按 cwd 分组，history/sessions/new 用 cwd 定位
// project，而不是进程级全局目录。
@(test)
test_api_projects_and_cwd_scoped_endpoints :: proc(t: ^testing.T) {
	base := test_temp_dir("api-projects")
	defer os.remove_all(base)

	config_dir := fmt.aprintf("%s/config", base)
	project_a := test_make_project(t, config_dir, fmt.aprintf("%s/a", base))
	project_b := test_make_project(t, config_dir, fmt.aprintf("%s/b", base))

	test_write_file(
		session_file(project_a, "ses_a"),
		`{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_a"}` + "\n" +
		`{"v":1,"seq":1,"ts":2,"type":"turn_start","turn":1}` + "\n",
	)
	test_write_file(
		session_file(project_b, "ses_b"),
		`{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_b"}` + "\n" +
		`{"v":1,"seq":1,"ts":2,"type":"turn_start","turn":1}` + "\n" +
		`{"v":1,"seq":2,"ts":3,"type":"turn_end","turn":1,"stop_reason":"stop"}` + "\n" +
		`{"v":1,"seq":3,"ts":4,"type":"turn_start","turn":2}` + "\n",
	)

	app: App
	api_fixture_setup(t, &app, project_a.root)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)
	app.config_dir = config_dir
	app.project = project_a
	app.cwd = project_a.root

	response := api_call(&app, .Get, "/api/projects")
	testing.expect_value(t, response.status, 200)
	groups: []Api_Project_Entry
	err := json.unmarshal(response.body, &groups, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expectf(t, err == nil, "cannot parse projects response: %v", err)
	testing.expect_value(t, len(groups), 2)

	sessions_by_cwd := make(map[string][]Api_Session_Entry, context.temp_allocator)
	for group in groups {
		sessions_by_cwd[group.cwd] = group.sessions
	}
	testing.expect_value(t, len(sessions_by_cwd[project_a.root]), 1)
	testing.expect_value(t, sessions_by_cwd[project_a.root][0].session_id, "ses_a")
	testing.expect_value(t, len(sessions_by_cwd[project_b.root]), 1)
	testing.expect_value(t, sessions_by_cwd[project_b.root][0].session_id, "ses_b")
	testing.expect_value(t, sessions_by_cwd[project_b.root][0].turns, 2)

	// /api/sessions?cwd= 只返回该目录的会话。
	list_query := fmt.aprintf("cwd=%s", project_b.root, allocator = context.temp_allocator)
	list := api_call(&app, .Get, "/api/sessions", list_query)
	testing.expect_value(t, list.status, 200)
	entries: []Api_Session_Entry
	list_err := json.unmarshal(list.body, &entries, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expectf(t, list_err == nil, "cannot parse sessions response: %v", list_err)
	testing.expect_value(t, len(entries), 1)
	testing.expect_value(t, entries[0].session_id, "ses_b")

	// history 用 cwd 定位 project；不带 cwd 时默认 project 里没有 ses_b。
	history_query := fmt.aprintf(
		"session_id=ses_b&cwd=%s",
		project_b.root,
		allocator = context.temp_allocator,
	)
	history := api_call(&app, .Get, "/api/history", history_query)
	testing.expect_value(t, history.status, 200)
	missing := api_call(&app, .Get, "/api/history", "session_id=ses_b")
	testing.expect_value(t, missing.status, 404)

	// 新 slot 记住自己的 cwd；current 回读同一个目录。
	new_body, marshal_err := json.marshal(
		Api_New_Body{cwd = project_b.root},
		{},
		context.temp_allocator,
	)
	testing.expect(t, marshal_err == nil)
	created := api_call(&app, .Post, "/api/session/new", "", string(new_body))
	testing.expect_value(t, created.status, 200)
	key_value, has_key := api_json_field(t, api_response_text(&created), "session_key")
	testing.expect(t, has_key)
	slot_key := string(key_value.(json.String))
	state := runner_state(&app, slot_key, context.temp_allocator)
	testing.expect_value(t, state.cwd, project_b.root)

	current_query := fmt.aprintf(
		"session_key=%s",
		slot_key,
		allocator = context.temp_allocator,
	)
	current := api_call(&app, .Get, "/api/session/current", current_query)
	testing.expect_value(t, current.status, 200)
	current_cwd, has_current_cwd := api_json_field(t, api_response_text(&current), "cwd")
	testing.expect(t, has_current_cwd)
	testing.expect_value(t, current_cwd.(json.String), json.String(project_b.root))

	// 不存在的 catalog 路径返回 400 invalid_cwd，而不是静默落到默认 project。
	bad := api_call(&app, .Get, "/api/sessions", "cwd=Z:/definitely/not/here")
	testing.expect_value(t, bad.status, 400)
	testing.expect(t, strings.contains(api_response_text(&bad), `"code":"invalid_cwd"`))
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

	text_sha := platform.sha256_hex(transmute([]byte)string(HISTORY_BLOB_TEXT))
	args_sha := platform.sha256_hex(transmute([]byte)string(HISTORY_ARGS_BLOB))
	test_write_file(blob_file(app.project, text_sha), HISTORY_BLOB_TEXT)
	test_write_file(blob_file(app.project, args_sha), HISTORY_ARGS_BLOB)

	big := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 300 {
		fmt.sbprintf(&big, "line-%03d\n", i)
	}
	big_text := strings.to_string(big)
	big_sha := platform.sha256_hex(transmute([]byte)big_text)
	test_write_file(blob_file(app.project, big_sha), big_text)

	missing_sha := strings.repeat("0", 64, context.temp_allocator)

	transcript := strings.concatenate(
		{
			`{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_hist","content_ref":"`,
			text_sha,
			`"}`,
			"\n",
			`{"v":1,"seq":1,"ts":2,"type":"user_message","content":"hi"}`,
			"\n",
			`{"v":1,"seq":2,"ts":3,"type":"message_end","message_id":"m1","role":"assistant","content":[{"type":"text","text_ref":"`,
			text_sha,
			`"},{"type":"text","text_ref":"`,
			missing_sha,
			`","text_preview":"fallback preview"},{"type":"tool_use","id":"call_2","name":"read_file","input_ref":"`,
			args_sha,
			`"},{"type":"tool_use","id":"call_3","name":"write_file","input_ref":"`,
			missing_sha,
			`","input_preview":"partial input"}]}`,
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

	session_start, has_session_start := history_event(history.events, "session_start")
	testing.expect(t, has_session_start)
	session_content, session_content_ok := json_string_field(session_start, "content")
	testing.expect(t, session_content_ok)
	testing.expect_value(t, session_content, HISTORY_BLOB_TEXT)

	message_end, has_message_end := history_event(history.events, "message_end")
	testing.expect(t, has_message_end)
	blocks, blocks_ok := message_end["content"].(json.Array)
	testing.expect(t, blocks_ok)
	if len(blocks) == 4 {
		first, _ := blocks[0].(json.Object)
		text, text_ok := json_string_field(first, "text")
		testing.expect(t, text_ok)
		testing.expect_value(t, text, HISTORY_BLOB_TEXT)

		second, _ := blocks[1].(json.Object)
		fallback, fallback_ok := json_string_field(second, "text")
		testing.expect(t, fallback_ok)
		testing.expect_value(t, fallback, "fallback preview")

		// tool_use 的 input_ref 从 blobs 解析成 JSON，缺失时退化为 input_preview。
		tool_use, tool_use_ok := blocks[2].(json.Object)
		testing.expect(t, tool_use_ok)
		input, input_ok := tool_use["input"].(json.Object)
		testing.expect(t, input_ok)
		file_path, path_ok := json_string_field(input, "file_path")
		testing.expect(t, path_ok)
		testing.expect_value(t, file_path, "x.txt")

		missing_input, missing_input_ok := blocks[3].(json.Object)
		testing.expect(t, missing_input_ok)
		preview_input, preview_input_ok := json_string_field(missing_input, "input")
		testing.expect(t, preview_input_ok)
		testing.expect_value(t, preview_input, "partial input")
	} else {
		testing.expectf(t, false, "expected 4 message_end blocks, got %d", len(blocks))
	}

	tool_start, has_tool_start := history_event(history.events, "tool_execution_start")
	testing.expect(t, has_tool_start)
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
	started_body := api_response_text(&started)
	accepted, has_accepted := api_json_field(t, started_body, "accepted")
	testing.expect(t, has_accepted)
	testing.expect_value(t, accepted.(json.Boolean), json.Boolean(true))
	key_value, has_key := api_json_field(t, started_body, "session_key")
	testing.expect(t, has_key)
	slot_key := string(key_value.(json.String))
	testing.expect(t, strings.has_prefix(slot_key, WEB_SLOT_PREFIX))

	testing.expect(t, test_wait_session(&app, "ses_cancel", 10 * time.Second), "agent did not start")

	current := api_call(&app, .Get, "/api/session/current")
	testing.expect(t, strings.contains(api_response_text(&current), `"running":true`))
	testing.expect(t, strings.contains(api_response_text(&current), `"session_id":"ses_cancel"`))
	testing.expect(t, strings.contains(api_response_text(&current), `"turn":1`))

	// 同一 session 仍然单飞。
	busy_body := strings.concatenate(
		{`{"prompt":"second","session_key":"`, slot_key, `"}`},
		context.temp_allocator,
	)
	busy := api_call(&app, .Post, "/api/turn", "", busy_body)
	testing.expect_value(t, busy.status, 409)
	testing.expect(t, strings.contains(api_response_text(&busy), `"code":"turn_running"`))

	// 切换/恢复另一个 session 不再被别的 session 的运行中 turn 挡住。
	resume := api_call(&app, .Post, "/api/session/resume", "", `{"session_id":"ses_other"}`)
	testing.expect_value(t, resume.status, 200)

	// 不同 session 可以并发跑：第二个 turn 直接启动。
	second := api_call(&app, .Post, "/api/turn", "", `{"prompt":"[scenario:cancel]","session_key":"ses_other"}`)
	testing.expect_value(t, second.status, 202)

	first_cancel := api_call(&app, .Delete, "/api/turn", fmt.aprintf("session_key=%s", slot_key, allocator = context.temp_allocator))
	testing.expect_value(t, first_cancel.status, 202)
	testing.expect_value(t, api_response_text(&first_cancel), `{"cancelled":true}`)
	testing.expect(t, test_wait_key_idle(&app, slot_key, 10 * time.Second), "cancel did not stop turn")
	testing.expect(t, runner_session_running(&app, "ses_other"), "other session must keep running")

	second_cancel := api_call(&app, .Delete, "/api/turn", "session_key=ses_other")
	testing.expect_value(t, second_cancel.status, 202)
	testing.expect_value(t, api_response_text(&second_cancel), `{"cancelled":true}`)
	testing.expect(t, test_wait_runner_idle(&app, 10 * time.Second), "cancel did not stop turn")

	idle_cancel := api_call(&app, .Delete, "/api/turn")
	testing.expect_value(t, idle_cancel.status, 202)
	testing.expect_value(t, api_response_text(&idle_cancel), `{"cancelled":false}`)
}


// 多 session 并发的核心不变量：每个标签页的 SSE 只收到自己 session 的事件，
// 取消也只作用于自己那一轮。
@(test)
test_api_concurrent_sessions_are_isolated :: proc(t: ^testing.T) {
	dir := test_temp_dir("api-concurrent")
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
	key_value, has_key := api_json_field(t, api_response_text(&created), "session_key")
	testing.expect(t, has_key)
	slot_key := string(key_value.(json.String))

	sub_a: Sse_Subscriber
	testing.expect(t, sse_hub_subscribe_topic(&app.hub, &sub_a, slot_key, 512))
	defer sse_hub_unsubscribe(&app.hub, &sub_a)
	sub_b: Sse_Subscriber
	testing.expect(t, sse_hub_subscribe_topic(&app.hub, &sub_b, "ses_other", 512))
	defer sse_hub_unsubscribe(&app.hub, &sub_b)

	first_body := strings.concatenate(
		{`{"prompt":"[scenario:cancel]","session_key":"`, slot_key, `"}`},
		context.temp_allocator,
	)
	first := api_call(&app, .Post, "/api/turn", "", first_body)
	testing.expect_value(t, first.status, 202)

	second := api_call(&app, .Post, "/api/turn", "", `{"prompt":"hello","session_key":"ses_other"}`)
	testing.expect_value(t, second.status, 202)

	testing.expect(t, test_wait_key_idle(&app, "ses_other", 10 * time.Second), "second turn did not finish")
	time.sleep(50 * time.Millisecond)

	b_frames := test_drain_frames(&sub_b)
	defer delete(b_frames)
	testing.expect(t, strings.contains(b_frames, `"type":"turn_end"`))
	testing.expect(t, strings.contains(b_frames, `"exit_code":0`))

	// A 还挂着：它的连接看不到 B 的 turn_end / turn_done。
	a_frames := test_drain_frames(&sub_a)
	defer delete(a_frames)
	testing.expect(t, strings.contains(a_frames, `"text":"working"`))
	testing.expect(t, !strings.contains(a_frames, `"type":"turn_end"`))
	testing.expect(t, !strings.contains(a_frames, "event: turn_done"))

	cancel_query := fmt.aprintf("session_key=%s", slot_key, allocator = context.temp_allocator)
	cancelled := api_call(&app, .Delete, "/api/turn", cancel_query)
	testing.expect_value(t, cancelled.status, 202)
	testing.expect_value(t, api_response_text(&cancelled), `{"cancelled":true}`)
	testing.expect(t, test_wait_key_idle(&app, slot_key, 10 * time.Second), "cancel did not stop turn")

	done_frames := test_drain_frames(&sub_a)
	defer delete(done_frames)
	testing.expect(t, strings.contains(done_frames, "event: turn_done"))
	testing.expect(t, strings.contains(done_frames, `"stop_reason":"cancelled"`))
	testing.expect_value(t, sse_hub_subscriber_count(&app.hub), 2)
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

// 关停时 app_shutdown 必须销毁 hub：阻塞在 recv 上的 SSE 连接线程要立刻被唤醒，
// 否则进程退出会丢下悬挂线程（也解释了前端为什么能靠重连 + history 恢复）。
Sse_Recv_Probe :: struct {
	sub:  ^Sse_Subscriber,
	done: i32,
	got:  i32, // 2 = channel 已关闭
}

sse_test_wait_for_close :: proc(user: rawptr) {
	probe := (^Sse_Recv_Probe)(user)
	_, ok := sse_subscriber_recv(probe.sub)
	sync.atomic_store(&probe.got, 2 if !ok else 1)
	sync.atomic_store(&probe.done, 1)
}

@(test)
test_app_shutdown_wakes_sse_subscribers :: proc(t: ^testing.T) {
	dir := test_temp_dir("api-shutdown-sse")
	defer os.remove_all(dir)

	app: App
	api_fixture_setup(t, &app, dir)

	sub: Sse_Subscriber
	testing.expect(t, sse_hub_subscribe(&app.hub, &sub, 4))

	probe := Sse_Recv_Probe{sub = &sub}
	handle := thread.create_and_start_with_data(
		rawptr(&probe),
		sse_test_wait_for_close,
		name = "sse-shutdown-wait",
	)
	testing.expect(t, handle != nil)
	if handle == nil {
		return
	}
	// 给线程一点时间进入阻塞 recv（没有更可靠的“已阻塞”信号）。
	time.sleep(20 * time.Millisecond)

	app_shutdown(&app)

	start := time.tick_now()
	for sync.atomic_load(&probe.done) == 0 && time.tick_since(start) < 2 * time.Second {
		time.sleep(2 * time.Millisecond)
	}
	done := sync.atomic_load(&probe.done)
	got := sync.atomic_load(&probe.got)
	if done == 0 {
		// 收尾逻辑没唤醒 recv 时，手动关闭 channel，避免测试进程挂死。
		sync_chan.close(sub.frames)
	}
	thread.join(handle)
	thread.destroy(handle)
	sse_hub_unsubscribe(&app.hub, &sub)

	testing.expect_value(t, done, i32(1))
	testing.expect_value(t, got, i32(2))

	// 关停路径必须可重入。
	app_shutdown(&app)
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
