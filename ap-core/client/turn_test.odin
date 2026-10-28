package client

import protocol "../protocol"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

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

expect_command :: proc(t: ^testing.T, actual: []string, expected: []string) {
	testing.expect_value(t, len(actual), len(expected))
	if len(actual) != len(expected) {
		return
	}
	for value, i in expected {
		testing.expect_value(t, actual[i], value)
	}
}

Recorded_Event :: struct {
	count: int,
	typ:   string,
	text:  string,
}

record_event :: proc(user: rawptr, ev: protocol.Stream_Event) {
	rec := (^Recorded_Event)(user)
	rec.count += 1
	rec.typ = strings.clone(ev.type)
	if text, ok := ev.delta.text.?; ok {
		rec.text = strings.clone(text)
	}
}

Recorded_Stderr :: struct {
	count: int,
	last:  string,
}

record_stderr :: proc(user: rawptr, line: string) {
	rec := (^Recorded_Stderr)(user)
	rec.count += 1
	rec.last = line
}

Raw_Record :: struct {
	count: int,
	raw:   string,
	typ:   string,
}

record_raw_line :: proc(user: rawptr, ev: protocol.Stream_Event, raw: string) {
	rec := (^Raw_Record)(user)
	rec.count += 1
	rec.raw = strings.clone(raw, context.allocator)
	rec.typ = strings.clone(ev.type, context.allocator)
}

@(test)
test_on_agent_stdout_forwards_events_and_captures_session :: proc(t: ^testing.T) {
	state: Pump_State
	defer if len(state.session_id) > 0 {
		delete(state.session_id, context.allocator)
	}

	rec: Recorded_Event
	defer {
		if len(rec.text) > 0 {
			delete(rec.text, context.allocator)
		}
		if len(rec.typ) > 0 {
			delete(rec.typ, context.allocator)
		}
	}
	callbacks := Turn_Callbacks {
		user     = &rec,
		on_event = record_event,
	}
	ctx := Pump_Context {
		callbacks = &callbacks,
		state     = &state,
	}

	on_agent_stdout_line(&ctx, `{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_x"}`)
	on_agent_stdout_line(&ctx, `{"type":"message_update","message_id":"m1","delta":{"text":"hi"}}`)
	on_agent_stdout_line(&ctx, `not json`)

	testing.expect_value(t, rec.count, 2)
	testing.expect_value(t, state.session_id, "ses_x")
	testing.expect_value(t, rec.typ, "message_update")
	testing.expect_value(t, rec.text, "hi")
}

@(test)
test_on_agent_stderr_caches_and_forwards :: proc(t: ^testing.T) {
	state: Pump_State
	defer delete(state.stderr_log)

	rec: Recorded_Stderr
	callbacks := Turn_Callbacks {
		user      = &rec,
		on_stderr = record_stderr,
	}
	ctx := Pump_Context {
		callbacks = &callbacks,
		state     = &state,
	}

	on_agent_stderr_line(&ctx, "ap: warning: one")
	on_agent_stderr_line(&ctx, "ap: error: two")

	testing.expect_value(t, rec.count, 2)
	testing.expect_value(t, rec.last, "ap: error: two")
	testing.expect_value(t, string(state.stderr_log[:]), "ap: warning: one\nap: error: two\n")
}

@(test)
test_on_agent_stdout_forwards_raw_line_untouched :: proc(t: ^testing.T) {
	state: Pump_State
	defer delete(state.stderr_log)

	rec: Raw_Record
	defer {
		delete(rec.raw)
		delete(rec.typ)
	}
	callbacks := Turn_Callbacks {
		user          = &rec,
		on_event_line = record_raw_line,
	}
	ctx := Pump_Context {
		callbacks = &callbacks,
		state     = &state,
	}

	line := `{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_x","future_field":{"nested":true}}`
	on_agent_stdout_line(&ctx, line)

	testing.expect_value(t, rec.count, 1)
	testing.expect_value(t, rec.typ, "session_start")
	testing.expect_value(t, rec.raw, line)
}

