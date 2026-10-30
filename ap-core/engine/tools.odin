package engine

import "../platform"

import "core:encoding/json"
import "core:fmt"
import "core:time"

Tool_Result :: struct {
	ok:          bool,
	content:     string,
	error:       string,
	duration_ms: int,
	exit_code:   Maybe(int),
	metadata:    json.Value,
	fatal:       bool,
}

Tool_Context :: struct {
	cwd:               string,
	project:           Project,
	settings:          ^Settings,
	cancel:            ^platform.Cancel_Token,
	session_id:        string,
	parent_tool_call_id: string,
	agent_name:        string,
	agent_depth:       int,
	config_dir:        string,
	self_exe:          string,
	bash_path:         string,
	model:             string,
	max_steps:         int,
	on_update:         proc(user: rawptr, chunk: string),
	update_user:       rawptr,
	on_progress:       proc(user: rawptr, style: Progress_Style, line: string),
	progress_user:     rawptr,
}

tool_ok :: proc(content: string) -> Tool_Result {
	return {ok = true, content = content}
}

tool_fail :: proc(message: string) -> Tool_Result {
	return {ok = false, error = message}
}

tool_arg_string :: proc(obj: json.Object, name: string) -> (string, Error) {
	value, exists := obj[name]
	if !exists {
		return "", make_error(.Tool, "missing required parameter %q", name)
	}
	text, is_string := value.(json.String)
	if !is_string {
		return "", make_error(.Tool, "parameter %q must be a string", name)
	}
	return string(text), ok_error()
}

tool_arg_optional_string :: proc(obj: json.Object, name: string) -> (Maybe(string), Error) {
	value, exists := obj[name]
	if !exists {
		return nil, ok_error()
	}
	text, is_string := value.(json.String)
	if !is_string {
		return nil, make_error(.Tool, "parameter %q must be a string", name)
	}
	return string(text), ok_error()
}

tool_arg_optional_int :: proc(obj: json.Object, name: string) -> (Maybe(int), Error) {
	value, exists := obj[name]
	if !exists {
		return nil, ok_error()
	}
	number, is_int := value.(json.Integer)
	if !is_int {
		return nil, make_error(.Tool, "parameter %q must be an integer", name)
	}
	return int(number), ok_error()
}

tool_arg_optional_bool :: proc(obj: json.Object, name: string) -> (Maybe(bool), Error) {
	value, exists := obj[name]
	if !exists {
		return nil, ok_error()
	}
	flag, is_bool := value.(json.Boolean)
	if !is_bool {
		return nil, make_error(.Tool, "parameter %q must be a boolean", name)
	}
	return bool(flag), ok_error()
}

tool_execute :: proc(name: string, args: json.Value, ctx: ^Tool_Context) -> Tool_Result {
	start := time.tick_now()
	obj, is_obj := args.(json.Object)
	if !is_obj {
		return tool_fail("tool arguments must be a JSON object")
	}
	result: Tool_Result
	switch name {
	case "read_file":
		result = tool_read_file(obj, ctx)
	case "write_file":
		result = tool_write_file(obj, ctx)
	case "edit_file":
		result = tool_edit_file(obj, ctx)
	case "bash":
		result = tool_bash(obj, ctx)
	case "task":
		result = tool_task(obj, ctx)
	case:
		result = tool_fail(fmt.tprintf("unknown tool %q", name))
	}
	result.duration_ms = int(time.tick_since(start) / time.Millisecond)
	return result
}

arg_error :: proc(err: Error) -> Tool_Result {
	return tool_fail(err.message)
}
