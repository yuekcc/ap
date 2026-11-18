package apcore

import "platform"

import "core:encoding/json"
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

sdk_noop_tool :: proc(name: string) -> Tool {
	return {
		name = name,
		description = name,
		parameters_json = `{"type":"object"}`,
		execute = proc(user: rawptr, args: json.Value, ctx: ^Tool_Context) -> Tool_Result {
			return ok_tool()
		},
	}
}

ok_tool :: proc() -> Tool_Result {
	return {ok = true}
}

@(test)
test_sdk_session_request_fills_env :: proc(t: ^testing.T) {
	tools := make([]Tool, 1)
	tools[0] = sdk_noop_tool("read_file")
	registry, _ := registry_init(tools)
	env := Env {
		config_dir = "/cfg",
		cwd        = "/work",
		tools      = registry,
	}
	opts := Session_Options {
		kind              = .Resume,
		source_session_id = "sess-1",
		model             = "m1",
		tools             = []string{"read_file"},
		agent_depth       = 2,
	}
	req := session_request(&env, opts)
	testing.expect_value(t, req.kind, Session_Kind.Resume)
	testing.expect_value(t, req.project.root, "")
	testing.expect_value(t, req.source_session_id, "sess-1")
	testing.expect_value(t, req.model, "m1")
	testing.expect_value(t, req.agent_depth, 2)
	testing.expect_value(t, req.tools[0], "read_file")
	testing.expect(t, req.settings == &env.settings)
	testing.expect_value(t, req.registry.tools[0].name, "read_file")
}

// SDK 不读 settings.json：目录里没有这个文件也必须成功，设置完全来自入参。
@(test)
test_sdk_env_open_does_not_read_settings_json :: proc(t: ^testing.T) {
	dir := sdk_temp_dir("no-settings-file")
	defer os.remove_all(dir)

	settings := settings_defaults()
	settings.model = "injected-model"
	settings.api_key = "injected-key"

	work := fmt.tprintf("%s/work", dir)
	_ = os.make_directory_all(work)

	env, err := env_open({
		config_dir = dir,
		cwd        = work,
		settings   = settings,
		tools      = nil,
	})
	defer delete(env.config_dir)
	defer delete(env.cwd)
	if !testing.expect_value(t, err.kind, Error_Kind.None) {
		return
	}
	testing.expect_value(t, env.settings.model, "injected-model")
	testing.expect_value(t, env.settings.api_key, "injected-key")
	testing.expect(t, len(env.cwd) > 0)
}

@(test)
test_sdk_env_open_validates_registry :: proc(t: ^testing.T) {
	dir := sdk_temp_dir("bad-registry")
	defer os.remove_all(dir)

	tools := make([]Tool, 2)
	tools[0] = sdk_noop_tool("dup")
	tools[1] = sdk_noop_tool("dup")
	_, err := env_open({
		config_dir = dir,
		cwd        = dir,
		settings   = settings_defaults(),
		tools      = tools,
	})
	testing.expect(t, err.kind != Error_Kind.None)
}

@(test)
test_sdk_session_options_append :: proc(t: ^testing.T) {
	opts: Session_Options
	session_options_append(&opts, "")
	session_options_append(&opts, "one")
	session_options_append(&opts, "two")
	testing.expect_value(t, len(opts.prompt_sections), 2)
	testing.expect_value(t, opts.prompt_sections[0], "one")
	testing.expect_value(t, opts.prompt_sections[1], "two")
}

// 回归：--debug 曾经因为 SDK 不转发 info/debug 而完全没有输出。
@(test)
test_sdk_log_info_and_debug_follow_level :: proc(t: ^testing.T) {
	dir := sdk_temp_dir("sdk-logger")
	defer os.remove_all(dir)
	defer log_set_level(.Info)
	defer log_file_close()

	year, month, day, _, _, _ := platform.local_now()
	path := fmt.tprintf("%s/logs/app-%04d-%02d-%02d.log", dir, year, month, day)

	log_file_open(dir)
	log_set_level(.Warn)
	log_info("filtered info")
	log_debug("filtered debug")
	testing.expect(t, !os.exists(path))

	log_set_level(.Debug)
	log_info("step %d: request", 1)
	log_debug("provider: status %d", 200)

	data, err := os.read_entire_file_from_path(path, context.allocator)
	testing.expect(t, err == nil)
	content := string(data)
	testing.expect(t, strings.contains(content, "[info] step 1: request\n"))
	testing.expect(t, strings.contains(content, "[debug] provider: status 200\n"))
}
