package aptui

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_load_tui_settings_missing_file :: proc(t: ^testing.T) {
	dir := test_temp_dir("settings-missing")
	defer os.remove_all(dir)

	settings, warning := load_tui_settings(dir)
	testing.expect_value(t, settings.enable_glow, false)
	testing.expect_value(t, warning, "")
}

@(test)
test_load_tui_settings_prefers_jsonc :: proc(t: ^testing.T) {
	dir := test_temp_dir("settings-jsonc")
	defer os.remove_all(dir)

	test_write_file(test_settings_json_path(dir, "settings.json"), `{"tui":{"enable_glow":true}}`)
	test_write_file(test_settings_json_path(dir, "settings.jsonc"), `{"tui":{"enable_glow":false}}`)
	settings, warning := load_tui_settings(dir)
	testing.expect_value(t, warning, "")
	testing.expect_value(t, settings.enable_glow, false)

	os.remove(test_settings_json_path(dir, "settings.jsonc"))
	settings2, warning2 := load_tui_settings(dir)
	testing.expect_value(t, warning2, "")
	testing.expect_value(t, settings2.enable_glow, true)
}

test_settings_json_path :: proc(dir, name: string) -> string {
	return strings.concatenate({dir, "/", name}, context.temp_allocator)
}

@(test)
test_load_tui_settings_reports_type_errors :: proc(t: ^testing.T) {
	dir := test_temp_dir("settings-type")
	defer os.remove_all(dir)

	path := test_settings_json_path(dir, "settings.json")
	test_write_file(path, `{"tui":{"enable_glow":"yes"}}`)
	settings, warning := load_tui_settings(dir)
	testing.expect_value(t, settings.enable_glow, false)
	testing.expect(t, strings.contains(warning, "tui.enable_glow"))

	test_write_file(path, `{"tui":true}`)
	_, warning2 := load_tui_settings(dir)
	testing.expect(t, strings.contains(warning2, "must be an object"))

	// 显式 null 与 ap-cli 的规则一致，按缺失处理。
	test_write_file(path, `{"tui":null}`)
	settings2, warning3 := load_tui_settings(dir)
	testing.expect_value(t, settings2.enable_glow, false)
	testing.expect_value(t, warning3, "")

	test_write_file(path, `{"tui":{"enable_glow":null}}`)
	settings3, warning4 := load_tui_settings(dir)
	testing.expect_value(t, settings3.enable_glow, false)
	testing.expect_value(t, warning4, "")

	test_write_file(path, `{"tui":`)
	_, warning5 := load_tui_settings(dir)
	testing.expect(t, strings.contains(warning5, "invalid JSON"))
}
