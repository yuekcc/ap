package engine

import "../platform"
import "../tool"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

Fake_Response :: struct {
	text:        string,
	tool_name:   string,
	tool_id:     string,
	tool_input:  json.Value,
	stop:        Stop_Reason,
	usage:       Usage,
	error:       Provider_Error,
	emit_text:   bool,
}

Fake_Provider :: struct {
	responses: []Fake_Response,
	index:     int,
}

fake_provider_state: ^Fake_Provider

fake_provider_call :: proc(
	p: ^Provider,
	req: ^Chat_Message_Request,
	sink: Stream_Sink,
	cancel: ^platform.Cancel_Token,
) -> Provider_Error {
	state := fake_provider_state
	if state == nil || state.index >= len(state.responses) {
		return {kind = .Protocol, message = "fake provider exhausted", retryable = false}
	}
	response := state.responses[state.index]
	state.index += 1
	if response.error.kind != .None {
		return response.error
	}
	message_id := fmt.tprintf("fake-%d", state.index)
	emit_provider_event(sink, Provider_Message_Start{model = "fake", message_id = message_id})
	if len(response.text) > 0 {
		emit_provider_event(sink, Provider_Text_Delta{text = response.text})
	}
	calls := make([dynamic]Assembled_Tool_Call, 0, 1)
	if response.stop == .Tool_Use {
		append(
			&calls,
			Assembled_Tool_Call{id = response.tool_id, name = response.tool_name, input = response.tool_input},
		)
	}
	emit_provider_event(
		sink,
		Provider_Message_End {
			message_id = message_id,
			stop_reason = response.stop,
			usage = response.usage,
			tool_calls = calls[:],
			text = response.text,
		},
	)
	return provider_error_none()
}

LOOP_TEST_IMAGE: string : "\x89PNG\r\n\x1a\n"

loop_test_bash_exec :: proc(user: rawptr, args: json.Value, ctx: ^tool.Tool_Context) -> tool.Tool_Result {
	obj, _ := args.(json.Object)
	command, _ := obj["command"].(json.String)
	text := "hello\n"
	if strings.contains(string(command), "120000") {
		b := strings.builder_make()
		for _ in 0 ..< 120000 {
			strings.write_byte(&b, 'x')
		}
		text = strings.to_string(b)
	}
	if strings.contains(string(command), "return-image") {
		data := make([]byte, len(LOOP_TEST_IMAGE))
		copy(data, transmute([]byte)LOOP_TEST_IMAGE)
		images := make([]tool.Tool_Image, 1)
		images[0] = {
			name      = "pixel.png",
			mime_type = "image/png",
			data      = data,
		}
		return {ok = true, content = "[image pixel.png]", exit_code = 0, images = images}
	}
	return {ok = true, content = text, exit_code = 0}
}

loop_test_write_exec :: proc(user: rawptr, args: json.Value, ctx: ^tool.Tool_Context) -> tool.Tool_Result {
	obj, _ := args.(json.Object)
	path_value, _ := obj["file_path"].(json.String)
	content_value, _ := obj["content"].(json.String)
	_ = os.write_entire_file_from_bytes(string(path_value), transmute([]byte)string(content_value))
	return {ok = true, content = "written"}
}

loop_test_registry :: proc() -> tool.Registry {
	tools := make([]tool.Tool, 2)
	tools[0] = {
		name = "bash",
		description = "bash",
		parameters_json = `{"type":"object"}`,
		execute = loop_test_bash_exec,
	}
	tools[1] = {
		name = "write_file",
		description = "write_file",
		parameters_json = `{"type":"object"}`,
		execute = loop_test_write_exec,
	}
	registry, _ := tool.registry_init(tools)
	return registry
}

