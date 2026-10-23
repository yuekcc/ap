package tui

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

test_temp_dir :: proc(prefix: string) -> string {
	base := os.get_env("TEMP", context.allocator)
	if len(base) == 0 {
		base = os.get_env("TMPDIR", context.allocator)
	}
	if len(base) == 0 {
		base = "."
	}
	dir := fmt.aprintf("%s/ap-tui-test-%s-%d", base, prefix, time.time_to_unix_nano(time.now()))
	os.make_directory_all(dir)
	return dir
}

test_write_file :: proc(path, content: string) {
	dir, _ := os.split_path(path)
	if len(dir) > 0 {
		os.make_directory_all(dir)
	}
	if err := os.write_entire_file_from_bytes(path, transmute([]byte)content); err != nil {
		panic("failed to write test file")
	}
}

@(test)
test_fnv32a_known_value :: proc(t: ^testing.T) {
	testing.expect_value(t, fnv32a_hex(transmute([]byte)string("hello")), "4f9f2cab")
}

@(test)
test_parse_stream_events :: proc(t: ^testing.T) {
	ev, ok := parse_event_line(`{"type":"message_update","message_id":"m1","delta":{"text":"hi"}}`)
	testing.expect(t, ok)
	testing.expect_value(t, ev.type, "message_update")
	text, has_text := ev.delta.text.?
	testing.expect(t, has_text)
	testing.expect_value(t, text, "hi")

	start, ok2 := parse_event_line(`{"type":"session_start","session_id":"ses_x","content":"sys","parent_session_id":null}`)
	testing.expect(t, ok2)
	testing.expect_value(t, start.session_id, "ses_x")
	_, has_parent := start.parent_session_id.?
	testing.expect(t, !has_parent)
}

@(test)
test_format_tool_args :: proc(t: ^testing.T) {
	value: json.Value
	args_json := `{"file_path":"ap/main.odin","limit":20,"ok":true}`
	err := json.unmarshal(transmute([]byte)args_json, &value)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, format_args(value, nil), "file_path=ap/main.odin, limit=20, ok=true")
}

@(test)
test_preview_content_truncates :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 10 {
		fmt.sbprintf(&b, "line %d\n", i)
	}
	out, truncated := preview_content(strings.to_string(b))
	testing.expect(t, !truncated)
	testing.expect(t, strings.contains(out, "line 9"))

	_, truncated_many_lines := preview_content(strings.repeat("x\n", 300, context.temp_allocator))
	testing.expect(t, truncated_many_lines)

	long := strings.repeat("y", 30000, context.temp_allocator)
	out_long, truncated_bytes := preview_content(long)
	testing.expect(t, truncated_bytes)
	testing.expect(t, len(out_long) <= 20000)
}

