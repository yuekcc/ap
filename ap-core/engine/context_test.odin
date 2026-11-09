package engine

import "../platform"

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
	testing.expect_value(t, err.kind, Error_Kind.None)
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
test_project_messages_preserves_reasoning_and_tool_order :: proc(t: ^testing.T) {
	project, _, dir := test_project_and_settings(t, "ctx-reasoning")
	defer test_cleanup(dir)

	events := []Event {
		test_event("user_message", `{"type":"user_message","content":"hi"}`),
		test_event(
			"message_end",
			`{"type":"message_end","message_id":"m1","role":"assistant","content":[{"type":"text","text":"checking"},{"type":"tool_use","id":"call_2","name":"bash","input":{"command":"b"}},{"type":"tool_use","id":"call_1","name":"bash","input":{"command":"a"}}],"stop_reason":"tool_use","reasoning":"think step"}`,
		),
		test_event(
			"tool_execution_end",
			`{"type":"tool_execution_end","tool_call_id":"call_2","ok":true,"content":"b done"}`,
		),
		test_event(
			"tool_execution_end",
			`{"type":"tool_execution_end","tool_call_id":"call_1","ok":true,"content":"a done"}`,
		),
	}
	messages, err := project_messages(project, events)
	testing.expect_value(t, err.kind, Error_Kind.None)
	testing.expect_value(t, len(messages), 4)
	testing.expect_value(t, messages[1].role, "assistant")
	testing.expect_value(t, messages[1].reasoning_content.?, "think step")
	testing.expect_value(t, len(messages[1].tool_calls), 2)
	testing.expect_value(t, messages[1].tool_calls[0].id, "call_2")
	testing.expect_value(t, messages[1].tool_calls[1].id, "call_1")
	testing.expect_value(t, messages[2].tool_call_id.?, "call_2")
	testing.expect_value(t, messages[3].tool_call_id.?, "call_1")
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
	testing.expect_value(t, err.kind, Error_Kind.None)
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
	testing.expect_value(t, err.kind, Error_Kind.None)
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
	testing.expect_value(t, err.kind, Error_Kind.None)
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
	testing.expect_value(t, err.kind, Error_Kind.Usage)
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
	testing.expect_value(t, err.kind, Error_Kind.None)
	b, _ := project_messages(project, events)
	testing.expect_value(t, string(messages_bytes(a)), string(messages_bytes(b)))
	testing.expect_value(t, a[1].tool_calls[0].function.arguments, `{"a":{"b":2},"z":1}`)
}

@(test)
test_build_system_prompt_orders_sections :: proc(t: ^testing.T) {
	prompt := build_system_prompt(
		{
			base_override = "BASE\n",
			tool_section = "TOOL_SECTION",
			sections = []string{"## 环境\nENV\n", "## 追加指令\nAPPEND\n"},
		},
	)
	testing.expect(t, strings.has_prefix(prompt, "BASE\n"))
	testing.expect(t, test_contains(prompt, "## 工具\nTOOL_SECTION\n\n## 环境\nENV\n\n## 追加指令\nAPPEND\n"))
	testing.expect(t, strings.has_suffix(prompt, "APPEND\n"))
}

@(test)
test_build_system_prompt_skips_empty_sections_and_adds_newline :: proc(t: ^testing.T) {
	prompt := build_system_prompt(
		{
			base_override = "BASE",
			tool_section = "TOOL_SECTION",
			sections = []string{"", "SECTION_WITHOUT_NEWLINE"},
		},
	)
	testing.expect(t, strings.has_prefix(prompt, "BASE\n\n## 工具\nTOOL_SECTION\n"))
	testing.expect(t, strings.has_suffix(prompt, "\n\nSECTION_WITHOUT_NEWLINE\n"))
}

@(test)
test_build_system_prompt_base_override_keeps_tool_section :: proc(t: ^testing.T) {
	prompt := build_system_prompt(
		{
			base_override = "CUSTOM_BASE\n",
			tool_section = "TOOL_SECTION",
			sections = []string{"APPEND_MARKER"},
		},
	)
	testing.expect(t, strings.has_prefix(prompt, "CUSTOM_BASE\n"))
	testing.expect(t, !test_contains(prompt, "你是 AI Assistant"))
	testing.expect(t, test_contains(prompt, "## 工具\nTOOL_SECTION"))
	testing.expect(t, test_contains(prompt, "APPEND_MARKER"))
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
	testing.expect_value(t, err.kind, Error_Kind.None)
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
	testing.expect_value(t, err.kind, Error_Kind.Usage)
}

