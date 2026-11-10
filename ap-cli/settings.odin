package apcli

import apcore "../ap-core"
import aptools "tools"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// settings 属于应用层配置：一次读取，再拆成 SDK Settings 与工具配置。
// apcore 不打开这个文件，也不认识工具超时/深度字段。
//
// 文件按 JSON5 规格解析，因此 .jsonc 里的注释和尾逗号是合法的。JSON5 比
// JSONC 宽（单引号字符串、十六进制、NaN/Infinity），这里接受超集而不另写
// 一个去注释的预处理器。

known_setting_keys := [16]string {
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
	"image_input",
	"image_max_bytes",
	"stream_include_usage",
	"context_window_tokens",
	"context_reserve_percent",
	"handoff_max_tokens",
}

Loaded_Settings :: struct {
	sdk:  apcore.Settings,
	tool: aptools.Tool_Config,
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
		// 显式 null 按缺失处理
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

// 上下文预算的取值校验。settings 与 --context-window 覆盖都走这里：
// 预算开启时 target = window - max_tokens - reserve 必须为正，否则请求还没
// 发出去就已经注定失败。reserve 按窗口的百分比算出。
validate_context_budget :: proc(settings: apcore.Settings) -> apcore.Error {
	if settings.context_window_tokens < 0 {
		return apcore.errorf(.Usage, "context_window_tokens must be non-negative")
	}
	if settings.context_reserve_percent < 0 || settings.context_reserve_percent > 100 {
		return apcore.errorf(.Usage, "context_reserve_percent must be between 0 and 100")
	}
	if settings.handoff_max_tokens <= 0 {
		return apcore.errorf(.Usage, "handoff_max_tokens must be positive")
	}
	if settings.context_window_tokens <= 0 {
		// 0 表示关闭预算，其余字段不参与计算。
		return apcore.ok_error()
	}
	if settings.context_window_tokens <= settings.max_tokens {
		return apcore.errorf(
			.Usage,
			"context_window_tokens (%d) must be greater than max_tokens (%d)",
			settings.context_window_tokens,
			settings.max_tokens,
		)
	}
	if settings.context_window_tokens <= settings.handoff_max_tokens {
		return apcore.errorf(
			.Usage,
			"context_window_tokens (%d) must be greater than handoff_max_tokens (%d)",
			settings.context_window_tokens,
			settings.handoff_max_tokens,
		)
	}
	// 余量按窗口等比算出，所以这里用实际算出的 token 数判断，
	// 不能拿百分比直接和窗口比较。
	reserve := settings.context_window_tokens * settings.context_reserve_percent / 100
	room := settings.context_window_tokens - settings.max_tokens - reserve
	if room <= 0 {
		return apcore.errorf(
			.Usage,
			"context_window_tokens (%d) leaves no budget: max_tokens (%d) + reserve (%d%% of window = %d) must be smaller",
			settings.context_window_tokens,
			settings.max_tokens,
			settings.context_reserve_percent,
			reserve,
		)
	}
	return apcore.ok_error()
}

// 配置文件候选后缀，按优先级排列：两者同时存在时只用 .jsonc。
SETTINGS_FILE_NAMES := [2]string{"settings.jsonc", "settings.json"}

// 找到实际使用的配置文件。返回空串表示两个候选都不存在；此时报错指向
// settings.json，因为示例和文档都是从它出发的。
find_settings_path :: proc(config_dir: string) -> string {
	for name in SETTINGS_FILE_NAMES {
		path := fmt.tprintf("%s/%s", config_dir, name)
		if os.exists(path) {
			return path
		}
	}
	return ""
}

load_settings :: proc(config_dir: string, require_api_key := true) -> (Loaded_Settings, apcore.Error) {
	loaded := Loaded_Settings {
		sdk = apcore.settings_defaults(),
		tool = aptools.Tool_Config {
			config_dir = config_dir,
			tool_timeout_ms = 120000,
			max_capture_bytes = 67108864,
			image_input = false,
			image_max_bytes = 5242880,
			max_agent_depth = 1,
		},
		path = fmt.tprintf("%s/settings.json", config_dir),
	}
	// .jsonc 优先：它是显式选择加入的注释版本，同时存在时不应被 .json 静默覆盖。
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

	for key in obj {
		known := false
		for known_key in known_setting_keys {
			if key == known_key {
				known = true
				break
			}
		}
		if !known {
			apcore.log_warn("unknown settings field %q in %s ignored", key, loaded.path)
		}
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
	if err := json_get_int(obj, loaded.path, "max_steps", &loaded.sdk.max_steps); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, loaded.path, "max_agent_depth", &loaded.tool.max_agent_depth); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, loaded.path, "max_tokens", &loaded.sdk.max_tokens); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, loaded.path, "tool_timeout_ms", &loaded.tool.tool_timeout_ms); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, loaded.path, "llm_timeout_ms", &loaded.sdk.llm_timeout_ms); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, loaded.path, "blob_threshold_bytes", &loaded.sdk.blob_threshold_bytes); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, loaded.path, "max_capture_bytes", &loaded.tool.max_capture_bytes); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_bool(obj, loaded.path, "image_input", &loaded.tool.image_input); !apcore.is_ok(err) {
		return loaded, err
	}
	if err := json_get_int(obj, loaded.path, "image_max_bytes", &loaded.tool.image_max_bytes); !apcore.is_ok(err) {
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
	if require_api_key && len(loaded.sdk.api_key) == 0 {
		return loaded, apcore.errorf(.Usage, "model API key is missing: set api_key in %s or AP_API_KEY", loaded.path)
	}
	if loaded.sdk.max_steps <= 0 {
		return loaded, apcore.errorf(.Usage, "%s: max_steps must be positive", loaded.path)
	}
	if loaded.tool.max_agent_depth < 0 {
		return loaded, apcore.errorf(.Usage, "%s: max_agent_depth must be non-negative", loaded.path)
	}
	if loaded.sdk.max_tokens <= 0 {
		return loaded, apcore.errorf(.Usage, "%s: max_tokens must be positive", loaded.path)
	}
	if loaded.tool.tool_timeout_ms <= 0 || loaded.sdk.llm_timeout_ms <= 0 {
		return loaded, apcore.errorf(.Usage, "%s: timeouts must be positive", loaded.path)
	}
	if loaded.sdk.blob_threshold_bytes <= 0 ||
	   loaded.tool.max_capture_bytes <= 0 ||
	   loaded.tool.image_max_bytes <= 0 {
		return loaded, apcore.errorf(.Usage, "%s: size limits must be positive", loaded.path)
	}
	if err := validate_context_budget(loaded.sdk); !apcore.is_ok(err) {
		return loaded, err
	}
	loaded.sdk.base_url = strings.trim_right(loaded.sdk.base_url, "/")
	if len(loaded.sdk.base_url) == 0 {
		return loaded, apcore.errorf(.Usage, "%s: base_url must not be empty", loaded.path)
	}
	loaded.tool.model = loaded.sdk.model
	loaded.tool.max_steps = loaded.sdk.max_steps
	return loaded, apcore.ok_error()
}