test_render_to_file :: proc(
	t: ^testing.T,
	events: []string,
	mode: Event_Mode,
) -> string {
	dir := test_temp_dir("render")
	defer os.remove_all(dir)

	project := Project {
		config_dir = dir,
		root = dir,
		hash = "test",
		dir = dir,
		blobs_dir = fmt.aprintf("%s/blobs", dir),
	}
	os.make_directory_all(project.blobs_dir)

	out_path := fmt.aprintf("%s/out.txt", dir)
	file, ferr := os.open(out_path, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil {
		return ""
	}

	r := Renderer {
		out = file,
		color = false,
		project = &project,
		at_line_start = true,
	}
	for line in events {
		ev, ok := parse_event_line(line)
		if !ok {
			continue
		}
		render_event(&r, ev, mode)
		free_all(context.temp_allocator)
	}
	finish_assistant(&r)
	os.close(file)
	data, _ := os.read_entire_file_from_path(out_path, context.allocator)
	return string(data)
}

@(test)
test_render_live_stream :: proc(t: ^testing.T) {
	out := test_render_to_file(
		t,
		{
			`{"type":"message_start","message_id":"m1"}`,
			`{"type":"message_update","message_id":"m1","delta":{"text":"hello"}}`,
			`{"type":"message_update","message_id":"m1","delta":{"text":" world\n"}}`,
			`{"type":"message_end","message_id":"m1","content":[{"type":"text","text":"hello world\n"}]}`,
			`{"type":"tool_execution_start","tool_call_id":"c1","name":"read_file","args":{"file_path":"ap/main.odin"}}`,
			`{"type":"tool_execution_end","tool_call_id":"c1","ok":true,"content":"file body\n","duration_ms":12}`,
		},
		.Live,
	)
	testing.expect(t, strings.contains(out, "● hello world"))
	testing.expect(t, strings.contains(out, "⚙ read_file"))
	testing.expect(t, strings.contains(out, "file_path=ap/main.odin"))
	testing.expect(t, strings.contains(out, "file body"))
	testing.expect(t, strings.contains(out, "✓ 12ms"))
	// 文本增量已经展示过，message_end 不应重复整段文本。
	testing.expect_value(t, strings.count(out, "hello world"), 1)
}

@(test)
test_render_history :: proc(t: ^testing.T) {
	out := test_render_to_file(
		t,
		{
			`{"type":"user_message","content":"do it"}`,
			`{"type":"message_end","message_id":"m1","content":[{"type":"text","text":"working\n"}]}`,
			`{"type":"tool_execution_start","tool_call_id":"c1","name":"bash","args":{"command":"ls"}}`,
			`{"type":"tool_execution_end","tool_call_id":"c1","ok":false,"error":"boom","duration_ms":3}`,
			`{"type":"turn_end","turn":1,"stop_reason":"max_steps"}`,
		},
		.History,
	)
	testing.expect(t, strings.contains(out, "› do it"))
	testing.expect(t, strings.contains(out, "● working"))
	testing.expect(t, strings.contains(out, "⚙ bash"))
	testing.expect(t, strings.contains(out, "command=ls"))
	testing.expect(t, strings.contains(out, "✗ 3ms boom"))
	testing.expect(t, strings.contains(out, "turn ended: max_steps"))
}

@(test)
test_find_latest_root_session :: proc(t: ^testing.T) {
	dir := test_temp_dir("sessions")
	defer os.remove_all(dir)
	project := Project {
		config_dir = dir,
		root = dir,
		hash = "test",
		dir = dir,
		blobs_dir = fmt.aprintf("%s/blobs", dir),
	}
	os.make_directory_all(project.dir)

	root_line := `{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_root","content":"sys","cwd":"/x","model":"m","provider":"p","agent_name":"general","agent_depth":0,"parent_session_id":null}`
	child_line := `{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_child","content":"sys","cwd":"/x","model":"m","provider":"p","agent_name":"general","agent_depth":1,"parent_session_id":"ses_root"}`
	test_write_file(fmt.tprintf("%s/ses_root.jsonl", dir), strings.concatenate({root_line, "\n"}))
	test_write_file(fmt.tprintf("%s/ses_child.jsonl", dir), strings.concatenate({child_line, "\n"}))

	found, err := find_latest_root_session(project)
	testing.expect_value(t, err.message, "")
	testing.expect_value(t, found, "ses_root")
}

@(test)
test_replay_session :: proc(t: ^testing.T) {
	dir := test_temp_dir("replay")
	defer os.remove_all(dir)
	project := Project {
		config_dir = dir,
		root = dir,
		hash = "test",
		dir = dir,
		blobs_dir = fmt.aprintf("%s/blobs", dir),
	}
	os.make_directory_all(project.dir)

	transcript := strings.concatenate(
		{
			`{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_1","content":"sys","cwd":"/x","model":"m","provider":"p","agent_name":"general","agent_depth":0,"parent_session_id":null}`,
			"\n",
			`{"v":1,"seq":1,"ts":2,"type":"user_message","content":"hello"}`,
			"\n",
			`{"v":1,"seq":2,"ts":3,"type":"message_end","message_id":"m1","content":[{"type":"text","text":"hi there\n"}]}`,
			"\n",
		},
	)
	test_write_file(fmt.tprintf("%s/ses_1.jsonl", dir), transcript)

	out_path := fmt.aprintf("%s/out.txt", dir)
	file, ferr := os.open(out_path, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil {
		return
	}
	app := App {
		project = project,
		session_id = "ses_1",
		renderer = {
			out = file,
			color = false,
			project = &project,
			at_line_start = true,
		},
	}
	err := replay_session(&app, "ses_1")
	testing.expect_value(t, err.message, "")
	os.close(file)
	data, _ := os.read_entire_file_from_path(out_path, context.allocator)
	out := string(data)
	testing.expect(t, strings.contains(out, "resumed ses_1"))
	testing.expect(t, strings.contains(out, "› hello"))
	testing.expect(t, strings.contains(out, "● hi there"))
}

@(test)
test_replay_session_resolves_blobs :: proc(t: ^testing.T) {
	dir := test_temp_dir("blob")
	defer os.remove_all(dir)
	project := Project {
		config_dir = dir,
		root = dir,
		hash = "test",
		dir = dir,
		blobs_dir = fmt.aprintf("%s/blobs", dir),
	}
	os.make_directory_all(project.blobs_dir)
	test_write_file(fmt.tprintf("%s/%s", project.blobs_dir, "559600820d9e6926bb88d9a39b1be2c31c01682580b6a7eaf50c53611d74493d"), "blob text\n")

	transcript := strings.concatenate(
		{
			`{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_1","content":"sys","cwd":"/x","model":"m","provider":"p","agent_name":"general","agent_depth":0,"parent_session_id":null}`,
			"\n",
			`{"v":1,"seq":1,"ts":2,"type":"message_end","message_id":"m1","content":[{"type":"text","text_ref":"559600820d9e6926bb88d9a39b1be2c31c01682580b6a7eaf50c53611d74493d","text_bytes":10}]}`,
			"\n",
			`{"v":1,"seq":2,"ts":3,"type":"tool_execution_start","tool_call_id":"c1","name":"read_file","args":{"file_path":"a"}}`,
			"\n",
			`{"v":1,"seq":3,"ts":4,"type":"tool_execution_end","tool_call_id":"c1","ok":true,"content":null,"content_ref":"559600820d9e6926bb88d9a39b1be2c31c01682580b6a7eaf50c53611d74493d","content_preview":"preview"}`,
			"\n",
		},
	)
	test_write_file(fmt.tprintf("%s/ses_1.jsonl", dir), transcript)

	out_path := fmt.aprintf("%s/out.txt", dir)
	file, ferr := os.open(out_path, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil {
		return
	}
	app := App {
		project = project,
		session_id = "ses_1",
		renderer = {
			out = file,
			color = false,
			project = &project,
			at_line_start = true,
		},
	}
	err := replay_session(&app, "ses_1")
	testing.expect_value(t, err.message, "")
	os.close(file)
	data, _ := os.read_entire_file_from_path(out_path, context.allocator)
	out := string(data)
	testing.expect(t, strings.contains(out, "● blob text"))
	testing.expect(t, strings.contains(out, "blob text"))
}

@(test)
test_on_stdout_line_remembers_session :: proc(t: ^testing.T) {
	app := App{}
	on_stdout_line(
		&app,
		`{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_x","content":"sys","cwd":"/x","model":"m","provider":"p","agent_name":"general","agent_depth":0,"parent_session_id":null}`,
	)
	testing.expect_value(t, app.session_id, "ses_x")
}
