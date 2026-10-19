package ap

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

test_event :: proc(typ, line: string) -> Event {
	return Event{v = 1, type = typ, line = line}
}

@(test)
test_project_messages_basic :: proc(t: ^testing.T) {
	project, _, dir := test_project_and_settings(t, "ctx-basic")
	defer test_cleanup(dir)

	events := []Event {
		test_event("user_message", `{"v":1,"seq":0,"ts":0,"type":"user_message","content":"hi"}`),
		test_event(
			"message_end",
			`{"v":1,"seq":1,"ts":0,"type":"message_end","message_id":"m1","role":"assistant","content":[{"type":"text","text":"hello"},{"type":"tool_use","id":"call_1","name":"read_file","input":{"file_path":"a.txt"}}],"stop_reason":"tool_use","usage":null,"reasoning":null}`,
		),
		test_event(
			"tool_execution_end",
			`{"v":1,"seq":2,"ts":0,"type":"tool_execution_end","tool_call_id":"call_1","ok":true,"content":"file contents","error":null,"duration_ms":1,"exit_code":null,"metadata":null}`,
		),
		test_event(
			"message_end",
			`{"v":1,"seq":3,"ts":0,"type":"message_end","message_id":"m2","role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"stop","usage":null,"reasoning":null}`,
		),
	}
	messages, err := project_messages(project, events)
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, len(messages), 4)
	testing.expect_value(t, messages[0].role, "user")
	testing.expect_value(t, messages[0].content.?, "hi")
	testing.expect_value(t, messages[1].role, "assistant")
	testing.expect_value(t, messages[1].content.?, "hello")
	testing.expect_value(t, len(messages[1].tool_calls), 1)
	testing.expect_value(t, messages[1].tool_calls[0].id, "call_1")
	testing.expect_value(t, messages[1].tool_calls[0].function.name, "read_file")
	testing.expect_value(t, messages[1].tool_calls[0].function.arguments, `{"file_path":"a.txt"}`)
	testing.expect_value(t, messages[2].role, "tool")
	testing.expect_value(t, messages[2].tool_call_id.?, "call_1")
	testing.expect_value(t, messages[2].content.?, "file contents")
	testing.expect_value(t, messages[3].content.?, "done")
}

@(test)
test_project_messages_drops_unpaired_tool_use :: proc(t: ^testing.T) {
	project, _, dir := test_project_and_settings(t, "ctx-unpaired")
	defer test_cleanup(dir)
	events := []Event {
		test_event("user_message", `{"type":"user_message","content":"hi"}`),
		test_event(
			"message_end",
			`{"type":"message_end","message_id":"m1","role":"assistant","content":[{"type":"tool_use","id":"call_x","name":"bash","input":{"command":"ls"}}],"stop_reason":"tool_use"}`,
		),
		test_event(
			"message_end",
			`{"type":"message_end","message_id":"m2","role":"assistant","content":[{"type":"text","text":"keep"},{"type":"tool_use","id":"call_y","name":"bash","input":{"command":"pwd"}}],"stop_reason":"tool_use"}`,
		),
		test_event(
			"tool_execution_end",
			`{"type":"tool_execution_end","tool_call_id":"orphan","ok":true,"content":"orphan"}`,
		),
	}
	messages, err := project_messages(project, events)
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, len(messages), 2)
	testing.expect_value(t, messages[1].role, "assistant")
	testing.expect_value(t, messages[1].content.?, "keep")
	testing.expect_value(t, len(messages[1].tool_calls), 0)
}

@(test)
test_project_messages_drops_cancelled_and_empty :: proc(t: ^testing.T) {
	project, _, dir := test_project_and_settings(t, "ctx-cancel")
	defer test_cleanup(dir)
	events := []Event {
		test_event("user_message", `{"type":"user_message","content":"hi"}`),
		test_event(
			"message_end",
			`{"type":"message_end","message_id":"m1","role":"assistant","content":[{"type":"text","text":"half"}],"stop_reason":"cancelled"}`,
		),
		test_event(
			"message_end",
			`{"type":"message_end","message_id":"m2","role":"assistant","content":[],"stop_reason":"stop"}`,
		),
		test_event("message_start", `{"type":"message_start","message_id":"m3","role":"assistant"}`),
	}
	messages, err := project_messages(project, events)
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, len(messages), 1)
	testing.expect_value(t, messages[0].role, "user")
}

