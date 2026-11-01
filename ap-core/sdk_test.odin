package apcore

import "platform"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

sdk_temp_dir :: proc(name: string) -> string {
	base := os.get_env("TEMP", context.allocator)
	if len(base) == 0 {
		base = os.get_env("TMPDIR", context.allocator)
	}
	if len(base) == 0 {
		base = "."
	}
	dir := fmt.tprintf("%s/ap-sdk-test-%s-%d", base, name, os.get_pid())
	os.remove_all(dir)
	if err := os.make_directory_all(dir); err != nil {
		panic("cannot create temp dir")
	}
	return dir
}

sdk_write_settings :: proc(config_dir: string) {
	path := fmt.tprintf("%s/settings.json", config_dir)
	data := `{"model":"test-model","api_key":"test-key"}`
	if err := os.write_entire_file_from_bytes(path, transmute([]byte)data); err != nil {
		panic("cannot write settings.json")
	}
}

sdk_restore_env :: proc(name, previous: string) {
	if len(previous) == 0 {
		_ = os.unset_env(name)
	} else {
		_ = os.set_env(name, previous)
	}
}

// env_open 需要一个可执行的 bash；用 AP_BASH 指向临时文件，避免依赖机器环境。
// 返回的 previous 交给调用方在结束时还原。
sdk_set_fake_bash :: proc(dir: string) -> (path, previous: string) {
	path = fmt.tprintf("%s/bash", dir)
	_ = os.write_entire_file_from_bytes(path, []byte{})
	previous = os.get_env("AP_BASH", context.allocator)
	_ = os.set_env("AP_BASH", path)
	return path, previous
}

@(test)
test_sdk_session_request_fills_env :: proc(t: ^testing.T) {
	env := Env {
		config_dir      = "/cfg",
		cwd             = "/work",
		bash_path       = "/bin/bash",
		child_agent_bin = "/bin/ap-child",
	}
	opts := Session_Options {
		kind              = .Resume,
		source_session_id = "sess-1",
		model             = "m1",
		tools_set         = true,
		tools             = []string{"read_file"},
		no_skills         = true,
		agent_depth       = 2,
	}
	req := session_request(&env, opts)
	testing.expect_value(t, req.kind, Session_Kind.Resume)
	testing.expect_value(t, req.config_dir, "/cfg")
	testing.expect_value(t, req.cwd, "/work")
	testing.expect_value(t, req.bash_path, "/bin/bash")
	// self_exe 是 task 子代理要拉起的可执行文件，必须来自 child_agent_bin。
	testing.expect_value(t, req.self_exe, "/bin/ap-child")
	testing.expect_value(t, req.source_session_id, "sess-1")
	testing.expect_value(t, req.model.?, "m1")
	testing.expect_value(t, req.agent_depth.?, 2)
	testing.expect(t, req.tools_set)
	testing.expect(t, req.no_skills)
	testing.expect(t, req.settings == &env.settings)
}

@(test)
test_sdk_env_open_success :: proc(t: ^testing.T) {
	dir := sdk_temp_dir("env")
	defer os.remove_all(dir)
	sdk_write_settings(dir)

	work := fmt.tprintf("%s/work", dir)
	_ = os.make_directory_all(work)
	fake_bash, previous := sdk_set_fake_bash(dir)
	defer sdk_restore_env("AP_BASH", previous)

	env, err := env_open({config_dir = dir, cwd = work, child_agent_bin = "/explicit/ap"})
	defer delete(env.config_dir)
	defer delete(env.cwd)
	defer delete(env.bash_path)
	if !testing.expect_value(t, err.kind, Error_Kind.None) {
		return
	}
	testing.expect(t, strings.contains(strings.to_lower(env.config_dir), "ap-sdk-test-env"))
	testing.expect_value(t, env.settings.model, "test-model")
	testing.expect_value(t, env.bash_path, fake_bash)
	testing.expect_value(t, env.child_agent_bin, "/explicit/ap")
	testing.expect(t, strings.contains(env.cwd, "work"))
}

@(test)
test_sdk_env_open_falls_back_to_self_exe :: proc(t: ^testing.T) {
	dir := sdk_temp_dir("self-exe")
	defer os.remove_all(dir)
	sdk_write_settings(dir)
	_, previous := sdk_set_fake_bash(dir)
	defer sdk_restore_env("AP_BASH", previous)

	env, err := env_open({config_dir = dir, cwd = dir})
	defer delete(env.config_dir)
	defer delete(env.cwd)
	defer delete(env.bash_path)
	if !testing.expect_value(t, err.kind, Error_Kind.None) {
		return
	}
	testing.expect_value(t, env.child_agent_bin, platform.resolve_self_exe())
}

@(test)
test_sdk_env_open_reports_missing_settings :: proc(t: ^testing.T) {
	dir := sdk_temp_dir("no-settings")
	defer os.remove_all(dir)

	_, err := env_open({config_dir = dir, cwd = dir})
	testing.expect_value(t, err.kind, Error_Kind.Usage)
	testing.expect(t, strings.contains(err.message, "settings.json"))
}

@(test)
test_sdk_list_tools_text :: proc(t: ^testing.T) {
	dir := sdk_temp_dir("tools")
	defer os.remove_all(dir)

	text, err := list_tools_text(dir, nil, false, nil)
	testing.expect_value(t, err.kind, Error_Kind.None)
	// 内置 general 默认五个工具，按 ALL_TOOL_NAMES 顺序。
	for name in all_tool_names() {
		testing.expect(t, strings.contains(text, name))
	}

	none_text, none_err := list_tools_text(dir, "general", true, []string{"read_file"})
	testing.expect_value(t, none_err.kind, Error_Kind.None)
	testing.expect(t, strings.contains(none_text, "read_file"))
	testing.expect(t, !strings.contains(none_text, "bash"))
}

@(test)
test_sdk_list_skills_text_is_text :: proc(t: ^testing.T) {
	dir := sdk_temp_dir("skills")
	defer os.remove_all(dir)

	text, err := list_skills_text(dir)
	testing.expect_value(t, err.kind, Error_Kind.None)
	testing.expect(t, len(text) > 0)
}
