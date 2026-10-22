package ap

import "core:encoding/json"
import "core:fmt"
import "core:strings"

Task_State :: struct {
	line_buf:            [dynamic]byte,
	stderr_ring:         [dynamic]byte,
	child_session_id:    string,
	last_error:          string,
	last_text:           string,
	stop_reason:         string,
	usage:               Usage,
	saw_session_start:   bool,
	saw_session_end:     bool,
	project:             Project,
	at_subagent_line_start: bool,
}

task_sanitize_tail :: proc(data: []byte, max_bytes: int) -> string {
	if len(data) == 0 {
		return ""
	}
	tail := data
	if len(tail) > max_bytes {
		tail = tail[len(tail) - max_bytes:]
	}
	// 从合法 UTF-8 边界开始。
	for len(tail) > 0 && !valid_utf8(tail) {
		tail = tail[1:]
	}
	return sanitize_utf8(tail)
}

task_buffer_stderr :: proc(state: ^Task_State, chunk: string) {
	append(&state.stderr_ring, ..transmute([]byte)chunk)
	if len(state.stderr_ring) > 8192 {
		excess := len(state.stderr_ring) - 8192
		copy(state.stderr_ring[:], state.stderr_ring[excess:])
		resize(&state.stderr_ring, 8192)
	}
}

task_forward_text :: proc(state: ^Task_State, text: string) {
	if len(text) == 0 {
		return
	}
	if state.at_subagent_line_start {
		stderr_write_string("[subagent] ")
	}
	stderr_write_string(text)
	state.at_subagent_line_start = text[len(text) - 1] == '\n'
}

task_handle_line :: proc(state: ^Task_State, project: Project, line: string) {
	if len(strings.trim_space(line)) == 0 {
		return
	}
	value, perr := json.parse_string(line, .JSON, true)
	if perr != nil {
		log_debug("subagent: skipping non-JSON stdout line")
		return
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return
	}
	typ, has_type := obj["type"].(json.String)
	if !has_type {
		return
	}
	switch string(typ) {
	case "session_start":
		start: Session_Start_Event
		if json.unmarshal_string(line, &start) == nil {
			state.saw_session_start = true
			state.child_session_id = start.session_id
		}
	case "message_update":
		if delta, ok := obj["delta"].(json.Object); ok {
			if text, ok_text := delta["text"].(json.String); ok_text {
				task_forward_text(state, string(text))
			}
		}
	case "message_end":
		end: Message_End_Event
		if json.unmarshal_string(line, &end) == nil && end.role == "assistant" && end.stop_reason != "cancelled" {
			text := strings.builder_make()
			has_text := false
			for block in end.content {
				if block.type != "text" {
					continue
				}
				block_text, terr := content_block_text(project, block)
				if !is_ok(terr) {
					continue
				}
				if has_text {
					strings.write_byte(&text, '\n')
				}
				strings.write_string(&text, block_text)
				has_text = true
			}
			if has_text {
				state.last_text = strings.to_string(text)
			}
		}
	case "turn_end":
		end: Turn_End_Event
		if json.unmarshal_string(line, &end) == nil {
			state.stop_reason = end.stop_reason
			state.usage = end.usage
		}
	case "error":
		err_ev: Error_Event
		if json.unmarshal_string(line, &err_ev) == nil {
			state.last_error = err_ev.message
		}
	case "session_end":
		state.saw_session_end = true
	}
}

task_stdout_chunk :: proc(user: rawptr, chunk: string) {
	state := (^Task_State)(user)
	append(&state.line_buf, ..transmute([]byte)chunk)
	for {
		nl := -1
		for i in 0 ..< len(state.line_buf) {
			if state.line_buf[i] == '\n' {
				nl = i
				break
			}
		}
		if nl < 0 {
			break
		}
		line := string(state.line_buf[:nl])
		task_handle_line(state, state.project, line)
		remaining := state.line_buf[nl + 1:]
		copy(state.line_buf[:], remaining)
		resize(&state.line_buf, len(state.line_buf) - (nl + 1))
	}
}

task_stderr_chunk :: proc(user: rawptr, chunk: string) {
	state := (^Task_State)(user)
	task_buffer_stderr(state, chunk)
	stderr_write_string(chunk)
}

