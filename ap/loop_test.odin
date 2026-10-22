package ap

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
	cancel: ^Cancel_Token,
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

loop_test_setup :: proc(t: ^testing.T, name: string) -> (Loop, Tool_Context, string) {
	dir := test_temp_dir(name)
	project, perr := open_project(fmt.tprintf("%s/config", dir), dir)
	testing.expect_value(t, perr.code, Exit_Code.OK)
	settings := new(Settings)
	settings^ = settings_defaults()
	store := new(Transcript_Store)
	store_value, serr := new_transcript_store(project, fmt.tprintf("sess-%s", name), settings)
	store^ = store_value
	testing.expect_value(t, serr.code, Exit_Code.OK)
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
	testing.expect_value(t, transcript_append(store, start).code, Exit_Code.OK)
	events, rerr := transcript_read_all(project, store.session_id)
	testing.expect_value(t, rerr.code, Exit_Code.OK)

	bash, _ := find_bash()
	agent := agent_default_general()
	cancel := new(Cancel_Token)
	tool_ctx := Tool_Context {
		cwd = dir,
		project = project,
		settings = settings,
		cancel = cancel,
		session_id = store.session_id,
		agent_name = "general",
		config_dir = fmt.tprintf("%s/config", dir),
		bash_path = bash,
		model = "fake",
		max_steps = 5,
	}
	loop := loop_init(
		project,
		settings,
		store,
		agent,
		"fake",
		fmt.tprintf("%s/config", dir),
		"",
		bash,
		store.session_id,
		0,
		1,
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
	testing.expect_value(t, result.exit_code, Exit_Code.OK)
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
			testing.expect_value(t, berr.code, Exit_Code.OK)
			found_size = len(data)
		}
	}
	testing.expect(t, found_ref)
	testing.expect(t, found_size > 100000)
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
	testing.expect_value(t, result.exit_code, Exit_Code.OK)
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
	testing.expect_value(t, result.exit_code, Exit_Code.OK)
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
	testing.expect_value(t, result.exit_code, Exit_Code.OK)
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
	testing.expect_value(t, merr.code, Exit_Code.OK)
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
	testing.expect_value(t, result.exit_code, Exit_Code.OK)
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
	testing.expect_value(t, result.exit_code, Exit_Code.OK)
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

@(test)
test_loop_context_too_long :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-ctx")
	state := Fake_Provider {
		responses = []Fake_Response {
			{error = Provider_Error{kind = .Context_Too_Long, message = "too long", retryable = false}},
		},
	}
	fake_provider_state = &state
	result := loop_run_turn(&loop, "big")
	testing.expect_value(t, result.exit_code, Exit_Code.Provider)
	events, _ := transcript_read_all(loop.project, loop.session_id)
	last := events[len(events) - 1]
	testing.expect_value(t, last.type, "turn_end")
	end: Turn_End_Event
	json.unmarshal_string(last.line, &end)
	testing.expect_value(t, end.stop_reason, "context_too_long")
	loop_test_finish(&loop, dir)
}

@(test)
test_loop_cancel_mid_stream :: proc(t: ^testing.T) {
	loop, _, dir := loop_test_setup(t, "loop-cancel")
	cancel_token_cancel(loop.cancel)
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