@(test)
test_stderr_cache_keeps_recent_lines :: proc(t: ^testing.T) {
	log: [dynamic]u8
	defer delete(log)

	append_stderr_line(&log, "first line")
	append_stderr_line(&log, "second line")
	testing.expect_value(t, string(log[:]), "first line\nsecond line\n")

	body := strings.repeat("x", 80, context.temp_allocator)
	for i in 0 ..< 1000 {
		append_stderr_line(&log, fmt.tprintf("line-%04d-%s", i, body))
	}

	testing.expect(t, len(log) <= MAX_STDERR_BYTES)
	text := string(log[:])
	testing.expect(t, strings.contains(text, "line-0999-"))
	testing.expect(t, !strings.contains(text, "line-0000-"))
	testing.expect(t, text[0] != '\n')
}

@(test)
test_build_agent_command_minimal :: proc(t: ^testing.T) {
	options := Turn_Options {
		agent_bin  = "C:/bin/ap.exe",
		config_dir = "C:/cfg",
		cwd        = "C:/proj",
	}
	command := build_agent_command(&options)
	defer delete(command)

	expect_command(t, command[:], {"C:/bin/ap.exe", "--print0", "--output-format", "stream-json", "--config-dir", "C:/cfg"})
}

@(test)
test_build_agent_command_forwards_options :: proc(t: ^testing.T) {
	options := Turn_Options {
		agent_bin    = "C:/bin/ap.exe",
		session_id   = "ses_1",
		fork_session = true,
		config_dir   = "C:/cfg",
		cwd          = "C:/proj",
		model        = "some-model",
		agent        = "general",
		max_steps    = 5,
		max_tokens   = 1000,
		verbose      = true,
	}
	command := build_agent_command(&options)
	defer delete(command)

	expect_command(
		t,
		command[:],
		{
			"C:/bin/ap.exe",
			"--print0",
			"--output-format",
			"stream-json",
			"-s",
			"ses_1",
			"--fork-session",
			"--model",
			"some-model",
			"--agent",
			"general",
			"--max-steps",
			"5",
			"--max-tokens",
			"1000",
			"--config-dir",
			"C:/cfg",
			"--verbose",
		},
	)
}

// 记录「这块内存是不是本 allocator 给的」；turn 的结果必须能被同一 allocator 释放。
Allocator_Probe :: struct {
	backing: runtime.Allocator,
	live:    map[rawptr]bool,
}

allocator_probe_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	probe := (^Allocator_Probe)(data)
	memory, err := probe.backing.procedure(
		probe.backing.data,
		mode,
		size,
		alignment,
		old_memory,
		old_size,
		loc,
	)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if err == nil {
			probe.live[raw_data(memory)] = true
		}
	case .Resize, .Resize_Non_Zeroed:
		if err == nil {
			delete_key(&probe.live, old_memory)
			probe.live[raw_data(memory)] = true
		}
	case .Free:
		delete_key(&probe.live, old_memory)
	case .Free_All:
		clear(&probe.live)
	case .Query_Features, .Query_Info:
	}
	return memory, err
}

// 结果字符串必须来自 Turn_Options.allocator：runner 在另一个线程释放它们，
// 不能假设分配线程的 context.allocator 恰好是 heap。
@(test)
test_turn_run_allocates_result_with_options_allocator :: proc(t: ^testing.T) {
	dir := test_temp_dir("agent-allocator")
	defer os.remove_all(dir)

	probe := Allocator_Probe{backing = runtime.heap_allocator()}
	// 不能用 temp allocator：泵每行回调都会 free_all(temp_allocator)。
	probe.live = make(map[rawptr]bool)
	allocator := runtime.Allocator {
		procedure = allocator_probe_proc,
		data      = &probe,
	}
	options := Turn_Options {
		agent_bin  = fake_agent_path(t),
		config_dir = dir,
		cwd        = dir,
		allocator  = allocator,
	}
	if len(options.agent_bin) == 0 {
		return
	}

	result := turn_run(&options, "hello", {})
	testing.expect_value(t, result.session_id, "ses_fake")
	testing.expect(
		t,
		probe.live[raw_data(result.session_id)],
		"session_id must be allocated by Turn_Options.allocator",
	)

	delete(result.session_id, allocator)
	testing.expect(
		t,
		!probe.live[raw_data(result.session_id)],
		"session_id must be freeable with Turn_Options.allocator",
	)
}
