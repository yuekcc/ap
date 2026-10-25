package main

import "base:runtime"
import "core:os"
import "core:testing"

expect_command :: proc(t: ^testing.T, actual: []string, expected: []string) {
	testing.expect_value(t, len(actual), len(expected))
	if len(actual) != len(expected) {
		return
	}
	for value, i in expected {
		testing.expect_value(t, actual[i], value)
	}
}

// 记录「这块内存是不是本 allocator 给的」；pump 的结果必须能被同一 allocator 释放。
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
test_pump_agent_allocates_result_with_options_allocator :: proc(t: ^testing.T) {
	dir := test_temp_dir("agent-allocator")
	defer os.remove_all(dir)

	probe := Allocator_Probe{backing = runtime.heap_allocator()}
	// 不能用 temp allocator：pump 每行回调都会 free_all(temp_allocator)。
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

	result := pump_agent(&options, "hello", {})
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
		agent_bin  = "C:/bin/ap.exe",
		session_id = "ses_1",
		config_dir = "C:/cfg",
		cwd        = "C:/proj",
		model      = "some-model",
		agent      = "general",
		max_steps  = 5,
		max_tokens = 1000,
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
		},
	)
}