loop_test_setup :: proc(t: ^testing.T, name: string) -> (Loop, tool.Tool_Context, string) {
	dir := test_temp_dir(name)
	project, perr := platform.open_project(fmt.tprintf("%s/config", dir), dir)
	testing.expect(t, platform.is_ok(perr))
	settings := new(Settings)
	settings^ = settings_defaults()
	store := new(Transcript_Store)
	store_value, serr := new_transcript_store(project, fmt.tprintf("sess-%s", name), settings)
	store^ = store_value
	testing.expect_value(t, serr.kind, Error_Kind.None)
	h := make_header(store, "session_start")
	start := Session_Start_Event {
		header = h,
		session_id = store.session_id,
		content = "system prompt",
		role = "system",
		cwd = project.root,
		model = "fake",
		provider = PROVIDER_NAME,
		agent_name = "general",
		agent_depth = 0,
	}
	testing.expect_value(t, transcript_append(store, start).kind, Error_Kind.None)
	events, rerr := transcript_read_all(project, store.session_id)
	testing.expect_value(t, rerr.kind, Error_Kind.None)

	cancel := new(platform.Cancel_Token)
	tool_ctx := tool.Tool_Context {
		cwd = dir,
		project = project,
		cancel = cancel,
		session_id = store.session_id,
		agent_name = "general",
	}
	active := make([]string, 2)
	active[0] = "bash"
	active[1] = "write_file"
	loop := loop_init(
		project,
		settings,
		store,
		loop_test_registry(),
		active,
		"fake",
		"general",
		store.session_id,
		0,
		5,
		100,
		cancel,
		events,
		{},
	)
	loop.provider_call = fake_provider_call
	loop.sleep_fn = proc(ms: int) {}
	return loop, tool_ctx, dir
}

loop_test_finish :: proc(l: ^Loop, dir: string) {
	transcript_close(l.store)
	loop_destroy(l)
	test_cleanup(dir)
}

@(test)
test_loop_blobs_large_tool_output :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-blob-output")
	args := make(json.Object)
	// 单行 120KB：不触发 bash 的 2000 行分页，但超过 blob_threshold_bytes。
	args["command"] = json.String("head -c 120000 /dev/zero | tr '\\0' x")
	state := Fake_Provider {
		responses = []Fake_Response {
			{tool_name = "bash", tool_id = "call_out", tool_input = args, stop = .Tool_Use},
			{text = "done", stop = .Stop},
		},
	}
	fake_provider_state = &state
	result := loop_run_turn(&loop, "run big output")
	testing.expect_value(t, result.error_kind, Error_Kind.None)
	events, _ := transcript_read_all(loop.project, loop.session_id)
	found_ref := false
	found_size := 0
	for ev in events {
		if ev.type != "tool_execution_end" {
			continue
		}
		end: Tool_Execution_End_Event
		json.unmarshal_string(ev.line, &end)
		if ref, ok := end.content_ref.?; ok {
			found_ref = true
			data, berr := blob_read(loop.project, ref)
			testing.expect_value(t, berr.kind, Error_Kind.None)
			found_size = len(data)
		}
	}
	testing.expect(t, found_ref)
	testing.expect(t, found_size > 100000)
	loop_test_finish(&loop, dir)
}

@(test)
test_loop_persists_tool_images :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-image")
	args := make(json.Object)
	args["command"] = json.String("return-image")
	state := Fake_Provider {
		responses = []Fake_Response {
			{tool_name = "bash", tool_id = "call_image", tool_input = args, stop = .Tool_Use},
			{text = "done", stop = .Stop},
		},
	}
	fake_provider_state = &state
	result := loop_run_turn(&loop, "read an image")
	testing.expect_value(t, result.fatal_error, "")
	testing.expect_value(t, result.error_kind, Error_Kind.None)

	events, _ := transcript_read_all(loop.project, loop.session_id)
	found := false
	for ev in events {
		if ev.type != "tool_execution_end" {
			continue
		}
		end: Tool_Execution_End_Event
		json.unmarshal_string(ev.line, &end)
		if len(end.images) != 1 {
			continue
		}
		found = true
		testing.expect_value(t, end.images[0].mime_type, "image/png")
		testing.expect_value(t, end.images[0].name, "pixel.png")
		data, berr := blob_read(loop.project, end.images[0].ref)
		testing.expect_value(t, berr.kind, Error_Kind.None)
		testing.expect_value(t, len(data), 8)
		delete(data)
	}
	testing.expect(t, found)

	messages, merr := project_messages(loop.project, events)
	testing.expect_value(t, merr.kind, Error_Kind.None)
	found_message := false
	for msg in messages {
		if len(msg.images) == 1 {
			found_message = true
			testing.expect_value(t, len(msg.images[0].data), 8)
		}
	}
	testing.expect(t, found_message)
	loop_test_finish(&loop, dir)
}

