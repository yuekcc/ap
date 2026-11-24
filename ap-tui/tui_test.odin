package aptui

import client "../ap-core/client"
import protocol "../ap-core/protocol"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
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
	testing.expect_value(t, client.fnv32a_hex(transmute([]byte)string("hello")), "4f9f2cab")
}

test_render_to_file :: proc(
	t: ^testing.T,
	events: []string,
	mode: Event_Mode,
	glow: Glow_Config = {},
) -> string {
	dir := test_temp_dir("render")
	defer os.remove_all(dir)

	project := client.Project {
		config_dir = dir,
		root       = dir,
		hash       = "test",
		dir        = dir,
		blobs_dir  = fmt.aprintf("%s/blobs", dir),
	}
	os.make_directory_all(project.blobs_dir)

	out_path := fmt.aprintf("%s/out.txt", dir)
	file, ferr := os.open(out_path, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil {
		return ""
	}

	r := Renderer {
		out           = file,
		color         = false,
		project       = &project,
		at_line_start = true,
		glow          = glow,
	}
	for line in events {
		ev, ok := protocol.parse_stream_event(line)
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

fake_glow_render :: proc(text: string, width: int, color: bool) -> (string, client.Error) {
	_ = width
	_ = color
	return fmt.aprintf("[glow] %s", strings.trim_space(text)), client.ok_error()
}

fake_glow_fail :: proc(text: string, width: int, color: bool) -> (string, client.Error) {
	_, _, _ = text, width, color
	return "", client.errorf("boom")
}

@(test)
test_glow_renders_message_end_once :: proc(t: ^testing.T) {
	out := test_render_to_file(
		t,
		{
			`{"type":"message_start","message_id":"m1"}`,
			`{"type":"message_update","message_id":"m1","delta":{"text":"hello"}}`,
			`{"type":"message_update","message_id":"m1","delta":{"text":" world\n"}}`,
			`{"type":"message_end","message_id":"m1","content":[{"type":"text","text":"hello world\n"}]}`,
		},
		.Live,
		Glow_Config{enabled = true, render = fake_glow_render},
	)
	// delta 不上屏，只在 message_end 渲染一次。
	testing.expect(t, strings.contains(out, "● [glow] hello world"))
	testing.expect_value(t, strings.count(out, "hello world"), 1)
}

@(test)
test_glow_renders_history_message :: proc(t: ^testing.T) {
	out := test_render_to_file(
		t,
		{
			`{"type":"user_message","content":"do it"}`,
			`{"type":"message_end","message_id":"m1","content":[{"type":"text","text":"answer\n"}]}`,
		},
		.History,
		Glow_Config{enabled = true, render = fake_glow_render},
	)
	testing.expect(t, strings.contains(out, "› do it"))
	testing.expect(t, strings.contains(out, "● [glow] answer"))
}

@(test)
test_glow_failure_falls_back_to_raw_once :: proc(t: ^testing.T) {
	out := test_render_to_file(
		t,
		{
			`{"type":"message_end","message_id":"m1","content":[{"type":"text","text":"hello\n"}]}`,
			`{"type":"message_end","message_id":"m2","content":[{"type":"text","text":"world\n"}]}`,
		},
		.Live,
		Glow_Config{enabled = true, render = fake_glow_fail},
	)
	testing.expect(t, strings.contains(out, "● hello"))
	testing.expect(t, strings.contains(out, "● world"))
	// 第一次失败后关闭本进程内的 glow，不再重复报错。
	testing.expect_value(t, strings.count(out, "glow failed"), 1)
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
	// 工具调用占两行：参数行 + 缩进两格的状态行，不展示输出内容。
	testing.expect(t, strings.contains(out, "◆ read_file (file_path=ap/main.odin)\n  ✓ 12ms\n"))
	testing.expect(t, !strings.contains(out, "file body"))
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
	testing.expect(t, strings.contains(out, "◆ bash (command=ls)\n  ✗ 3ms boom\n"))
	testing.expect(t, strings.contains(out, "turn ended: max_steps"))
}

@(test)
test_render_tool_error_is_single_line :: proc(t: ^testing.T) {
	out := test_render_to_file(
		t,
		{
			`{"type":"tool_execution_start","tool_call_id":"c1","name":"bash","args":{"command":"false"}}`,
			`{"type":"tool_execution_end","tool_call_id":"c1","ok":false,"error":"line one\nline two","exit_code":1}`,
		},
		.Live,
	)
	testing.expect(t, strings.contains(out, "◆ bash (command=false)\n  ✗ exit 1 line one line two\n"))
}

// 工具运行期间插入的 note（如 --verbose 的 stderr）不会让状态行多出空行。
@(test)
test_render_tool_end_after_note :: proc(t: ^testing.T) {
	dir := test_temp_dir("tool_note")
	defer os.remove_all(dir)
	project := client.Project {
		config_dir = dir,
		root = dir,
		hash = "test",
		dir = dir,
		blobs_dir = fmt.aprintf("%s/blobs", dir),
	}

	out_path := fmt.aprintf("%s/out.txt", dir)
	file, ferr := os.open(out_path, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil {
		return
	}
	r := Renderer {
		out = file,
		color = false,
		project = &project,
		at_line_start = true,
	}
	tool_start(&r, "bash", "command=ls")
	note(&r, "[ap] stderr line")
	tool_end(&r, true, "", 7, nil)
	os.close(file)

	data, _ := os.read_entire_file_from_path(out_path, context.allocator)
	testing.expect_value(t, string(data), "◆ bash (command=ls)\n[ap] stderr line\n  ✓ 7ms\n")
}

@(test)
test_find_latest_root_session :: proc(t: ^testing.T) {
	dir := test_temp_dir("sessions")
	defer os.remove_all(dir)
	project := client.Project {
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

	found, err := client.find_latest_root_session(project)
	testing.expect_value(t, err.message, "")
	testing.expect_value(t, found, "ses_root")
}

@(test)
test_replay_session :: proc(t: ^testing.T) {
	dir := test_temp_dir("replay")
	defer os.remove_all(dir)
	project := client.Project {
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
	project := client.Project {
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
test_on_agent_event_remembers_session :: proc(t: ^testing.T) {
	app := App{}
	ev, ok := protocol.parse_stream_event(
		`{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_x","content":"sys","cwd":"/x","model":"m","provider":"p","agent_name":"general","agent_depth":0,"parent_session_id":null}`,
	)
	testing.expect(t, ok)
	on_agent_event(&app, ev)
	testing.expect_value(t, app.session_id, "ses_x")
}

@(test)
test_turn_gap_before_prompt :: proc(t: ^testing.T) {
	dir := test_temp_dir("gap")
	defer os.remove_all(dir)
	project := client.Project {
		config_dir = dir,
		root = dir,
		hash = "test",
		dir = dir,
		blobs_dir = fmt.aprintf("%s/blobs", dir),
	}

	out_path := fmt.aprintf("%s/out.txt", dir)
	file, ferr := os.open(out_path, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil {
		return
	}
	app := App {
		project = project,
		renderer = {
			out = file,
			color = false,
			project = &project,
			at_line_start = true,
		},
	}

	// 首轮之前（没有跑过 ap）不额外空行。
	input := Input{}
	write_turn_gap(&app, &input)
	ensure_line_start(&app.renderer)

	// 模拟一轮 turn 的输出结束后设置标志。
	note(&app.renderer, "agent done")
	app.prompt_gap = true
	write_turn_gap(&app, &input)
	ensure_line_start(&app.renderer)
	// 标志只生效一次。
	write_turn_gap(&app, &input)
	os.close(file)

	data, _ := os.read_entire_file_from_path(out_path, context.allocator)
	out := string(data)
	testing.expect_value(t, out, "agent done\n\n")
}

// handoff 是正常结束，不是失败：turn_end 不写好也不会画成告警行。
@(test)
test_render_handoff_turn_end_is_silent :: proc(t: ^testing.T) {
	out := test_render_to_file(
		t,
		{
			`{"type":"message_end","message_id":"m1","content":[{"type":"text","text":"done\n"}]}`,
			`{"type":"turn_end","turn":1,"stop_reason":"handoff"}`,
		},
		.History,
	)
	testing.expect(t, !strings.contains(out, "turn ended: handoff"))
}

@(test)
test_osc52_sequence :: proc(t: ^testing.T) {
	seq, err := osc52_sequence("hello\n")
	testing.expect_value(t, err.message, "")
	testing.expect_value(t, seq, "\x1b]52;c;aGVsbG8K\x1b\\")
}

@(test)
test_write_osc52_to_file :: proc(t: ^testing.T) {
	dir := test_temp_dir("osc52")
	defer os.remove_all(dir)

	path := fmt.aprintf("%s/out.bin", dir)
	file, ferr := os.open(path, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil {
		return
	}
	err := write_osc52(file, "hi")
	os.close(file)
	testing.expect_value(t, err.message, "")

	data, _ := os.read_entire_file_from_path(path, context.allocator)
	testing.expect_value(t, string(data), "\x1b]52;c;aGk=\x1b\\")
}

// /copy 用原始 Markdown，而不是 glow 渲染结果；空消息不覆盖上一条。
@(test)
test_render_tracks_last_assistant_text :: proc(t: ^testing.T) {
	dir := test_temp_dir("last_text")
	defer os.remove_all(dir)
	project := client.Project {
		config_dir = dir,
		root       = dir,
		hash       = "test",
		dir        = dir,
		blobs_dir  = fmt.aprintf("%s/blobs", dir),
	}

	out_path := fmt.aprintf("%s/out.txt", dir)
	file, ferr := os.open(out_path, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil {
		return
	}
	r := Renderer {
		out           = file,
		color         = false,
		project       = &project,
		at_line_start = true,
		glow          = Glow_Config{enabled = true, render = fake_glow_render},
	}
	defer {
		if len(r.last_assistant_text) > 0 {
			delete(r.last_assistant_text, context.allocator)
		}
	}
	events := [?]string {
		`{"type":"message_start","message_id":"m1"}`,
		`{"type":"message_update","message_id":"m1","delta":{"text":"first"}}`,
		`{"type":"message_end","message_id":"m1","content":[{"type":"text","text":"first\n"}]}`,
		`{"type":"message_end","message_id":"m2","content":[]}`,
		`{"type":"message_start","message_id":"m3"}`,
		`{"type":"message_end","message_id":"m3","content":[{"type":"text","text":"# second\n\nbody\n"}]}`,
	}
	for line in events {
		ev, ok := protocol.parse_stream_event(line)
		if !ok {
			continue
		}
		render_event(&r, ev, .Live)
		free_all(context.temp_allocator)
	}
	os.close(file)
	testing.expect_value(t, r.last_assistant_text, "# second\n\nbody\n")
}

@(test)
test_copy_command_without_message :: proc(t: ^testing.T) {
	dir := test_temp_dir("copy_cmd")
	defer os.remove_all(dir)

	out_path := fmt.aprintf("%s/out.txt", dir)
	file, ferr := os.open(out_path, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil {
		return
	}
	app := App {
		renderer = {out = file, at_line_start = true},
	}
	testing.expect_value(t, handle_command(&app, "/copy"), Command_Result.Handled)
	os.close(file)

	data, _ := os.read_entire_file_from_path(out_path, context.allocator)
	testing.expect(t, strings.contains(string(data), "nothing to copy"))
}

@(test)
test_format_elapsed :: proc(t: ^testing.T) {
	testing.expect_value(t, format_elapsed(0), "0ms")
	testing.expect_value(t, format_elapsed(842 * time.Millisecond), "842ms")
	testing.expect_value(t, format_elapsed(3480 * time.Millisecond), "3.4s")
	testing.expect_value(t, format_elapsed(65 * time.Second), "1m05s")
	testing.expect_value(t, format_elapsed(3725 * time.Second), "1h02m")
	// 时钟回拨等异常输入不能显示负数。
	testing.expect_value(t, format_elapsed(-5 * time.Second), "0ms")
}

@(test)
test_turn_summary_line :: proc(t: ^testing.T) {
	testing.expect_value(t, turn_summary_line("", 3480 * time.Millisecond, false), "turn 3.4s")
	testing.expect_value(
		t,
		turn_summary_line("ses_x", 15 * time.Millisecond, false),
		"using session: ses_x (15ms)",
	)
	testing.expect_value(t, turn_summary_line("", 3480 * time.Millisecond, true), "turn 3.4s · cancelled")
	testing.expect_value(
		t,
		turn_summary_line("ses_x", 15 * time.Millisecond, true),
		"using session: ses_x (15ms) · cancelled",
	)
}

// 取消的轮次不再重复报退出码和 stderr 预览。
@(test)
test_turn_cancelled_classification :: proc(t: ^testing.T) {
	testing.expect(t, turn_cancelled({exit_code = 1, cancelled = true}, false))
	testing.expect(t, turn_cancelled({exit_code = 1}, true))
	testing.expect(t, turn_cancelled({exit_code = 130}, false))
	testing.expect(t, turn_cancelled({exit_code = 143}, false))
	testing.expect(t, !turn_cancelled({exit_code = 1}, false))
	testing.expect(t, !turn_cancelled({exit_code = 0}, false))
}

// 实时取消不单独占行：cancel 与 turn_end 都不上屏，由结束行带上 cancelled。
@(test)
test_render_live_cancel_deferred_to_summary :: proc(t: ^testing.T) {
	dir := test_temp_dir("cancel")
	defer os.remove_all(dir)
	project := client.Project {
		config_dir = dir,
		root = dir,
		hash = "test",
		dir = dir,
		blobs_dir = fmt.aprintf("%s/blobs", dir),
	}

	out_path := fmt.aprintf("%s/out.txt", dir)
	file, ferr := os.open(out_path, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil {
		return
	}
	r := Renderer {
		out = file,
		color = false,
		project = &project,
		at_line_start = true,
	}

	cancel_line := `{"type":"cancel","scope":"step"}`
	cancel_ev, cancel_ok := protocol.parse_stream_event(cancel_line)
	testing.expect(t, cancel_ok)
	render_event(&r, cancel_ev, .Live)
	free_all(context.temp_allocator)
	testing.expect(t, r.cancelled)

	turn_end := `{"type":"turn_end","turn":1,"stop_reason":"cancelled"}`
	end_ev, end_ok := protocol.parse_stream_event(turn_end)
	testing.expect(t, end_ok)
	render_event(&r, end_ev, .Live)
	free_all(context.temp_allocator)

	note(&r, turn_summary_line("", 1500 * time.Millisecond, r.cancelled))
	os.close(file)

	data, _ := os.read_entire_file_from_path(out_path, context.allocator)
	testing.expect_value(t, string(data), "turn 1.5s · cancelled\n")
}

// 重放没有结束行，取消记录仍需留痕；turn_end(cancelled) 不额外打印。
@(test)
test_render_history_cancel_note :: proc(t: ^testing.T) {
	out := test_render_to_file(
		t,
		{
			`{"type":"cancel","scope":"step"}`,
			`{"type":"turn_end","turn":1,"stop_reason":"cancelled"}`,
		},
		.History,
	)
	testing.expect(t, strings.contains(out, "cancelled [step]"))
	testing.expect(t, !strings.contains(out, "turn ended"))
}

// ---- 端到端：Ctrl+C 取消一轮后的收尾 ----

FAKE_AGENT_SOURCE :: #load("testdata/fake_agent/main.odin", string)

// 测试进程内只编译一次假 agent。
FAKE_AGENT_EXE: string

fake_agent_path :: proc(t: ^testing.T) -> string {
	if len(FAKE_AGENT_EXE) > 0 {
		return FAKE_AGENT_EXE
	}
	dir := test_temp_dir("fake-agent")
	src_dir := fmt.aprintf("%s/pkg", dir)
	test_write_file(fmt.aprintf("%s/main.odin", src_dir), FAKE_AGENT_SOURCE)
	exe := fmt.aprintf("%s/fake-agent", dir)
	when ODIN_OS == .Windows {
		exe = strings.concatenate({exe, ".exe"})
	}
	state, out, errout, err := os.process_exec(
		{command = []string{"odin", "build", src_dir, fmt.aprintf("-out:%s", exe)}},
		context.allocator,
	)
	defer {
		delete(out)
		delete(errout)
	}
	if err != nil || !state.exited || state.exit_code != 0 {
		fmt.eprintfln("cannot build fake agent: %v\nstdout:\n%s\nstderr:\n%s", err, out, errout)
		testing.fail(t)
		return ""
	}
	// 这个路径要活过整个测试进程；测试的 context.allocator 是每个测试任务
	// 结束后回滚的 arena，不能直接存。
	FAKE_AGENT_EXE = strings.clone(exe, runtime.heap_allocator())
	return FAKE_AGENT_EXE
}

test_cancel_thread_token: ^client.Cancel_Token

test_cancel_after_delay :: proc() {
	time.sleep(300 * time.Millisecond)
	if token := test_cancel_thread_token; token != nil {
		// 线程没有 Odin context 可用，直接写原子标志，和信号处理器一致。
		sync.atomic_store(&token.value, 1)
	}
}

// 取消的一轮只留一行 `turn … · cancelled`：不再报退出码，也不 dump stderr。
@(test)
test_run_turn_cancel_keeps_single_summary :: proc(t: ^testing.T) {
	agent_bin := fake_agent_path(t)
	if len(agent_bin) == 0 {
		return
	}
	dir := test_temp_dir("turn-cancel")
	defer os.remove_all(dir)
	project := client.Project {
		config_dir = dir,
		root       = dir,
		hash       = "test",
		dir        = dir,
		blobs_dir  = fmt.aprintf("%s/blobs", dir),
	}
	os.make_directory_all(project.blobs_dir)

	out_path := fmt.aprintf("%s/out.txt", dir)
	file, ferr := os.open(out_path, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil {
		return
	}

	app := App {
		project   = project,
		agent_bin = agent_bin,
		renderer  = {out = file, color = false, project = &project, at_line_start = true},
	}

	cancel: client.Cancel_Token
	test_cancel_thread_token = &cancel
	defer test_cancel_thread_token = nil
	th := thread.create_and_start(test_cancel_after_delay)
	exit_code := run_agent_turn(&app, "[scenario:cancel]", &cancel)
	thread.join(th)
	os.close(file)

	testing.expect(t, exit_code != 0)
	data, _ := os.read_entire_file_from_path(out_path, context.allocator)
	out := string(data)
	testing.expect(t, strings.contains(out, "· cancelled"))
	// 取消被当成预期操作：退出码、stderr 预览和 turn ended 都不该出现。
	testing.expect(t, !strings.contains(out, "agent exited with code"))
	testing.expect(t, !strings.contains(out, "agent stderr"))
	testing.expect(t, !strings.contains(out, "## Step 1"))
	testing.expect(t, !strings.contains(out, "turn ended"))
	testing.expect(t, !strings.contains(out, "cancelled [step]"))
}

// `/` 开头的裸单词按命令处理：未知命令只提示，不当提示词发给模型。
@(test)
test_unknown_slash_command_is_not_a_prompt :: proc(t: ^testing.T) {
	dir := test_temp_dir("unknown-cmd")
	defer os.remove_all(dir)

	out_path := fmt.aprintf("%s/out.txt", dir)
	file, ferr := os.open(out_path, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil {
		return
	}
	app := App {
		renderer = {out = file, at_line_start = true},
	}

	testing.expect_value(t, handle_command(&app, "/q"), Command_Result.Quit)
	testing.expect_value(t, handle_command(&app, "/qxit"), Command_Result.Handled)
	testing.expect_value(t, handle_command(&app, "/tmp"), Command_Result.Handled)
	// 绝对路径和带空格的输入不是命令，仍是提示词。
	testing.expect_value(t, handle_command(&app, "/z/projects/ap/x.odin"), Command_Result.Not_Command)
	testing.expect_value(t, handle_command(&app, "/quit now"), Command_Result.Not_Command)
	testing.expect_value(t, handle_command(&app, "plain"), Command_Result.Not_Command)
	os.close(file)

	data, _ := os.read_entire_file_from_path(out_path, context.allocator)
	out := string(data)
	testing.expect(t, strings.contains(out, "unknown command: /qxit"))
	testing.expect(t, strings.contains(out, "unknown command: /tmp"))
	testing.expect(t, !strings.contains(out, "/z/projects/ap/x.odin"))
}
