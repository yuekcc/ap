package engine

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
test_settings_defaults_and_defaults_file :: proc(t: ^testing.T) {
	dir := test_temp_dir("settings")
	defer test_cleanup(dir)
	test_write_file(
		fmt.tprintf("%s/settings.json", dir),
		`{"model":"test-model","api_key":"sk-test","base_url":"http://127.0.0.1:8788/v1/"}`,
	)
	s, err := load_settings(dir)
	testing.expect_value(t, err.kind, Error_Kind.None)
	testing.expect_value(t, s.model, "test-model")
	testing.expect_value(t, s.api_key, "sk-test")
	testing.expect_value(t, s.base_url, "http://127.0.0.1:8788/v1")
	testing.expect_value(t, s.max_steps, 100)
	testing.expect_value(t, s.max_tokens, 8192)
	testing.expect_value(t, s.stream_include_usage, true)
}

@(test)
test_settings_missing_file_has_hint :: proc(t: ^testing.T) {
	dir := test_temp_dir("settings-missing")
	defer test_cleanup(dir)
	_, err := load_settings(dir)
	testing.expect_value(t, err.kind, Error_Kind.Usage)
	testing.expect(t, test_contains(err.message, "hint:"))
	testing.expect(t, test_contains(err.message, "settings.json"))
}

@(test)
test_settings_env_api_key_overrides :: proc(t: ^testing.T) {
	dir := test_temp_dir("settings-env")
	defer test_cleanup(dir)
	test_write_file(fmt.tprintf("%s/settings.json", dir), `{"model":"m","api_key":"from-file"}`)
	os.set_env("AP_API_KEY", "from-env")
	defer os.unset_env("AP_API_KEY")
	s, err := load_settings(dir)
	testing.expect_value(t, err.kind, Error_Kind.None)
	testing.expect_value(t, s.api_key, "from-env")
}

@(test)
test_settings_missing_model_and_key :: proc(t: ^testing.T) {
	dir := test_temp_dir("settings-bad")
	defer test_cleanup(dir)
	test_write_file(fmt.tprintf("%s/settings.json", dir), `{"api_key":"k"}`)
	_, err := load_settings(dir)
	testing.expect_value(t, err.kind, Error_Kind.Usage)

	test_write_file(fmt.tprintf("%s/settings.json", dir), `{"model":"m"}`)
	_, err2 := load_settings(dir)
	testing.expect_value(t, err2.kind, Error_Kind.Usage)
}

@(test)
test_settings_type_error :: proc(t: ^testing.T) {
	dir := test_temp_dir("settings-type")
	defer test_cleanup(dir)
	test_write_file(fmt.tprintf("%s/settings.json", dir), `{"model":"m","api_key":"k","max_steps":"ten"}`)
	_, err := load_settings(dir)
	testing.expect_value(t, err.kind, Error_Kind.Usage)
}

@(test)
test_agent_definition_roundtrip :: proc(t: ^testing.T) {
	content := "---\nname: scout\ndescription: 搜索代码\ntools: read_file, bash\nmodel: small\nmax_steps: 30\n---\n\n你是搜索代理。\n"
	def, err := parse_agent_definition("C:/x/scout.md", "scout", content)
	testing.expect_value(t, err.kind, Error_Kind.None)
	testing.expect_value(t, def.name, "scout")
	testing.expect_value(t, def.description, "搜索代码")
	testing.expect_value(t, len(def.tools), 2)
	testing.expect(t, agent_has_tool(def, "read_file"))
	testing.expect(t, !agent_has_tool(def, "task"))
	testing.expect_value(t, def.model.?, "small")
	testing.expect_value(t, def.max_steps.?, 30)
	testing.expect_value(t, def.body, "你是搜索代理。\n")
}

@(test)
test_agent_definition_errors :: proc(t: ^testing.T) {
	_, err := parse_agent_definition("x.md", "x", "---\nname: x\n---\nbody")
	testing.expect_value(t, err.kind, Error_Kind.Usage)

	_, err2 := parse_agent_definition("x.md", "x", "---\nname: x\ndescription: d\ntools: grep\n---\n")
	testing.expect_value(t, err2.kind, Error_Kind.Usage)

	_, err3 := parse_agent_definition("x.md", "y", "---\nname: x\ndescription: d\n---\n")
	testing.expect_value(t, err3.kind, Error_Kind.Usage)

	_, err4 := parse_agent_definition("x.md", "x", "no frontmatter")
	testing.expect_value(t, err4.kind, Error_Kind.Usage)
}

@(test)
test_agent_general_builtin_and_override :: proc(t: ^testing.T) {
	dir := test_temp_dir("agents")
	defer test_cleanup(dir)
	def, err := load_agent(dir, "general")
	testing.expect_value(t, err.kind, Error_Kind.None)
	testing.expect(t, def.builtin)
	testing.expect_value(t, len(def.tools), 5)

	test_write_file(
		fmt.tprintf("%s/agents/general.md", dir),
		"---\nname: general\ndescription: overridden\ntools: read_file\n---\n正文\n",
	)
	def2, err2 := load_agent(dir, "general")
	testing.expect_value(t, err2.kind, Error_Kind.None)
	testing.expect(t, !def2.builtin)
	testing.expect_value(t, def2.description, "overridden")
	testing.expect_value(t, len(def2.tools), 1)
}

@(test)
test_agent_unknown_name :: proc(t: ^testing.T) {
	dir := test_temp_dir("agents-missing")
	defer test_cleanup(dir)
	_, err := load_agent(dir, "nope")
	testing.expect_value(t, err.kind, Error_Kind.Usage)
}
