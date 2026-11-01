package apcli

import apcore "../ap-core"
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
	s, err := load_settings(dir)
	testing.expect_value(t, err.kind, apcore.Error_Kind.None)
	testing.expect_value(t, s.model, "test-model")
	testing.expect_value(t, s.api_key, "sk-test")
	testing.expect_value(t, s.base_url, "http://127.0.0.1:8788/v1")
	testing.expect_value(t, s.max_steps, 100)
	testing.expect_value(t, s.max_tokens, 8192)
	testing.expect_value(t, s.stream_include_usage, true)
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
	s, err := load_settings(dir)
	testing.expect_value(t, err.kind, apcore.Error_Kind.None)
	testing.expect_value(t, s.api_key, "from-env")
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
