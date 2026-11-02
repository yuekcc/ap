package tool

import "../platform"

import "core:encoding/json"

// 工具参数助手。错误类型用 platform.Error，避免 tool 包依赖 engine。

tool_arg_string :: proc(obj: json.Object, name: string) -> (string, platform.Error) {
	value, exists := obj[name]
	if !exists {
		return "", platform.errorf("missing required parameter %q", name)
	}
	text, is_string := value.(json.String)
	if !is_string {
		return "", platform.errorf("parameter %q must be a string", name)
	}
	return string(text), platform.ok_error()
}

tool_arg_optional_string :: proc(obj: json.Object, name: string) -> (Maybe(string), platform.Error) {
	value, exists := obj[name]
	if !exists {
		return nil, platform.ok_error()
	}
	text, is_string := value.(json.String)
	if !is_string {
		return nil, platform.errorf("parameter %q must be a string", name)
	}
	return string(text), platform.ok_error()
}

tool_arg_optional_int :: proc(obj: json.Object, name: string) -> (Maybe(int), platform.Error) {
	value, exists := obj[name]
	if !exists {
		return nil, platform.ok_error()
	}
	number, is_int := value.(json.Integer)
	if !is_int {
		return nil, platform.errorf("parameter %q must be an integer", name)
	}
	return int(number), platform.ok_error()
}

tool_arg_optional_bool :: proc(obj: json.Object, name: string) -> (Maybe(bool), platform.Error) {
	value, exists := obj[name]
	if !exists {
		return nil, platform.ok_error()
	}
	flag, is_bool := value.(json.Boolean)
	if !is_bool {
		return nil, platform.errorf("parameter %q must be a boolean", name)
	}
	return bool(flag), platform.ok_error()
}
