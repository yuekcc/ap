package apcli

import apcore "../ap-core"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// settings.json 属于应用层配置：由 ap-cli 读取、校验，再把结果作为
// apcore.Settings 传给 SDK。apcore 不打开这个文件。

known_setting_keys := [11]string {
	"model",
	"base_url",
	"api_key",
	"max_steps",
	"max_agent_depth",
	"max_tokens",
	"tool_timeout_ms",
	"llm_timeout_ms",
	"blob_threshold_bytes",
	"max_capture_bytes",
	"stream_include_usage",
}

json_get_string :: proc(obj: json.Object, key: string, out: ^string) -> apcore.Error {
	value, exists := obj[key]
	if !exists {
		return apcore.ok_error()
	}
	#partial switch v in value {
	case json.String:
		out^ = string(v)
	case json.Null:
		// 显式 null 按缺失处理
	case:
		return apcore.errorf(.Usage, "settings.json: %q must be a string", key)
	}
	return apcore.ok_error()
}

json_get_int :: proc(obj: json.Object, key: string, out: ^int) -> apcore.Error {
	value, exists := obj[key]
	if !exists {
		return apcore.ok_error()
	}
	#partial switch v in value {
	case json.Integer:
		out^ = int(v)
	case json.Float:
		n := int(v)
		if f64(n) != f64(v) {
			return apcore.errorf(.Usage, "settings.json: %q must be an integer", key)
		}
		out^ = n
	case json.Null:
	case:
		return apcore.errorf(.Usage, "settings.json: %q must be an integer", key)
	}
	return apcore.ok_error()
}

json_get_bool :: proc(obj: json.Object, key: string, out: ^bool) -> apcore.Error {
	value, exists := obj[key]
	if !exists {
		return apcore.ok_error()
	}
	#partial switch v in value {
	case json.Boolean:
		out^ = bool(v)
	case json.Null:
	case:
		return apcore.errorf(.Usage, "settings.json: %q must be a boolean", key)
	}
	return apcore.ok_error()
}

load_settings :: proc(config_dir: string) -> (apcore.Settings, apcore.Error) {
	s := apcore.settings_defaults()
	s.path = fmt.tprintf("%s/settings.json", config_dir)
	data, derr := os.read_entire_file_from_path(s.path, context.allocator)
	if derr != nil {
		return s, apcore.errorf(
			.Usage,
			"cannot read config file %s: %v\nhint: create it with model and api_key (see settings.example.json), or pass --config-dir",
			s.path,
			derr,
		)
	}
	value, perr := json.parse_string(string(data), .JSON, true)
	if perr != nil {
		return s, apcore.errorf(.Usage, "invalid JSON in %s: %v", s.path, perr)
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return s, apcore.errorf(.Usage, "%s must contain a JSON object", s.path)
	}

	for key in obj {
		known := false
		for known_key in known_setting_keys {
			if key == known_key {
				known = true
				break
			}
		}
		if !known {
			apcore.log_warn("unknown settings.json field %q ignored", key)
		}
	}

	if err := json_get_string(obj, "model", &s.model); !apcore.is_ok(err) {
		return s, err
	}
	if err := json_get_string(obj, "base_url", &s.base_url); !apcore.is_ok(err) {
		return s, err
	}
	if err := json_get_string(obj, "api_key", &s.api_key); !apcore.is_ok(err) {
		return s, err
	}
	if err := json_get_int(obj, "max_steps", &s.max_steps); !apcore.is_ok(err) {
		return s, err
	}
	if err := json_get_int(obj, "max_agent_depth", &s.max_agent_depth); !apcore.is_ok(err) {
		return s, err
	}
	if err := json_get_int(obj, "max_tokens", &s.max_tokens); !apcore.is_ok(err) {
		return s, err
	}
	if err := json_get_int(obj, "tool_timeout_ms", &s.tool_timeout_ms); !apcore.is_ok(err) {
		return s, err
	}
	if err := json_get_int(obj, "llm_timeout_ms", &s.llm_timeout_ms); !apcore.is_ok(err) {
		return s, err
	}
	if err := json_get_int(obj, "blob_threshold_bytes", &s.blob_threshold_bytes); !apcore.is_ok(err) {
		return s, err
	}
	if err := json_get_int(obj, "max_capture_bytes", &s.max_capture_bytes); !apcore.is_ok(err) {
		return s, err
	}
	if err := json_get_bool(obj, "stream_include_usage", &s.stream_include_usage); !apcore.is_ok(err) {
		return s, err
	}

	if env_key := os.get_env("AP_API_KEY", context.allocator); len(env_key) > 0 {
		s.api_key = env_key
	}
	if len(s.model) == 0 {
		return s, apcore.errorf(.Usage, "settings.json: model is required")
	}
	if len(s.api_key) == 0 {
		return s, apcore.errorf(.Usage, "model API key is missing: set api_key in %s or AP_API_KEY", s.path)
	}
	if s.max_steps <= 0 {
		return s, apcore.errorf(.Usage, "settings.json: max_steps must be positive")
	}
	if s.max_agent_depth < 0 {
		return s, apcore.errorf(.Usage, "settings.json: max_agent_depth must be non-negative")
	}
	if s.max_tokens <= 0 {
		return s, apcore.errorf(.Usage, "settings.json: max_tokens must be positive")
	}
	if s.tool_timeout_ms <= 0 || s.llm_timeout_ms <= 0 {
		return s, apcore.errorf(.Usage, "settings.json: timeouts must be positive")
	}
	if s.blob_threshold_bytes <= 0 || s.max_capture_bytes <= 0 {
		return s, apcore.errorf(.Usage, "settings.json: size limits must be positive")
	}
	s.base_url = strings.trim_right(s.base_url, "/")
	if len(s.base_url) == 0 {
		return s, apcore.errorf(.Usage, "settings.json: base_url must not be empty")
	}
	return s, apcore.ok_error()
}