// ---- 预算投影 ----

budget_test_project :: proc(t: ^testing.T, name: string) -> (Project, string) {
	project, _, dir := test_project_and_settings(t, name)
	os.make_directory_all(project.root)
	return project, dir
}

// 一条 user_message + 8 个大工具结果。ELIDE_KEEP_RECENT_RESULTS 是 6，
// 所以前两个可以被省略。
budget_test_events :: proc(project: Project, content: string) -> []Event {
	events := make([dynamic]Event, 0, 16)
	append(&events, budget_test_system_start(project))
	append(
		&events,
		test_event("user_message", `{"v":1,"seq":0,"ts":0,"type":"user_message","content":"go"}`),
	)
	for i in 0 ..< 8 {
		call_id := fmt.tprintf("call_%d", i)
		append(
			&events,
			test_event(
				"message_end",
				json_concat(
					`{"v":1,"seq":1,"ts":0,"type":"message_end","message_id":"m`,
					fmt.tprintf("%d", i),
					`","role":"assistant","content":[{"type":"tool_use","id":"`,
					call_id,
					`","name":"read_file","input":{"file_path":"a.txt"}}],"stop_reason":"tool_use"}`,
				),
			),
		)
		append(
			&events,
			test_event(
				"tool_execution_end",
				json_concat(
					`{"v":1,"seq":2,"ts":0,"type":"tool_execution_end","tool_call_id":"`,
					call_id,
					`","ok":true,"content":`,
					string(platform.json_canonical_string(json.Value(json.String(content)))),
					`}`,
				),
			),
		)
	}
	return events[:]
}

budget_test_system_start :: proc(project: Project) -> Event {
	return test_event(
		"session_start",
		json_concat(
			`{"v":1,"seq":0,"ts":0,"type":"session_start","session_id":"s","content":"system prompt","role":"system","cwd":"`,
			project.root,
			`","model":"m","provider":"`,
			PROVIDER_NAME,
			`","agent_name":"general","agent_depth":0}`,
		),
	)
}

// limit_tokens <= 0 时 context_build_budgeted 与 context_build 逐字节相同。
@(test)
test_budgeted_matches_unbudgeted_when_disabled :: proc(t: ^testing.T) {
	project, dir := budget_test_project(t, "budget-disabled")
	defer test_cleanup(dir)
	content := strings.repeat("x", 4096)
	events := budget_test_events(project, content)

	want_system, want_messages, cerr := context_build(project, events)
	testing.expect_value(t, cerr.kind, Error_Kind.None)
	got, berr := context_build_budgeted(project, events, 0, 0, 100, context.allocator)
	testing.expect_value(t, berr.kind, Error_Kind.None)
	defer delete(got.messages)
	defer delete(got.system_prompt)
	testing.expect_value(t, got.system_prompt, want_system)
	testing.expect_value(t, string(messages_bytes(got.messages)), string(messages_bytes(want_messages)))
	testing.expect_value(t, got.elided_results, 0)
}

// 同一 transcript + 同一预算连算两次必须逐字节相同。
@(test)
test_budgeted_same_transcript_byte_identical :: proc(t: ^testing.T) {
	project, dir := budget_test_project(t, "budget-deterministic")
	defer test_cleanup(dir)
	events := budget_test_events(project, strings.repeat("y", 4096))
	limit := 3000

	first, ferr := context_build_budgeted(project, events, 0, limit, 100, context.allocator)
	testing.expect_value(t, ferr.kind, Error_Kind.None)
	defer delete(first.messages)
	defer delete(first.system_prompt)
	second, serr := context_build_budgeted(project, events, 0, limit, 100, context.allocator)
	testing.expect_value(t, serr.kind, Error_Kind.None)
	defer delete(second.messages)
	defer delete(second.system_prompt)

	testing.expect_value(t, first.elided_results, second.elided_results)
	testing.expect_value(t, first.estimated_tokens, second.estimated_tokens)
	testing.expect_value(t, string(messages_bytes(first.messages)), string(messages_bytes(second.messages)))
	testing.expect(t, first.elided_results > 0)
}