tool_task :: proc(args: json.Object, ctx: ^Tool_Context) -> Tool_Result {
	prompt, perr := tool_arg_string(args, "prompt")
	if !is_ok(perr) {
		return arg_error(perr)
	}
	if len(prompt) == 0 {
		return tool_fail("prompt must not be empty")
	}
	agent_name := "general"
	if value, err := tool_arg_optional_string(args, "agent_name"); !is_ok(err) {
		return arg_error(err)
	} else if v, ok := value.?; ok && len(v) > 0 {
		agent_name = v
	}
	if ctx.agent_depth >= ctx.settings.max_agent_depth {
		return tool_fail("max_agent_depth reached; task is not available")
	}
	if len(ctx.self_exe) == 0 {
		return tool_fail("cannot determine ap executable path")
	}

	exec_args := []string {
		ctx.self_exe,
		"--agent", agent_name,
		"--output-format", "stream-json",
		"--print0",
		"--parent-session-id", ctx.session_id,
		"--parent-tool-call-id", ctx.parent_tool_call_id,
		"--agent-depth", fmt.tprintf("%d", ctx.agent_depth + 1),
		"--config-dir", ctx.config_dir,
		"--model", ctx.model,
		"--max-steps", fmt.tprintf("%d", ctx.max_steps),
	}

	state: Task_State
	state.line_buf = make([dynamic]byte, 0, 8192)
	state.stderr_ring = make([dynamic]byte, 0, 8192)
	state.at_subagent_line_start = true
	state.project = ctx.project
	defer delete(state.line_buf)
	defer delete(state.stderr_ring)

	run := run_child(
		{
			command = exec_args,
			cwd = ctx.cwd,
			stdin_data = transmute([]byte)prompt,
			timeout_ms = 0,
			max_capture_bytes = ctx.settings.max_capture_bytes,
			cancel = ctx.cancel,
			on_stdout = task_stdout_chunk,
			on_stderr = task_stderr_chunk,
			user = &state,
		},
	)
	defer free_run_result(&run)
	if len(state.line_buf) > 0 {
		task_handle_line(&state, ctx.project, string(state.line_buf[:]))
	}
	if !run.spawned {
		res := tool_fail(run.error)
		res.fatal = true
		return res
	}
	if run.cancelled {
		return task_fail_with_state(&state, run.duration_ms, "cancelled")
	}
	if len(run.error) > 0 {
		res := task_fail_with_state(&state, run.duration_ms, run.error)
		res.fatal = true
		return res
	}
	if run.overflow {
		return task_fail_with_state(&state, run.duration_ms, "subagent output exceeded max_capture_bytes")
	}
	if !state.saw_session_start {
		message := fmt.tprintf("subagent exited before session_start; stderr: %s", task_sanitize_tail(state.stderr_ring[:], 2000))
		return task_fail_with_state(&state, run.duration_ms, message)
	}
	if run.exit_code != 0 {
		message := state.last_error
		if len(message) == 0 {
			message = task_sanitize_tail(state.stderr_ring[:], 2000)
		}
		return task_fail_with_state(&state, run.duration_ms, fmt.tprintf("subagent exited with code %d: %s", run.exit_code, message))
	}
	if !state.saw_session_end {
		return task_fail_with_state(&state, run.duration_ms, "subagent exited without session_end")
	}

	content := state.last_text
	if len(content) == 0 {
		content = "(subagent returned no text)"
	}
	res := tool_ok(content)
	res.metadata = task_metadata(&state, run.duration_ms)
	return res
}

task_fail_with_state :: proc(state: ^Task_State, duration_ms: int, message: string) -> Tool_Result {
	res := tool_fail(message)
	res.metadata = task_metadata(state, duration_ms)
	return res
}

task_metadata :: proc(state: ^Task_State, duration_ms: int) -> json.Value {
	obj := make(json.Object)
	obj["child_session_id"] = json.String(state.child_session_id)
	obj["stop_reason"] = json.String(state.stop_reason)
	usage_data, _ := json_marshal_utf8(state.usage)
	usage_value, _ := json.parse_string(string(usage_data), .JSON, true)
	obj["usage"] = usage_value
	obj["duration_ms"] = json.Integer(duration_ms)
	return obj
}