@(test)
test_project_messages_merges_consecutive_user :: proc(t: ^testing.T) {
	project, _, dir := test_project_and_settings(t, "ctx-merge")
	defer test_cleanup(dir)
	events := []Event {
		test_event("user_message", `{"type":"user_message","content":"one"}`),
		test_event("user_message", `{"type":"user_message","content":"two"}`),
		test_event(
			"message_end",
			`{"type":"message_end","message_id":"m1","role":"assistant","content":[{"type":"text","text":"a"}],"stop_reason":"stop"}`,
		),
		test_event(
			"message_end",
			`{"type":"message_end","message_id":"m2","role":"assistant","content":[{"type":"text","text":"b"}],"stop_reason":"stop"}`,
		),
	}
	messages, _ := project_messages(project, events)
	testing.expect_value(t, len(messages), 2)
	testing.expect_value(t, messages[0].content.?, "one\ntwo")
	testing.expect_value(t, messages[1].content.?, "a\nb")
}

@(test)
test_project_messages_resolves_blobs :: proc(t: ^testing.T) {
	project, _, dir := test_project_and_settings(t, "ctx-blob")
	defer test_cleanup(dir)
	input_sha, _ := blob_write(project, transmute([]byte)string(`{"file_path":"blob.txt"}`))
	output_sha, _ := blob_write(project, transmute([]byte)string("full output from blob"))
	events := []Event {
		test_event("user_message", `{"type":"user_message","content":"hi"}`),
		test_event(
			"message_end",
			json_concat(
				`{"type":"message_end","message_id":"m1","role":"assistant","content":[{"type":"tool_use","id":"call_1","name":"read_file","input_ref":"`,
				input_sha,
				`","input_bytes":24,"input_preview":"..."}],"stop_reason":"tool_use"}`,
			),
		),
		test_event(
			"tool_execution_end",
			json_concat(
				`{"type":"tool_execution_end","tool_call_id":"call_1","ok":true,"content":"","content_ref":"`,
				output_sha,
				`","content_bytes":21,"content_preview":"..."}`,
			),
		),
	}
	messages, err := project_messages(project, events)
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, len(messages), 3)
	testing.expect_value(t, messages[1].tool_calls[0].function.arguments, `{"file_path":"blob.txt"}`)
	testing.expect_value(t, messages[2].content.?, "full output from blob")
}

@(test)
test_project_messages_missing_blob_fails :: proc(t: ^testing.T) {
	project, _, dir := test_project_and_settings(t, "ctx-missing-blob")
	defer test_cleanup(dir)
	missing := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	events := []Event {
		test_event(
			"tool_execution_end",
			json_concat(
				`{"type":"tool_execution_end","tool_call_id":"call_1","ok":true,"content_ref":"`,
				missing,
				`"}`,
			),
		),
		// 没有对应 tool_use 时孤立结果会被丢弃，不触发 blob 读取；这里补一条配对消息。
		test_event(
			"message_end",
			`{"type":"message_end","message_id":"m1","role":"assistant","content":[{"type":"tool_use","id":"call_1","name":"bash","input":{"command":"x"}}],"stop_reason":"tool_use"}`,
		),
	}
	_, err := project_messages(project, events)
	testing.expect_value(t, err.code, Exit_Code.Usage)
}

@(test)
test_project_messages_replay_is_byte_identical :: proc(t: ^testing.T) {
	project, _, dir := test_project_and_settings(t, "ctx-replay")
	defer test_cleanup(dir)
	events := []Event {
		test_event("user_message", `{"type":"user_message","content":"hi"}`),
		test_event(
			"message_end",
			`{"type":"message_end","message_id":"m1","role":"assistant","content":[{"type":"text","text":"hello"},{"type":"tool_use","id":"call_1","name":"read_file","input":{"z":1,"a":{"b":2}}}],"stop_reason":"tool_use"}`,
		),
		test_event(
			"tool_execution_end",
			`{"type":"tool_execution_end","tool_call_id":"call_1","ok":true,"content":"ok"}`,
		),
	}
	a, err := project_messages(project, events)
	testing.expect_value(t, err.code, Exit_Code.OK)
	b, _ := project_messages(project, events)
	testing.expect_value(t, string(messages_bytes(a)), string(messages_bytes(b)))
	testing.expect_value(t, a[1].tool_calls[0].function.arguments, `{"a":{"b":2},"z":1}`)
}