@(test)
test_loop_blobs_large_tool_input :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-blob-input")
	target := fmt.tprintf("%s/big.txt", dir)
	big := strings.repeat("z", 120000)
	args := make(json.Object)
	args["file_path"] = json.String(target)
	args["content"] = json.String(big)
	state := Fake_Provider {
		responses = []Fake_Response {
			{tool_name = "write_file", tool_id = "call_big", tool_input = args, stop = .Tool_Use},
			{text = "done", stop = .Stop},
		},
	}
	fake_provider_state = &state
	result := loop_run_turn(&loop, "write big")
	testing.expect_value(t, result.error_kind, Error_Kind.None)
	testing.expect(t, os.exists(target))
	info, serr := os.stat(target, context.allocator)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, info.size, i64(len(big)))

	events, _ := transcript_read_all(loop.project, loop.session_id)
	found_input_ref := false
	found_start_ref := false
	for ev in events {
		if ev.type == "message_end" {
			msg: Message_End_Event
			json.unmarshal_string(ev.line, &msg)
			for block in msg.content {
				if block.type == "tool_use" && block.input_ref != nil {
					found_input_ref = true
				}
			}
		}
		if ev.type == "tool_execution_start" {
			start: Tool_Execution_Start_Event
			json.unmarshal_string(ev.line, &start)
			if start.args_ref != nil {
				found_start_ref = true
			}
		}
	}
	testing.expect(t, found_input_ref)
	testing.expect(t, found_start_ref)
	loop_test_finish(&loop, dir)
}

@(test)
test_loop_text_stop :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-text")
	state := Fake_Provider {
		responses = []Fake_Response{{text = "hello", stop = .Stop, usage = Usage{input_tokens = 3, output_tokens = 2}}},
	}
	fake_provider_state = &state
	result := loop_run_turn(&loop, "hi")
	testing.expect_value(t, result.error_kind, Error_Kind.None)
	testing.expect_value(t, result.stop_reason, "stop")
	testing.expect_value(t, result.result_text, "hello")
	testing.expect_value(t, result.num_steps, 1)
	testing.expect_value(t, result.usage.input_tokens.?, 3)

	events, _ := transcript_read_all(loop.project, loop.session_id)
	types := make([dynamic]string, 0, len(events))
	for ev in events {
		append(&types, ev.type)
	}
	testing.expect_value(t, len(events), 7)
	testing.expect_value(t, types[0], "session_start")
	testing.expect_value(t, types[1], "user_message")
	testing.expect_value(t, types[2], "turn_start")
	testing.expect_value(t, types[3], "step_start")
	testing.expect_value(t, types[4], "message_start")
	testing.expect_value(t, types[5], "message_end")
	testing.expect_value(t, types[6], "turn_end")
	loop_test_finish(&loop, dir)
}

@(test)
test_loop_tool_use_then_stop :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-tool")
	target := fmt.tprintf("%s/note.txt", dir)
	args := make(json.Object)
	args["file_path"] = json.String(target)
	args["content"] = json.String("written by tool")
	state := Fake_Provider {
		responses = []Fake_Response {
			{
				tool_name = "write_file",
				tool_id = "call_1",
				tool_input = args,
				stop = .Tool_Use,
			},
			{text = "done", stop = .Stop},
		},
	}
	fake_provider_state = &state
	result := loop_run_turn(&loop, "write a file")
	testing.expect_value(t, result.error_kind, Error_Kind.None)
	testing.expect_value(t, result.stop_reason, "stop")
	testing.expect_value(t, result.result_text, "done")
	testing.expect_value(t, result.num_steps, 2)
	testing.expect(t, os.exists(target))
	testing.expect_value(t, test_read_file(target), "written by tool")

	events, _ := transcript_read_all(loop.project, loop.session_id)
	has_start := false
	has_end := false
	for ev in events {
		if ev.type == "tool_execution_start" do has_start = true
		if ev.type == "tool_execution_end" do has_end = true
	}
	testing.expect(t, has_start)
	testing.expect(t, has_end)

	messages, merr := project_messages(loop.project, events)
	testing.expect_value(t, merr.kind, Error_Kind.None)
	testing.expect_value(t, len(messages), 4)
	testing.expect_value(t, messages[1].tool_calls[0].id, "call_1")
	testing.expect_value(t, messages[2].role, "tool")
	testing.expect_value(t, messages[3].content.?, "done")
	loop_test_finish(&loop, dir)
}

