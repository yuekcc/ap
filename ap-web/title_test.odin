package apweb

import client "../ap-core/client"
import protocol "../ap-core/protocol"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// ---- /api/sessions 带标题 ----

@(test)
test_sessions_include_generated_title :: proc(t: ^testing.T) {
	base := test_temp_dir("api-title")
	defer os.remove_all(base)
	config_dir := fmt.aprintf("%s/config", base)
	project := test_make_project(t, config_dir, fmt.aprintf("%s/work", base))

	test_write_file(
		client.session_file(project, "ses_titled"),
		`{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_titled"}` + "\n" +
		`{"v":1,"seq":1,"ts":2,"type":"turn_start","turn":1}` + "\n" +
		`{"v":1,"seq":2,"ts":3,"type":"session_title","title":"旧标题"}` + "\n" +
		`{"v":1,"seq":3,"ts":4,"type":"session_title","title":"新标题"}` + "\n",
	)

	app: App
	api_fixture_setup(t, &app, project.root)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)
	app.config_dir = config_dir
	app.project = project
	app.cwd = project.root

	query := fmt.aprintf("cwd=%s", project.root, allocator = context.temp_allocator)
	response := api_call(&app, .Get, "/api/sessions", query)
	testing.expect_value(t, response.status, 200)
	entries: []Api_Session_Entry
	err := json.unmarshal(response.body, &entries, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expectf(t, err == nil, "cannot parse sessions response: %v", err)
	testing.expect_value(t, len(entries), 1)
	testing.expect_value(t, entries[0].title, "新标题")
	testing.expect_value(t, entries[0].turns, 1)
}

// ---- 人工刷新标题 ----

@(test)
test_api_session_title_runs_agent_bin :: proc(t: ^testing.T) {
	base := test_temp_dir("api-title-refresh")
	defer os.remove_all(base)

	app: App
	runner_test_setup(t, &app, base)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)
	api_register_routes()

	// 子进程的泵会 free_all(temp)，这个 key 要活到断言之后。
	key := strings.clone(runner_session_resume(&app, "ses_title", base), context.allocator)
	defer delete(key, context.allocator)
	request_body, marshal_err := json.marshal(
		Api_Title_Body{session_key = key},
		{},
		context.temp_allocator,
	)
	testing.expect(t, marshal_err == nil)
	response := api_call(&app, .Post, "/api/session/title", "", string(request_body))
	testing.expectf(
		t,
		response.status == 200,
		"body=%s response=%s",
		string(request_body),
		string(response.body),
	)

	payload: Api_Session_Title
	err := json.unmarshal(response.body, &payload, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expectf(t, err == nil, "cannot parse title response: %v", err)
	testing.expect_value(t, payload.title, "假标题")
	testing.expect_value(t, payload.session_key, key)
}

@(test)
test_api_session_title_without_transcript_is_409 :: proc(t: ^testing.T) {
	base := test_temp_dir("api-title-empty")
	defer os.remove_all(base)

	app: App
	runner_test_setup(t, &app, base)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)
	api_register_routes()

	// 新 slot 还没有真实 session id：没有 transcript 可读。
	key := runner_session_new(&app, base, context.temp_allocator)
	request_body, marshal_err := json.marshal(
		Api_Title_Body{session_key = key},
		{},
		context.temp_allocator,
	)
	testing.expect(t, marshal_err == nil)
	response := api_call(&app, .Post, "/api/session/title", "", string(request_body))
	testing.expectf(
		t,
		response.status == 409,
		"body=%s response=%s",
		string(request_body),
		string(response.body),
	)

	envelope: Api_Error_Envelope
	err := json.unmarshal(response.body, &envelope, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	testing.expectf(t, err == nil, "cannot parse error response: %v", err)
	testing.expect_value(t, envelope.error.code, "title_unavailable")
}

// ---- 首轮后自动生成 ----

@(test)
test_runner_auto_title_only_after_first_stop :: proc(t: ^testing.T) {
	base := test_temp_dir("auto-title")
	defer os.remove_all(base)
	config_dir := fmt.aprintf("%s/config", base)
	project := test_make_project(t, config_dir, fmt.aprintf("%s/work", base))

	app: App
	app.config_dir = config_dir
	app.cwd = project.root

	job := Turn_Job {
		app         = &app,
		session_id  = "ses_auto",
		turn        = 1,
		stop_reason = protocol.STOP_REASON_STOP,
	}
	job.options.cwd = project.root

	// 没有 transcript：读不到就不猜，避免对测试替身发无谓的模型调用。
	testing.expect(t, !runner_should_auto_title(&app, &job))

	transcript := proc(extra: string) -> string {
		return fmt.tprintf(
			`{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_auto"}
{"v":1,"seq":1,"ts":2,"type":"turn_start","turn":1}
{"v":1,"seq":2,"ts":3,"type":"turn_end","turn":1,"stop_reason":"stop"}
%s`,
			extra,
		)
	}
	path := client.session_file(project, "ses_auto")
	test_write_file(path, transcript(""))
	testing.expect(t, runner_should_auto_title(&app, &job))

	// 已经有标题就不再自动覆盖。
	test_write_file(
		path,
		transcript(`{"v":1,"seq":3,"ts":4,"type":"session_title","title":"写好的标题"}` + "\n"),
	)
	testing.expect(t, !runner_should_auto_title(&app, &job))

	// 不是首轮、或不是正常 stop，都不自动生成。
	test_write_file(path, transcript(""))
	job.turn = 2
	testing.expect(t, !runner_should_auto_title(&app, &job))
	job.turn = 1
	job.stop_reason = protocol.STOP_REASON_CANCELLED
	testing.expect(t, !runner_should_auto_title(&app, &job))
}
