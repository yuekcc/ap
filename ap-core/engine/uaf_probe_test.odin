package engine

// 回归测试：用「free 后写毒」检测 use-after-free。

import "base:runtime"
import "core:encoding/json"
import "core:testing"

POISON :: 0xFF

Poison_Probe :: struct {
	backing:         runtime.Allocator,
	live:            map[rawptr]int,
	untracked_frees: int,
}

poison_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	probe := (^Poison_Probe)(data)
	switch mode {
	case .Free:
		if old_memory != nil {
			if tracked, found := probe.live[old_memory]; found {
				n := min(tracked, 64)
				bytes := transmute([]byte)runtime.Raw_Slice{data = old_memory, len = n}
				for i in 0 ..< n {
					bytes[i] = POISON
				}
				delete_key(&probe.live, old_memory)
			} else {
				probe.untracked_frees += 1
			}
		}
	case .Alloc, .Alloc_Non_Zeroed:
		memory, err := probe.backing.procedure(
			probe.backing.data,
			mode,
			size,
			alignment,
			old_memory,
			old_size,
			loc,
		)
		if err == nil && memory != nil {
			probe.live[raw_data(memory)] = size
		}
		return memory, err
	case .Resize, .Resize_Non_Zeroed:
		memory, err := probe.backing.procedure(
			probe.backing.data,
			mode,
			size,
			alignment,
			old_memory,
			old_size,
			loc,
		)
		if err == nil && memory != nil {
			delete_key(&probe.live, old_memory)
			probe.live[raw_data(memory)] = size
		}
		return memory, err
	case .Free_All, .Query_Features, .Query_Info:
	}
	return probe.backing.procedure(
		probe.backing.data,
		mode,
		size,
		alignment,
		old_memory,
		old_size,
		loc,
	)
}

@(test)
test_probe_message_id_after_free :: proc(t: ^testing.T) {
	probe := Poison_Probe{backing = runtime.heap_allocator()}
	probe.live = make(map[rawptr]int, runtime.heap_allocator())
	poisoned := runtime.Allocator {
		procedure = poison_proc,
		data      = &probe,
	}
	previous := context.allocator
	context.allocator = poisoned
	defer {
		context.allocator = previous
	}

	loop, _, dir := loop_test_setup(t, "loop-uaf-probe")
	args := make(json.Object)
	args["command"] = json.String("echo hi")
	state := Fake_Provider {
		responses = []Fake_Response {
			{tool_name = "bash", tool_id = "call_uaf", tool_input = args, stop = .Tool_Use},
			{text = "done", stop = .Stop},
		},
	}
	fake_provider_state = state
	defer fake_provider_state = {}
	result := loop_run_turn(&loop, "go")
	// loop 收养 provider 的 message_id 与 tool call 后不能再碰已释放内存，
	// 否则这里要么拿到乱码 id，要么在毒化分配器下崩溃。
	testing.expect_value(t, result.error_kind, Error_Kind.None)
	testing.expect_value(t, probe.untracked_frees, 0)

	ids := make([dynamic]string, 0, 2)
	events, rerr := transcript_read_all(loop.project, loop.session_id)
	testing.expect_value(t, rerr.kind, Error_Kind.None)
	for ev in events {
		if ev.type != "message_end" {
			continue
		}
		msg: Message_End_Event
		if json.unmarshal_string(ev.line, &msg) == nil {
			append(&ids, msg.message_id)
		}
	}
	testing.expect_value(t, len(ids), 2)
	if len(ids) == 2 {
		testing.expect_value(t, ids[0], "fake-1")
		testing.expect_value(t, ids[1], "fake-2")
	}
	loop_test_finish(&loop, dir)
}