@(test)
test_loop_max_steps :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-max")
	loop.max_steps = 2
	target := fmt.tprintf("%s/note.txt", dir)
	args := make(json.Object)
	args["file_path"] = json.String(target)
	args["content"] = json.String("x")
	state := Fake_Provider {
		responses = []Fake_Response {
			{tool_name = "write_file", tool_id = "c1", tool_input = args, stop = .Tool_Use},
			{tool_name = "write_file", tool_id = "c2", tool_input = args, stop = .Tool_Use},
		},
	}
	fake_provider_state = &state
	result := loop_run_turn(&loop, "loop")
	testing.expect_value(t, result.error_kind, Error_Kind.None)
	testing.expect_value(t, result.stop_reason, "max_steps")
	testing.expect_value(t, result.num_steps, 2)
	events, _ := transcript_read_all(loop.project, loop.session_id)
	last := events[len(events) - 1]
	testing.expect_value(t, last.type, "turn_end")
	loop_test_finish(&loop, dir)
}

@(test)
test_loop_retry_then_success :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-retry")
	state := Fake_Provider {
		responses = []Fake_Response {
			{error = Provider_Error{kind = .Network, message = "flaky", retryable = true}},
			{text = "recovered", stop = .Stop},
		},
	}
	fake_provider_state = &state
	result := loop_run_turn(&loop, "retry")
	testing.expect_value(t, result.error_kind, Error_Kind.None)
	testing.expect_value(t, result.result_text, "recovered")
	events, _ := transcript_read_all(loop.project, loop.session_id)
	error_count := 0
	step_count := 0
	for ev in events {
		if ev.type == "error" do error_count += 1
		if ev.type == "step_start" do step_count += 1
	}
	testing.expect_value(t, error_count, 1)
	testing.expect_value(t, step_count, 1)
	loop_test_finish(&loop, dir)
}

// 不允许交接时（--no-handoff，或子代理的 agent_depth > 0）维持现状：
// 写 error、写 turn_end(context_too_long)、按 provider 错误结束。
@(test)
test_loop_context_too_long_without_handoff :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-ctx")
	loop.handoff_enabled = false
	state := Fake_Provider {
		responses = []Fake_Response {
			{error = Provider_Error{kind = .Context_Too_Long, message = "too long", retryable = false}},
		},
	}
	fake_provider_state = &state
	result := loop_run_turn(&loop, "big")
	testing.expect_value(t, result.error_kind, Error_Kind.Provider)
	events, _ := transcript_read_all(loop.project, loop.session_id)
	last := events[len(events) - 1]
	testing.expect_value(t, last.type, "turn_end")
	end: Turn_End_Event
	json.unmarshal_string(last.line, &end)
	testing.expect_value(t, end.stop_reason, "context_too_long")
	loop_test_finish(&loop, dir)
}

// 估算失误不该直接放弃：第一次超限时收紧预算重发同一 step，
// 不写 error、不增加 step、不写 turn_end。
@(test)
test_loop_context_too_long_corrects_then_succeeds :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-ctx-fix")
	state := Fake_Provider {
		responses = []Fake_Response {
			{error = Provider_Error{kind = .Context_Too_Long, message = "too long", retryable = false}},
			{text = "recovered", stop = .Stop},
		},
	}
	fake_provider_state = &state
	result := loop_run_turn(&loop, "big")
	testing.expect_value(t, result.error_kind, Error_Kind.None)
	testing.expect_value(t, result.stop_reason, "stop")
	testing.expect_value(t, result.result_text, "recovered")
	testing.expect_value(t, result.num_steps, 1)
	events, _ := transcript_read_all(loop.project, loop.session_id)
	error_count := 0
	step_count := 0
	for ev in events {
		if ev.type == "error" do error_count += 1
		if ev.type == "step_start" do step_count += 1
	}
	testing.expect_value(t, error_count, 0)
	testing.expect_value(t, step_count, 1)
	loop_test_finish(&loop, dir)
}

