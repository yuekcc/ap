package magi

import apcore "../ap-core"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// magi 复用 ap 的 $AP_CONFIG/settings.json 与 settings.jsonc，但只读取自己
// 需要的字段。这里不读工具超时、agent 深度等应用层配置；apcore 不认识这个文件。
// 文件按 JSON5 规格解析，与 ap-cli 保持一致（注释、尾逗号合法）。

Loaded_Settings :: struct {
	sdk:  apcore.Settings,
	path: string,
}

json_get_string :: proc(obj: json.Object, path, key: string, out: ^string) -> apcore.Error {
	value, exists := obj[key]
	if !exists {
		return apcore.ok_error()
	}
	#partial switch v in value {
	case json.String:
		out^ = string(v)
	case json.Null:
	case:
		return apcore.errorf(.Usage, "%s: %q must be a string", path, key)
	}
	return apcore.ok_error()
}

json_get_int :: proc(obj: json.Object, path, key: string, out: ^int) -> apcore.Error {
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
			return apcore.errorf(.Usage, "%s: %q must be an integer", path, key)
		}
		out^ = n
	case json.Null:
	case:
		return apcore.errorf(.Usage, "%s: %q must be an integer", path, key)
	}
	return apcore.ok_error()
}

json_get_bool :: proc(obj: json.Object, path, key: string, out: ^bool) -> apcore.Error {
	value, exists := obj[key]
	if !exists {
		return apcore.ok_error()
	}
	#partial switch v in value {
	case json.Boolean:
		out^ = bool(v)
	case json.Null:
	case:
		return apcore.errorf(.Usage, "%s: %q must be a boolean", path, key)
	}
	return apcore.ok_error()
}

// 与 ap-cli 相同的候选顺序：两者同时存在时只用 .jsonc。
SETTINGS_FILE_NAMES := [2]string{"settings.jsonc", "settings.json"}

find_settings_path :: proc(config_dir: string) -> string {
	for name in SETTINGS_FILE_NAMES {
		path := fmt.tprintf("%s/%s", config_dir, name)
		if os.exists(path) {
			return path
		}
	}
	return ""
}

load_settings :: proc(config_dir: string) -> (Loaded_Settings, apcore.Error) {
	loaded := Loaded_Settings {
		sdk  = apcore.settings_defaults(),
		path = fmt.tprintf("%s/settings.json", config_dir),
	}
	if found := find_settings_path(config_dir); len(found) > 0 {
		loaded.path = found
	}

	data, derr := os.read_entire_file_from_path(loaded.path, context.allocator)
	if derr != nil {
		return loaded, apcore.errorf(
			.Usage,
			"cannot read config file %s: %v\nhint: create settings.json or settings.jsonc with model and api_key (see settings.example.json), or pass --config-dir",
			loaded.path,
			derr,
		)
	}
	// JSON5 是超集：注释、尾逗号、单引号、十六进制数字、NaN/Infinity 都能过。
	value, perr := json.parse_string(string(data), .JSON5, true)
	if perr != nil {
		return loaded, apcore.errorf(.Usage, "invalid JSON in %s: %v", loaded.path, perr)
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return loaded, apcore.errorf(.Usage, "%s must contain a JSON object", loaded.path)
	}

	if err := json_get_string(obj, loaded.path, "model", &loaded.sdk.model); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_string(obj, loaded.path, "base_url", &loaded.sdk.base_url); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_string(obj, loaded.path, "api_key", &loaded.sdk.api_key); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, loaded.path, "max_tokens", &loaded.sdk.max_tokens); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, loaded.path, "llm_timeout_ms", &loaded.sdk.llm_timeout_ms); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, loaded.path, "blob_threshold_bytes", &loaded.sdk.blob_threshold_bytes); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_bool(obj, loaded.path, "stream_include_usage", &loaded.sdk.stream_include_usage); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, loaded.path, "context_window_tokens", &loaded.sdk.context_window_tokens); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, loaded.path, "context_reserve_percent", &loaded.sdk.context_reserve_percent); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, loaded.path, "handoff_max_tokens", &loaded.sdk.handoff_max_tokens); !apcore.is_ok(err) {
		return loaded, err
	}

	if env_key := os.get_env("AP_API_KEY", context.allocator); len(env_key) > 0 {
		loaded.sdk.api_key = env_key
	}
	if len(loaded.sdk.model) == 0 {
		return loaded, apcore.errorf(.Usage, "%s: model is required", loaded.path)
	}
	if len(loaded.sdk.api_key) == 0 {
		return loaded, apcore.errorf(
			.Usage,
			"model API key is missing: set api_key in %s or AP_API_KEY",
			loaded.path,
		)
	}
	if loaded.sdk.max_tokens <= 0 {
		return loaded, apcore.errorf(.Usage, "%s: max_tokens must be positive", loaded.path)
	}
	if loaded.sdk.llm_timeout_ms <= 0 {
		return loaded, apcore.errorf(.Usage, "%s: llm_timeout_ms must be positive", loaded.path)
	}
	if loaded.sdk.blob_threshold_bytes <= 0 {
		return loaded, apcore.errorf(.Usage, "%s: blob_threshold_bytes must be positive", loaded.path)
	}
	if loaded.sdk.context_window_tokens < 0 {
		return loaded, apcore.errorf(.Usage, "%s: context_window_tokens must be non-negative", loaded.path)
	}
	if loaded.sdk.context_reserve_percent < 0 || loaded.sdk.context_reserve_percent > 100 {
		return loaded, apcore.errorf(.Usage, "%s: context_reserve_percent must be between 0 and 100", loaded.path)
	}
	if loaded.sdk.handoff_max_tokens <= 0 {
		return loaded, apcore.errorf(.Usage, "%s: handoff_max_tokens must be positive", loaded.path)
	}
	if loaded.sdk.context_window_tokens > 0 {
		// 成员即使不交接也要过预算：target 为负会让三个角色同时失败。
		if loaded.sdk.context_window_tokens <= loaded.sdk.max_tokens {
			return loaded, apcore.errorf(
				.Usage,
				"%s: context_window_tokens (%d) must be greater than max_tokens (%d)",
				loaded.path,
				loaded.sdk.context_window_tokens,
				loaded.sdk.max_tokens,
			)
		}
		reserve := loaded.sdk.context_window_tokens * loaded.sdk.context_reserve_percent / 100
		room := loaded.sdk.context_window_tokens - loaded.sdk.max_tokens - reserve
		if room <= 0 {
			return loaded, apcore.errorf(
				.Usage,
				"%s: context_window_tokens (%d) leaves no budget: max_tokens (%d) + reserve (%d%% of window = %d) must be smaller",
				loaded.path,
				loaded.sdk.context_window_tokens,
				loaded.sdk.max_tokens,
				loaded.sdk.context_reserve_percent,
				reserve,
			)
		}
	}
	loaded.sdk.base_url = strings.trim_right(loaded.sdk.base_url, "/")
	if len(loaded.sdk.base_url) == 0 {
		return loaded, apcore.errorf(.Usage, "%s: base_url must not be empty", loaded.path)
	}
	return loaded, apcore.ok_error()
}
