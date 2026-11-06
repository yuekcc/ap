package apcli

import platform "../ap-core/platform"
import protocol "../ap-core/protocol"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// 把 text 模式的 stderr 渲染到临时文件，返回完整文本。
console_render :: proc(t: ^testing.T, prefix: string, events: []string) -> string {
	dir := cli_temp_dir(t, prefix)
	defer os.remove_all(dir)

	out_path := fmt.aprintf("%s/err.txt", dir)
	file, ferr := os.open(out_path, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil {
		return ""
	}

	c: Console
	console_init(&c, file, platform.Project{}, false)
	for line in events {
		console_transcript_line(&c, line)
		free_all(context.temp_allocator)
	}
	console_finish(&c)
	os.close(file)

	data, derr := os.read_entire_file_from_path(out_path, context.allocator)
	testing.expect_value(t, derr, nil)
	return string(data)
}

@(test)
test_console_renders_tool_lifecycle :: proc(t: ^testing.T) {
	out := console_render(
		t,
		"console-tool",
		{
			`{"type":"tool_execution_start","tool_call_id":"c1","name":"read_file","args":{"file_path":"a.odin","limit":20}}`,
			`{"type":"tool_execution_end","tool_call_id":"c1","ok":true,"content":"body\n","duration_ms":12}`,
		},
	)
	testing.expect(t, strings.contains(out, "◆ read_file (file_path=a.odin, limit=20)"))
	testing.expect(t, strings.contains(out, "  body\n"))
	testing.expect(t, strings.contains(out, "✓ 12ms"))
}

@(test)
test_console_renders_failed_tool_with_exit_code :: proc(t: ^testing.T) {
	out := console_render(
		t,
		"console-fail",
		{
			`{"type":"tool_execution_start","tool_call_id":"c1","name":"bash","args":{"command":"false"}}`,
			`{"type":"tool_execution_end","tool_call_id":"c1","ok":false,"error":"exit 1","duration_ms":3,"exit_code":1}`,
		},
	)
	testing.expect(t, strings.contains(out, "◆ bash (command=false)"))
	testing.expect(t, strings.contains(out, "✗ 3ms exit 1 exit 1"))
}

@(test)
test_console_skips_preview_after_streamed_tool_update :: proc(t: ^testing.T) {
	// bash 的增量输出已经实时展示，结束时不能再重复整份结果。
	dir := cli_temp_dir(t, "console-stream")
	defer os.remove_all(dir)
	out_path := fmt.aprintf("%s/err.txt", dir)
	file, ferr := os.open(out_path, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil {
		return
	}
	c: Console
	console_init(&c, file, platform.Project{}, false)
	console_transcript_line(&c, `{"type":"tool_execution_start","tool_call_id":"c1","name":"bash","args":{"command":"ls"}}`)
	console_tool_update(&c, "one\n")
	console_tool_update(&c, "two\n")
	console_transcript_line(&c, `{"type":"tool_execution_end","tool_call_id":"c1","ok":true,"content":"one\ntwo\n","duration_ms":5}`)
	console_finish(&c)
	os.close(file)

	data, _ := os.read_entire_file_from_path(out_path, context.allocator)
	out := string(data)
	testing.expect_value(t, strings.count(out, "one"), 1)
	testing.expect_value(t, strings.count(out, "two"), 1)
	testing.expect(t, strings.contains(out, "✓ 5ms"))
}

@(test)
test_console_renders_error_cancel_and_turn_end :: proc(t: ^testing.T) {
	out := console_render(
		t,
		"console-status",
		{
			`{"type":"error","scope":"llm","message":"network error","retryable":true}`,
			`{"type":"error","scope":"llm","message":"bad json","retryable":false}`,
			`{"type":"cancel","scope":"step"}`,
			`{"type":"turn_end","turn":1,"stop_reason":"max_steps"}`,
		},
	)
	testing.expect(t, strings.contains(out, "… [llm] network error"))
	testing.expect(t, strings.contains(out, "! [llm] bad json"))
	testing.expect(t, strings.contains(out, "cancelled [step]"))
	testing.expect(t, strings.contains(out, "turn ended: max_steps"))
}

@(test)
test_console_ignores_retry_progress_lines :: proc(t: ^testing.T) {
	// 重试已经由 error 事件渲染成 `…`，进度行再打一遍就是重复。
	dir := cli_temp_dir(t, "console-retry")
	defer os.remove_all(dir)
	out_path := fmt.aprintf("%s/err.txt", dir)
	file, _ := os.open(out_path, {.Read, .Write, .Create, .Trunc})
	c: Console
	console_init(&c, file, platform.Project{}, false)
	console_progress_line(&c, "[retry] network error (attempt 1, 1000ms)")
	console_progress_line(&c, "[subagent] 正在读取文件")
	console_finish(&c)
	os.close(file)

	data, _ := os.read_entire_file_from_path(out_path, context.allocator)
	out := string(data)
	testing.expect(t, !strings.contains(out, "[retry]"))
	testing.expect(t, strings.contains(out, "正在读取文件"))
}

@(test)
test_console_color_disabled_writes_no_escape :: proc(t: ^testing.T) {
	out := console_render(
		t,
		"console-nocolor",
		{
			`{"type":"tool_execution_start","tool_call_id":"c1","name":"bash","args":{}}`,
			`{"type":"tool_execution_end","tool_call_id":"c1","ok":true,"content":"done\n","duration_ms":1}`,
		},
	)
	testing.expect(t, !strings.contains(out, "\x1b["))
}

@(test)
test_text_format_routes_transcript_to_console :: proc(t: ^testing.T) {
	// text 走 console；json / stream-json 仍走原来的 markdown 进度块。
	dir := cli_temp_dir(t, "output-route")
	defer os.remove_all(dir)
	out_path := fmt.aprintf("%s/err.txt", dir)
	file, _ := os.open(out_path, {.Read, .Write, .Create, .Trunc})
	defer os.close(file)

	out := Output_State{format = .Text}
	console_init(&out.console, file, platform.Project{}, false)
	output_progress(&out, .Block, "### read_file")
	output_progress(&out, .Line, "[subagent] hi")
	output_transcript(&out, protocol.Transcript_Event{line = `{"type":"tool_execution_start","tool_call_id":"c1","name":"bash","args":{"command":"ls"}}`})
	console_finish(&out.console)

	data, _ := os.read_entire_file_from_path(out_path, context.allocator)
	text := string(data)
	testing.expect(t, !strings.contains(text, "### read_file"))
	testing.expect(t, strings.contains(text, "◆ bash (command=ls)"))
	testing.expect(t, strings.contains(text, "hi"))
}