// 第二次仍超限就生成交接文档：写 handoff 事件，stop_reason 变 handoff。
@(test)
test_loop_context_too_long_twice_triggers_handoff :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-ctx-handoff")
	state := Fake_Provider {
		responses = []Fake_Response {
			{error = Provider_Error{kind = .Context_Too_Long, message = "too long", retryable = false}},
			{error = Provider_Error{kind = .Context_Too_Long, message = "still too long", retryable = false}},
			{text = "handoff doc body", stop = .Stop, usage = Usage{input_tokens = 11, output_tokens = 7}},
		},
	}
	fake_provider_state = &state
	result := loop_run_turn(&loop, "big")
	testing.expect_value(t, result.error_kind, Error_Kind.None)
	testing.expect_value(t, result.stop_reason, "handoff")
	testing.expect_value(t, result.handoff_content, "handoff doc body")
	testing.expect_value(t, result.handoff_reason, "context_too_long")

	events, _ := transcript_read_all(loop.project, loop.session_id)
	handoffs := make([dynamic]Handoff_Event, 0, 1)
	for ev in events {
		if ev.type != "handoff" {
			continue
		}
		handoff: Handoff_Event
		json.unmarshal_string(ev.line, &handoff)
		append(&handoffs, handoff)
	}
	testing.expect_value(t, len(handoffs), 1)
	testing.expect_value(t, handoffs[0].reason, "context_too_long")
	testing.expect_value(t, handoffs[0].content, "handoff doc body")
	testing.expect(t, handoffs[0].source_events > 0)
	testing.expect_value(t, handoffs[0].usage.?.input_tokens.?, 11)

	last := events[len(events) - 1]
	testing.expect_value(t, last.type, "turn_end")
	end: Turn_End_Event
	json.unmarshal_string(last.line, &end)
	testing.expect_value(t, end.stop_reason, "handoff")
	loop_test_finish(&loop, dir)
}

// 交接调用的失败退回现状：error + turn_end(context_too_long)。
@(test)
test_loop_handoff_failure_falls_back :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-ctx-handoff-fail")
	state := Fake_Provider {
		responses = []Fake_Response {
			{error = Provider_Error{kind = .Context_Too_Long, message = "too long", retryable = false}},
			{error = Provider_Error{kind = .Context_Too_Long, message = "still too long", retryable = false}},
			// 交接调用返回空文本，视为失败。
			{text = "", stop = .Stop},
		},
	}
	fake_provider_state = &state
	result := loop_run_turn(&loop, "big")
	testing.expect_value(t, result.error_kind, Error_Kind.Provider)
	testing.expect_value(t, result.stop_reason, "context_too_long")
	events, _ := transcript_read_all(loop.project, loop.session_id)
	has_error := false
	has_handoff := false
	for ev in events {
		if ev.type == "error" do has_error = true
		if ev.type == "handoff" do has_handoff = true
	}
	testing.expect(t, has_error)
	testing.expect(t, !has_handoff)
	last := events[len(events) - 1]
	testing.expect_value(t, last.type, "turn_end")
	loop_test_finish(&loop, dir)
}

@(test)
test_loop_cancel_mid_stream :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-cancel")
	platform.cancel_token_cancel(loop.cancel)
	state := Fake_Provider{responses = []Fake_Response{{text = "partial", stop = .Stop}}}
	fake_provider_state = &state
	result := loop_run_turn(&loop, "cancel")
	testing.expect(t, result.cancelled)
	testing.expect_value(t, result.stop_reason, "cancelled")
	events, _ := transcript_read_all(loop.project, loop.session_id)
	// 取消时 fake provider 的事件不会执行（loop 在调用模型前检查 token）。
	last := events[len(events) - 1]
	testing.expect_value(t, last.type, "turn_end")
	loop_test_finish(&loop, dir)
}

Progress_Capture :: struct {
	styles: [dynamic]Progress_Style,
	lines:  [dynamic]string,
}

capture_progress :: proc(user: rawptr, style: Progress_Style, line: string) {
	capture := (^Progress_Capture)(user)
	append(&capture.styles, style)
	append(&capture.lines, line)
}

