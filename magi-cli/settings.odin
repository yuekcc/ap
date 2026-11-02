package magicli

import apcore "../ap-core"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// magi-cli 复用 ap 的 $AP_CONFIG/settings.json，但只读取自己需要的字段。
// 这里不读工具超时、agent 深度等应用层配置；apcore 不认识这个文件。

Loaded_Settings :: struct {
	sdk:  apcore.Settings,
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

load_settings :: proc(config_dir: string) -> (Loaded_Settings, apcore.Error) {
	loaded := Loaded_Settings {
		sdk  = apcore.settings_defaults(),
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

	if err := json_get_string(obj, "model", &loaded.sdk.model); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_string(obj, "base_url", &loaded.sdk.base_url); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_string(obj, "api_key", &loaded.sdk.api_key); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, "max_tokens", &loaded.sdk.max_tokens); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, "llm_timeout_ms", &loaded.sdk.llm_timeout_ms); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, "blob_threshold_bytes", &loaded.sdk.blob_threshold_bytes); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_bool(obj, "stream_include_usage", &loaded.sdk.stream_include_usage); !apcore.is_ok(err) {
		return loaded, err
	}

	if env_key := os.get_env("AP_API_KEY", context.allocator); len(env_key) > 0 {
		loaded.sdk.api_key = env_key
	}
	if len(loaded.sdk.model) == 0 {
		return loaded, apcore.errorf(.Usage, "settings.json: model is required")
	}
	if len(loaded.sdk.api_key) == 0 {
		return loaded, apcore.errorf(
			.Usage,
			"model API key is missing: set api_key in %s or AP_API_KEY",
			loaded.path,
		)
	}
	if loaded.sdk.max_tokens <= 0 {
		return loaded, apcore.errorf(.Usage, "settings.json: max_tokens must be positive")
	}
	if loaded.sdk.llm_timeout_ms <= 0 {
		return loaded, apcore.errorf(.Usage, "settings.json: llm_timeout_ms must be positive")
	}
	if loaded.sdk.blob_threshold_bytes <= 0 {
		return loaded, apcore.errorf(.Usage, "settings.json: blob_threshold_bytes must be positive")
	}
	loaded.sdk.base_url = strings.trim_right(loaded.sdk.base_url, "/")
	if len(loaded.sdk.base_url) == 0 {
		return loaded, apcore.errorf(.Usage, "settings.json: base_url must not be empty")
	}
	return loaded, apcore.ok_error()
}
