package apcli

import apcore "../ap-core"
import aptools "tools"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

settings_write_file :: proc(path, content: string) {
	if err := os.write_entire_file_from_bytes(path, transmute([]byte)content); err != nil {
		panic("cannot write test file")
	}
}

@(test)
test_settings_defaults_and_defaults_file :: proc(t: ^testing.T) {
	dir := cli_temp_dir(t, "settings")
	defer os.remove_all(dir)
	settings_write_file(
		fmt.tprintf("%s/settings.json", dir),
		`{"model":"test-model","api_key":"sk-test","base_url":"http://127.0.0.1:8788/v1/"}`,
	)
	loaded, err := load_settings(dir)
	testing.expect_value(t, err.kind, apcore.Error_Kind.None)
	testing.expect_value(t, loaded.sdk.model, "test-model")
	testing.expect_value(t, loaded.sdk.api_key, "sk-test")
	testing.expect_value(t, loaded.sdk.base_url, "http://127.0.0.1:8788/v1")
	testing.expect_value(t, loaded.sdk.max_steps, 100)
	testing.expect_value(t, loaded.sdk.max_tokens, 65536)
	testing.expect_value(t, loaded.sdk.context_window_tokens, 1048576)
	testing.expect_value(t, loaded.sdk.stream_include_usage, true)
	testing.expect_value(t, loaded.tool.config_dir, dir)
	testing.expect_value(t, loaded.tool.max_agent_depth, 1)
	testing.expect_value(t, loaded.tool.tool_timeout_ms, 120000)
	testing.expect_value(t, loaded.tool.max_capture_bytes, 67108864)
}

@(test)
test_settings_tool_fields_are_split_out :: proc(t: ^testing.T) {
	dir := cli_temp_dir(t, "settings-tools")
	defer os.remove_all(dir)
	settings_write_file(
		fmt.tprintf("%s/settings.json", dir),
		`{"model":"m","api_key":"k","max_agent_depth":3,"tool_timeout_ms":5000,"max_capture_bytes":1234}`,
	)
	loaded, err := load_settings(dir)
	testing.expect_value(t, err.kind, apcore.Error_Kind.None)
	testing.expect_value(t, loaded.tool.max_agent_depth, 3)
	testing.expect_value(t, loaded.tool.tool_timeout_ms, 5000)
	testing.expect_value(t, loaded.tool.max_capture_bytes, 1234)
}

@(test)
test_settings_missing_file_has_hint :: proc(t: ^testing.T) {
	dir := cli_temp_dir(t, "settings-missing")
	defer os.remove_all(dir)
	_, err := load_settings(dir)
	testing.expect_value(t, err.kind, apcore.Error_Kind.Usage)
	testing.expect(t, strings.contains(err.message, "hint:"))
	testing.expect(t, strings.contains(err.message, "settings.json"))
}

@(test)
test_settings_env_api_key_overrides :: proc(t: ^testing.T) {
	dir := cli_temp_dir(t, "settings-env")
	defer os.remove_all(dir)
	settings_write_file(fmt.tprintf("%s/settings.json", dir), `{"model":"m","api_key":"from-file"}`)
	_ = os.set_env("AP_API_KEY", "from-env")
	defer os.unset_env("AP_API_KEY")
	loaded, err := load_settings(dir)
	testing.expect_value(t, err.kind, apcore.Error_Kind.None)
	testing.expect_value(t, loaded.sdk.api_key, "from-env")
}

@(test)
test_settings_missing_model_and_key :: proc(t: ^testing.T) {
	dir := cli_temp_dir(t, "settings-bad")
	defer os.remove_all(dir)
	settings_write_file(fmt.tprintf("%s/settings.json", dir), `{"api_key":"k"}`)
	_, err := load_settings(dir)
	testing.expect_value(t, err.kind, apcore.Error_Kind.Usage)

	settings_write_file(fmt.tprintf("%s/settings.json", dir), `{"model":"m"}`)
	_, err2 := load_settings(dir)
	testing.expect_value(t, err2.kind, apcore.Error_Kind.Usage)

	// --print-system-prompt 不调用模型，不要求 API key。
	loaded, err3 := load_settings(dir, false)
	testing.expect_value(t, err3.kind, apcore.Error_Kind.None)
	testing.expect_value(t, loaded.sdk.model, "m")
}

@(test)
test_settings_type_error :: proc(t: ^testing.T) {
	dir := cli_temp_dir(t, "settings-type")
	defer os.remove_all(dir)
	settings_write_file(
		fmt.tprintf("%s/settings.json", dir),
		`{"model":"m","api_key":"k","max_steps":"ten"}`,
	)
	_, err := load_settings(dir)
	testing.expect_value(t, err.kind, apcore.Error_Kind.Usage)
}

// ap 面向 1M 上下文、64K 单次输出的模型。context_window_tokens 不能小于
// 单次输出上限，否则预算公式 target = window - max_tokens - reserve 必为负。
@(test)
test_settings_context_window_validation :: proc(t: ^testing.T) {
	dir := cli_temp_dir(t, "settings-window")
	defer os.remove_all(dir)

	// 0 表示关闭预算，合法。
	settings_write_file(fmt.tprintf("%s/settings.json", dir), `{"model":"m","api_key":"k","context_window_tokens":0}`)
	loaded, err := load_settings(dir)
	testing.expect_value(t, err.kind, apcore.Error_Kind.None)
	testing.expect_value(t, loaded.sdk.context_window_tokens, 0)

	// 等于或小于 max_tokens 是配置错误。
	settings_write_file(
		fmt.tprintf("%s/settings.json", dir),
		`{"model":"m","api_key":"k","max_tokens":65536,"context_window_tokens":65536}`,
	)
	_, err2 := load_settings(dir)
	testing.expect_value(t, err2.kind, apcore.Error_Kind.Usage)

	settings_write_file(
		fmt.tprintf("%s/settings.json", dir),
		`{"model":"m","api_key":"k","context_window_tokens":-1}`,
	)
	_, err3 := load_settings(dir)
	testing.expect_value(t, err3.kind, apcore.Error_Kind.Usage)
}

// 默认值就是规格：ap 面向 1M 上下文、64K 输出的模型，预算与自动交接默认启用。
// 这几个数字被改小会让预算公式与交接阈值失去意义，所以单独钉住。
@(test)
test_settings_context_budget_defaults :: proc(t: ^testing.T) {
	settings := apcore.settings_defaults()
	testing.expect_value(t, settings.max_tokens, 65536)
	testing.expect_value(t, settings.context_window_tokens, 1048576)
	// 预算逻辑尚未实现，这里只钉常量；实现后它们参与 target 计算。
	testing.expect_value(t, apcore.DEFAULT_CONTEXT_RESERVE_TOKENS, 32768)
	testing.expect_value(t, apcore.DEFAULT_HANDOFF_MAX_TOKENS, 16384)
	testing.expect_value(t, apcore.HANDOFF_TRIGGER_PERCENT, 90)
	testing.expect_value(t, apcore.CONTEXT_ELIDE_TARGET_PERCENT, 80)
}

// 测试用的工具配置：只要 max_agent_depth 有效即可，工具本身用空注册表。
apcli_test_tool_config :: proc(dir: string) -> aptools.Tool_Config {
	return {
		config_dir = dir,
		tool_timeout_ms = 1000,
		max_capture_bytes = 4096,
		max_agent_depth = 1,
	}
}