@(test)
test_loop_progress_uses_markdown_headings :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-progress")
	args := make(json.Object)
	args["command"] = json.String("echo hi")
	state := Fake_Provider {
		responses = []Fake_Response {
			{tool_name = "bash", tool_id = "call_prog", tool_input = args, stop = .Tool_Use},
			{text = "done", stop = .Stop},
		},
	}
	fake_provider_state = &state
	capture := Progress_Capture{}
	loop.emitter = Emitter{user = &capture, on_progress = capture_progress}
	result := loop_run_turn(&loop, "run echo")
	testing.expect_value(t, result.error_kind, Error_Kind.None)

	// step 用二级标题，tool 用三级标题，工具耗时单独成块。
	testing.expect_value(t, len(capture.lines), 4)
	testing.expect_value(t, capture.lines[0], "## Step 1")
	testing.expect_value(t, capture.lines[1], "### bash")
	testing.expect(t, strings.has_prefix(capture.lines[2], "_bash ok ("))
	testing.expect_value(t, capture.lines[3], "## Step 2")
	for style in capture.styles {
		testing.expect_value(t, style, Progress_Style.Block)
	}
	delete(capture.styles)
	delete(capture.lines)
	loop_test_finish(&loop, dir)
}

// turn_end.context 只在开启预算时出现；关闭预算时整个字段是 null。
@(test)
test_loop_turn_end_context_observation :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-ctx-observe")
	state := Fake_Provider {
		responses = []Fake_Response{{text = "hi", stop = .Stop, usage = Usage{input_tokens = 12}}},
	}
	fake_provider_state = &state
	result := loop_run_turn(&loop, "hi")
	testing.expect_value(t, result.error_kind, Error_Kind.None)
	events, _ := transcript_read_all(loop.project, loop.session_id)
	end: Turn_End_Event
	json.unmarshal_string(events[len(events) - 1].line, &end)
	observation, has_observation := end.context_info.?
	testing.expect(t, has_observation)
	testing.expect(t, observation.estimated_tokens > 0)
	testing.expect_value(t, observation.limit_tokens, context_budget_target(loop.settings, loop.max_tokens))
	testing.expect_value(t, observation.elided_results, 0)
	loop_test_finish(&loop, dir)
}

@(test)
test_loop_turn_end_context_null_when_budget_disabled :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-ctx-off")
	loop.settings.context_window_tokens = 0
	state := Fake_Provider{responses = []Fake_Response{{text = "hi", stop = .Stop}}}
	fake_provider_state = &state
	result := loop_run_turn(&loop, "hi")
	testing.expect_value(t, result.error_kind, Error_Kind.None)
	events, _ := transcript_read_all(loop.project, loop.session_id)
	end: Turn_End_Event
	json.unmarshal_string(events[len(events) - 1].line, &end)
	_, has_observation := end.context_info.?
	testing.expect(t, !has_observation)
	loop_test_finish(&loop, dir)
}

// 每一次成功响应都用真实的 input_tokens 校准下一次估算，比例钳制在
// [50, 200]。estimate 与 observed 的比值由 provider 决定，这里让 provider
// 报一个远大于本地估算的 input_tokens，确认比例被压到上限。
@(test)
test_loop_calibration_from_usage :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-calibration")
	args := make(json.Object)
	args["command"] = json.String("echo hi")
	state := Fake_Provider {
		responses = []Fake_Response {
			{
				tool_name = "bash",
				tool_id = "c1",
				tool_input = args,
				stop = .Tool_Use,
				usage = Usage{input_tokens = 900000},
			},
			{text = "done", stop = .Stop},
		},
	}
	fake_provider_state = &state
	result := loop_run_turn(&loop, "hi")
	testing.expect_value(t, result.error_kind, Error_Kind.None)
	// 第二步才会用到第一步的观测值。
	testing.expect_value(t, loop.calibration_percent, CALIBRATION_MAX_PERCENT)
	loop_test_finish(&loop, dir)
}

// 交接调用的用量计入 session 汇总：manual handoff 没有 turn，只能靠 handoff 事件。
@(test)
test_historical_usage_counts_handoff :: proc(t: ^testing.T) {
	events := []Event {
		test_event("turn_end", `{"type":"turn_end","turn":1,"stop_reason":"stop","usage":{"input_tokens":3}}`),
		test_event(
			"handoff",
			`{"type":"handoff","reason":"manual","content":"doc","usage":{"input_tokens":11,"output_tokens":7},"source_events":2}`,
		),
	}
	total := historical_usage_from_events(events)
	testing.expect_value(t, total.input_tokens.?, 14)
	testing.expect_value(t, total.output_tokens.?, 7)
}
