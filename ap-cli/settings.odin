package apcli

import apcore "../ap-core"
import aptools "tools"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// settings.json 属于应用层配置：一次读取，再拆成 SDK Settings 与工具配置。
// apcore 不打开这个文件，也不认识工具超时/深度字段。

known_setting_keys := [12]string {
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
	"context_window_tokens",
}

Loaded_Settings :: struct {
	sdk:  apcore.Settings,
	tool: aptools.Tool_Config,
	path: string,
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

load_settings :: proc(config_dir: string, require_api_key := true) -> (Loaded_Settings, apcore.Error) {
	loaded := Loaded_Settings {
		sdk = apcore.settings_defaults(),
		tool = aptools.Tool_Config {
			config_dir = config_dir,
			tool_timeout_ms = 120000,
			max_capture_bytes = 67108864,
			max_agent_depth = 1,
		},
		path = fmt.tprintf("%s/settings.json", config_dir),
	}
	data, derr := os.read_entire_file_from_path(loaded.path, context.allocator)
	if derr != nil {
		return loaded, apcore.errorf(
			.Usage,
			"cannot read config file %s: %v\nhint: create it with model and api_key (see settings.example.json), or pass --config-dir",
			loaded.path,
			derr,
		)
	}
	value, perr := json.parse_string(string(data), .JSON, true)
	if perr != nil {
		return loaded, apcore.errorf(.Usage, "invalid JSON in %s: %v", loaded.path, perr)
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return loaded, apcore.errorf(.Usage, "%s must contain a JSON object", loaded.path)
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

	if err := json_get_string(obj, "model", &loaded.sdk.model); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_string(obj, "base_url", &loaded.sdk.base_url); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_string(obj, "api_key", &loaded.sdk.api_key); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, "max_steps", &loaded.sdk.max_steps); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, "max_agent_depth", &loaded.tool.max_agent_depth); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, "max_tokens", &loaded.sdk.max_tokens); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, "tool_timeout_ms", &loaded.tool.tool_timeout_ms); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, "llm_timeout_ms", &loaded.sdk.llm_timeout_ms); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, "blob_threshold_bytes", &loaded.sdk.blob_threshold_bytes); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, "max_capture_bytes", &loaded.tool.max_capture_bytes); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_bool(obj, "stream_include_usage", &loaded.sdk.stream_include_usage); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, "context_window_tokens", &loaded.sdk.context_window_tokens); !apcore.is_ok(err) {
		return loaded, err
	}

	if env_key := os.get_env("AP_API_KEY", context.allocator); len(env_key) > 0 {
		loaded.sdk.api_key = env_key
	}
	if len(loaded.sdk.model) == 0 {
		return loaded, apcore.errorf(.Usage, "settings.json: model is required")
	}
	if require_api_key && len(loaded.sdk.api_key) == 0 {
		return loaded, apcore.errorf(.Usage, "model API key is missing: set api_key in %s or AP_API_KEY", loaded.path)
	}
	if loaded.sdk.max_steps <= 0 {
		return loaded, apcore.errorf(.Usage, "settings.json: max_steps must be positive")
	}
	if loaded.tool.max_agent_depth < 0 {
		return loaded, apcore.errorf(.Usage, "settings.json: max_agent_depth must be non-negative")
	}
	if loaded.sdk.max_tokens <= 0 {
		return loaded, apcore.errorf(.Usage, "settings.json: max_tokens must be positive")
	}
	if loaded.tool.tool_timeout_ms <= 0 || loaded.sdk.llm_timeout_ms <= 0 {
		return loaded, apcore.errorf(.Usage, "settings.json: timeouts must be positive")
	}
	if loaded.sdk.blob_threshold_bytes <= 0 || loaded.tool.max_capture_bytes <= 0 {
		return loaded, apcore.errorf(.Usage, "settings.json: size limits must be positive")
	}
	if loaded.sdk.context_window_tokens < 0 {
		return loaded, apcore.errorf(.Usage, "settings.json: context_window_tokens must be non-negative")
	}
	if loaded.sdk.context_window_tokens > 0 && loaded.sdk.context_window_tokens <= loaded.sdk.max_tokens {
		return loaded, apcore.errorf(
			.Usage,
			"settings.json: context_window_tokens (%d) must be greater than max_tokens (%d)",
			loaded.sdk.context_window_tokens,
			loaded.sdk.max_tokens,
		)
	}
	loaded.sdk.base_url = strings.trim_right(loaded.sdk.base_url, "/")
	if len(loaded.sdk.base_url) == 0 {
		return loaded, apcore.errorf(.Usage, "settings.json: base_url must not be empty")
	}
	loaded.tool.model = loaded.sdk.model
	loaded.tool.max_steps = loaded.sdk.max_steps
	return loaded, apcore.ok_error()
}