@(test)
test_system_prompt_layers_and_git_boundary :: proc(t: ^testing.T) {
	dir := test_temp_dir("prompt")
	defer test_cleanup(dir)
	root := fmt.tprintf("%s/repo", dir)
	sub := fmt.tprintf("%s/sub", root)
	config := fmt.tprintf("%s/config", dir)
	os.make_directory_all(sub)
	os.make_directory_all(fmt.tprintf("%s/.git", root))
	test_write_file(fmt.tprintf("%s/AGENTS.md", dir), "outside-memory")
	test_write_file(fmt.tprintf("%s/AGENTS.md", root), "root-memory")
	test_write_file(fmt.tprintf("%s/AGENTS.md", sub), "sub-memory")
	test_write_file(fmt.tprintf("%s/AGENTS.md", config), "global-memory")

	agent := agent_default_general()
	agent.body = "AGENT_BODY"
	cwd, _ := canonicalize_path(sub)
	prompt := build_system_prompt(
		{
			cwd = cwd,
			config_dir = config,
			agent = agent,
			append_prompt = "APPEND_MARKER",
			tool_section = "TOOL_SECTION",
		},
	)
	testing.expect(t, test_contains(prompt, "global-memory"))
	testing.expect(t, test_contains(prompt, "root-memory"))
	testing.expect(t, test_contains(prompt, "sub-memory"))
	testing.expect(t, !test_contains(prompt, "outside-memory"))
	testing.expect(t, test_contains(prompt, "TOOL_SECTION"))
	testing.expect(t, test_contains(prompt, "AGENT_BODY"))
	testing.expect(t, test_contains(prompt, "APPEND_MARKER"))

	root_pos := strings.index(prompt, "root-memory")
	sub_pos := strings.index(prompt, "sub-memory")
	global_pos := strings.index(prompt, "global-memory")
	append_pos := strings.index(prompt, "APPEND_MARKER")
	testing.expect(t, global_pos < root_pos)
	testing.expect(t, root_pos < sub_pos)
	testing.expect(t, sub_pos < append_pos)
}

@(test)
test_context_build_uses_frozen_system_prompt_blob :: proc(t: ^testing.T) {
	project, _, dir := test_project_and_settings(t, "ctx-system")
	defer test_cleanup(dir)
	prompt_text := "frozen system prompt with 中文"
	sha, _ := blob_write(project, transmute([]byte)prompt_text)
	events := []Event {
		test_event(
			"session_start",
			json_concat(
				`{"v":1,"seq":0,"ts":0,"type":"session_start","session_id":"s","content":"","role":"system","cwd":"`,
				project.root,
				`","model":"m","provider":"`,
				PROVIDER_NAME,
				`","agent_name":"general","agent_depth":0,"content_ref":"`,
				sha,
				`","content_bytes":`,
				fmt.tprintf("%d", len(prompt_text)),
				`}`,
			),
		),
		test_event("user_message", `{"type":"user_message","content":"hi"}`),
	}
	system_prompt, messages, err := context_build(project, events)
	if !is_ok(err) {
		fmt.println("context_build error:", err.message)
	}
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, system_prompt, prompt_text)
	testing.expect_value(t, len(messages), 1)
	testing.expect_value(t, messages[0].content.?, "hi")
}

@(test)
test_context_build_missing_system_blob_fails :: proc(t: ^testing.T) {
	project, _, dir := test_project_and_settings(t, "ctx-system-missing")
	defer test_cleanup(dir)
	missing := "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
	events := []Event {
		test_event(
			"session_start",
			json_concat(
				`{"v":1,"seq":0,"ts":0,"type":"session_start","session_id":"s","content":"","role":"system","cwd":"`,
				project.root,
				`","model":"m","provider":"`,
				PROVIDER_NAME,
				`","agent_name":"general","agent_depth":0,"content_ref":"`,
				missing,
				`"}`,
			),
		),
	}
	_, _, err := context_build(project, events)
	testing.expect_value(t, err.code, Exit_Code.Usage)
}

@(test)
test_available_tools_removes_task_at_max_depth :: proc(t: ^testing.T) {
	agent := agent_default_general()
	names := available_tool_names(agent, 1, 1)
	for name in names {
		testing.expect(t, name != "task")
	}
	names_root := available_tool_names(agent, 0, 1)
	found := false
	for name in names_root {
		if name == "task" {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
test_json_canonical_string_sorts_keys :: proc(t: ^testing.T) {
	value, perr := json.parse_string(`{"z":1,"a":[3,{"y":true,"b":null}],"m":"x"}`, .JSON, true)
	testing.expect_value(t, perr, nil)
	testing.expect_value(t, json_canonical_string(value), `{"a":[3,{"b":null,"y":true}],"m":"x","z":1}`)
}
