package ap

import "core:fmt"
import "core:os"
import "core:strings"
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
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, s.model, "test-model")
	testing.expect_value(t, s.api_key, "sk-test")
	testing.expect_value(t, s.base_url, "http://127.0.0.1:8788/v1")
	testing.expect_value(t, s.max_steps, 100)
	testing.expect_value(t, s.max_tokens, 8192)
	testing.expect_value(t, s.stream_include_usage, true)
}

@(test)
test_settings_env_api_key_overrides :: proc(t: ^testing.T) {
	dir := test_temp_dir("settings-env")
	defer test_cleanup(dir)
	test_write_file(fmt.tprintf("%s/settings.json", dir), `{"model":"m","api_key":"from-file"}`)
	os.set_env("AP_API_KEY", "from-env")
	defer os.unset_env("AP_API_KEY")
	s, err := load_settings(dir)
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, s.api_key, "from-env")
}

@(test)
test_settings_missing_model_and_key :: proc(t: ^testing.T) {
	dir := test_temp_dir("settings-bad")
	defer test_cleanup(dir)
	test_write_file(fmt.tprintf("%s/settings.json", dir), `{"api_key":"k"}`)
	_, err := load_settings(dir)
	testing.expect_value(t, err.code, Exit_Code.Usage)

	test_write_file(fmt.tprintf("%s/settings.json", dir), `{"model":"m"}`)
	_, err2 := load_settings(dir)
	testing.expect_value(t, err2.code, Exit_Code.Usage)
}

@(test)
test_settings_type_error :: proc(t: ^testing.T) {
	dir := test_temp_dir("settings-type")
	defer test_cleanup(dir)
	test_write_file(fmt.tprintf("%s/settings.json", dir), `{"model":"m","api_key":"k","max_steps":"ten"}`)
	_, err := load_settings(dir)
	testing.expect_value(t, err.code, Exit_Code.Usage)
}

@(test)
test_agent_definition_roundtrip :: proc(t: ^testing.T) {
	content := "---\nname: scout\ndescription: 搜索代码\ntools: read_file, bash\nmodel: small\nmax_steps: 30\n---\n\n你是搜索代理。\n"
	def, err := parse_agent_definition("C:/x/scout.md", "scout", content)
	testing.expect_value(t, err.code, Exit_Code.OK)
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
	testing.expect_value(t, err.code, Exit_Code.Usage)

	_, err2 := parse_agent_definition("x.md", "x", "---\nname: x\ndescription: d\ntools: grep\n---\n")
	testing.expect_value(t, err2.code, Exit_Code.Usage)

	_, err3 := parse_agent_definition("x.md", "y", "---\nname: x\ndescription: d\n---\n")
	testing.expect_value(t, err3.code, Exit_Code.Usage)

	_, err4 := parse_agent_definition("x.md", "x", "no frontmatter")
	testing.expect_value(t, err4.code, Exit_Code.Usage)
}

@(test)
test_agent_general_builtin_and_override :: proc(t: ^testing.T) {
	dir := test_temp_dir("agents")
	defer test_cleanup(dir)
	def, err := load_agent(dir, "general")
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect(t, def.builtin)
	testing.expect_value(t, len(def.tools), 5)

	test_write_file(
		fmt.tprintf("%s/agents/general.md", dir),
		"---\nname: general\ndescription: overridden\ntools: read_file\n---\n正文\n",
	)
	def2, err2 := load_agent(dir, "general")
	testing.expect_value(t, err2.code, Exit_Code.OK)
	testing.expect(t, !def2.builtin)
	testing.expect_value(t, def2.description, "overridden")
	testing.expect_value(t, len(def2.tools), 1)
}

@(test)
test_agent_unknown_name :: proc(t: ^testing.T) {
	dir := test_temp_dir("agents-missing")
	defer test_cleanup(dir)
	_, err := load_agent(dir, "nope")
	testing.expect_value(t, err.code, Exit_Code.Usage)
}

@(test)
test_path_normalization_hash_stable :: proc(t: ^testing.T) {
	dir := test_temp_dir("hash")
	defer test_cleanup(dir)
	a, err := canonicalize_path(dir, true)
	testing.expect_value(t, err.code, Exit_Code.OK)

	with_slash := fmt.tprintf("%s/", a)
	b, err2 := canonicalize_path(with_slash, true)
	testing.expect_value(t, err2.code, Exit_Code.OK)
	testing.expect_value(t, a, b)

	when ODIN_OS == .Windows {
		upper, _ := strings.to_upper(a)
		c, err3 := canonicalize_path(upper, true)
		testing.expect_value(t, err3.code, Exit_Code.OK)
		testing.expect_value(t, a, c)
	}
}

@(test)
test_path_relative_and_home :: proc(t: ^testing.T) {
	dir := test_temp_dir("resolve")
	defer test_cleanup(dir)
	os.make_directory_all(fmt.tprintf("%s/sub", dir))
	joined, err := resolve_tool_path(dir, "sub/../a.txt")
	testing.expect_value(t, err.code, Exit_Code.OK)
	expect := fmt.tprintf("%s/a.txt", strings.trim_right(dir, `\/`))
	testing.expect_value(t, joined, normalize_slashes(expect))

	home, herr := os.user_home_dir(context.allocator)
	testing.expect_value(t, herr, nil)
	expanded, err2 := expand_home("~/x")
	testing.expect_value(t, err2.code, Exit_Code.OK)
	home_slashed := normalize_slashes(home)
	testing.expect_value(t, expanded, fmt.tprintf("%s/x", strings.trim_right(home_slashed, `\/`)))
}

@(test)
test_project_hash_ignores_separators_and_uppercase :: proc(t: ^testing.T) {
	dir := test_temp_dir("project")
	defer test_cleanup(dir)
	config := fmt.tprintf("%s/config", dir)
	root := fmt.tprintf("%s/work", dir)
	os.make_directory_all(root)

	p1, err := open_project(config, root)
	testing.expect_value(t, err.code, Exit_Code.OK)
	backslashed, _ := strings.replace_all(root, "/", `\`)
	p2, err2 := open_project(config, backslashed)
	testing.expect_value(t, err2.code, Exit_Code.OK)
	testing.expect_value(t, p1.hash, p2.hash)

	when ODIN_OS == .Windows {
		upper, _ := strings.to_upper(root)
		p3, err3 := open_project(config, upper)
		testing.expect_value(t, err3.code, Exit_Code.OK)
		testing.expect_value(t, p1.hash, p3.hash)
	}

	testing.expect(t, os.exists(fmt.tprintf("%s/path.txt", p1.dir)))
}

@(test)
test_project_path_conflict :: proc(t: ^testing.T) {
	dir := test_temp_dir("conflict")
	defer test_cleanup(dir)
	config := fmt.tprintf("%s/config", dir)
	root := fmt.tprintf("%s/work", dir)
	os.make_directory_all(root)

	p, err := open_project(config, root)
	testing.expect_value(t, err.code, Exit_Code.OK)
	test_write_file(fmt.tprintf("%s/path.txt", p.dir), "different\n")
	_, err2 := open_project(config, root)
	testing.expect_value(t, err2.code, Exit_Code.Usage)
}