// content 与 content_ref 两种存储形式必须在阈值边界上得到同样的判定。
@(test)
test_budgeted_elides_blob_and_inline_alike :: proc(t: ^testing.T) {
	project, dir := budget_test_project(t, "budget-blob-parity")
	defer test_cleanup(dir)
	content := strings.repeat("z", 4096)
	sha, _ := blob_write(project, transmute([]byte)content)

	events := []Event {
		budget_test_system_start(project),
		test_event("user_message", `{"type":"user_message","content":"go"}`),
		test_event(
			"message_end",
			`{"type":"message_end","message_id":"m1","role":"assistant","content":[{"type":"tool_use","id":"call_1","name":"bash","input":{"command":"x"}}],"stop_reason":"tool_use"}`,
		),
		test_event(
			"tool_execution_end",
			json_concat(
				`{"type":"tool_execution_end","tool_call_id":"call_1","ok":true,"content_ref":"`,
				sha,
				`","content_bytes":4096}`,
			),
		),
	}
	// 补足最近 N 个结果：只有这样这条结果才进入可省略集合。
	inline := make([dynamic]Event, 0, 32)
	append(&inline, ..events)
	tail_content := strings.repeat("z", 4096)
	for i in 0 ..< ELIDE_KEEP_RECENT_RESULTS {
		call_id := fmt.tprintf("tail_%d", i)
		append(
			&inline,
			test_event(
				"message_end",
				json_concat(
					`{"type":"message_end","message_id":"t`,
					fmt.tprintf("%d", i),
					`","role":"assistant","content":[{"type":"tool_use","id":"`,
					call_id,
					`","name":"bash","input":{"command":"y"}}],"stop_reason":"tool_use"}`,
				),
			),
		)
		append(
			&inline,
			test_event(
				"tool_execution_end",
				json_concat(
					`{"type":"tool_execution_end","tool_call_id":"`,
					call_id,
					`","ok":true,"content":`,
					string(platform.json_canonical_string(json.Value(json.String(tail_content)))),
					`}`,
				),
			),
		)
	}
	blob_based, berr := context_build_budgeted(project, inline[:], 0, 1000, 100, context.allocator)
	testing.expect_value(t, berr.kind, Error_Kind.None)
	defer delete(blob_based.messages)
	defer delete(blob_based.system_prompt)
	testing.expect_value(t, blob_based.elided_results, 1)
	// 字节数按解析后的内容长度算，与存储形式无关。
	testing.expect_value(t, blob_based.messages[2].content.?, elided_stub("bash", 4096))
}

// 被省略的结果仍然校验 blob：缺失时组装失败，不静默降级。
@(test)
test_budgeted_elision_still_validates_blob :: proc(t: ^testing.T) {
	project, dir := budget_test_project(t, "budget-blob-missing")
	defer test_cleanup(dir)
	missing := "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
	events := []Event {
		budget_test_system_start(project),
		test_event(
			"message_end",
			`{"type":"message_end","message_id":"m1","role":"assistant","content":[{"type":"tool_use","id":"call_1","name":"bash","input":{"command":"x"}}],"stop_reason":"tool_use"}`,
		),
		test_event(
			"tool_execution_end",
			json_concat(`{"type":"tool_execution_end","tool_call_id":"call_1","ok":true,"content_ref":"`, missing, `"}`),
		),
	}
	_, err := context_build_budgeted(project, events, 0, 1, 100, context.allocator)
	testing.expect_value(t, err.kind, Error_Kind.Usage)
}

// 工具定义与 system prompt 都计入估算：只算 messages 会漏。
@(test)
test_estimate_request_includes_system_and_tools :: proc(t: ^testing.T) {
	messages := []Chat_Message{{role = ROLE_USER, content = "abcd"}}
	without := estimate_request_tokens("", messages, 0)
	with_system := estimate_request_tokens("abcd", messages, 0)
	with_tools := estimate_request_tokens("", messages, 100)
	testing.expect(t, with_system > without)
	testing.expect_value(t, with_tools, without + 100)
}
