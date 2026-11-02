package engine

import "../platform"
import "../tool"

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

test_tool_execute :: proc(user: rawptr, args: json.Value, ctx: ^tool.Tool_Context) -> tool.Tool_Result {
	return {ok = true}
}

test_registry :: proc(names: ..string) -> tool.Registry {
	tools := make([]tool.Tool, len(names))
	for name, i in names {
		tools[i] = tool.Tool {
			name = name,
			description = name,
			parameters_json = `{"type":"object"}`,
			execute = test_tool_execute,
		}
	}
	registry, err := tool.registry_init(tools)
	if !platform.is_ok(err) {
		panic("test registry init failed")
	}
	return registry
}

@(test)
test_resolve_fork_without_explicit_source_uses_latest_root :: proc(t: ^testing.T) {
	dir := test_temp_dir("fork-latest")
	defer test_cleanup(dir)
	root := fmt.tprintf("%s/work", dir)
	config_dir := fmt.tprintf("%s/config", dir)
	project, perr := platform.open_project(config_dir, root)
	testing.expect(t, platform.is_ok(perr))

	line := `{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_root","content":"sys","cwd":"/x","model":"m","provider":"p","agent_name":"general","agent_depth":0,"parent_session_id":null}`
	test_write_file(platform.session_file(project, "ses_root"), fmt.tprintf("%s\n", line))

	settings := settings_defaults()
	req := Session_Request {
		kind      = .Fork,
		project   = project,
		settings  = &settings,
		registry  = test_registry("read_file", "bash"),
	}
	resolved, err := resolve_session(req)
	testing.expect(t, is_ok(err))
	testing.expect_value(t, resolved.source_id, "ses_root")
	testing.expect_value(t, resolved.agent_name, "general")
}

test_session_project :: proc(t: ^testing.T, name: string) -> (platform.Project, string, string) {
	context.random_generator = crypto.random_generator()
	dir := test_temp_dir(name)
	root := fmt.tprintf("%s/work", dir)
	config := fmt.tprintf("%s/config", dir)
	_ = os.make_directory_all(root)
	project, perr := platform.open_project(config, root)
	testing.expect(t, platform.is_ok(perr))
	return project, config, dir
}

@(test)
test_resolve_new_prompt_sections_and_tool_switches :: proc(t: ^testing.T) {
	project, _, dir := test_session_project(t, "resolve-switches")
	defer test_cleanup(dir)

	settings := settings_defaults()
	req := Session_Request {
		kind               = .New,
		project            = project,
		settings           = &settings,
		registry           = test_registry("read_file", "bash"),
		base_system_prompt = "CUSTOM_BASE\n",
		prompt_sections    = []string{"## 环境\n- cwd: x\n", "## 追加指令\nAPPEND\n"},
		tools              = []string{"read_file"},
	}
	resolved, err := resolve_session(req)
	testing.expect(t, is_ok(err))
	testing.expect(t, strings.has_prefix(resolved.system_prompt, "CUSTOM_BASE\n"))
	testing.expect(t, !test_contains(resolved.system_prompt, "你是 AI Assistant"))
	testing.expect(t, test_contains(resolved.system_prompt, "## 环境"))
	testing.expect(t, test_contains(resolved.system_prompt, "APPEND"))
	testing.expect(t, test_contains(resolved.system_prompt, "### read_file"))
	testing.expect(t, !test_contains(resolved.system_prompt, "### bash"))
	testing.expect_value(t, strings.join(resolved.tools, ","), "read_file")
}

@(test)
test_resolve_new_tools_none :: proc(t: ^testing.T) {
	project, _, dir := test_session_project(t, "resolve-tools-none")
	defer test_cleanup(dir)
	settings := settings_defaults()
	resolved, err := resolve_session(
		{
			kind = .New,
			project = project,
			settings = &settings,
			registry = test_registry("read_file"),
			tools = []string{},
		},
	)
	testing.expect(t, is_ok(err))
	testing.expect_value(t, len(resolved.tools), 0)
	testing.expect(t, test_contains(resolved.system_prompt, "（本次没有可用工具）"))
}

@(test)
test_resolve_new_unknown_tool_is_usage_error :: proc(t: ^testing.T) {
	project, _, dir := test_session_project(t, "resolve-unknown-tool")
	defer test_cleanup(dir)
	settings := settings_defaults()
	_, err := resolve_session(
		{
			kind = .New,
			project = project,
			settings = &settings,
			registry = test_registry("read_file"),
			tools = []string{"grep"},
		},
	)
	testing.expect_value(t, err.kind, Error_Kind.Usage)
}

@(test)
test_resolve_restore_warns_and_uses_frozen_tools :: proc(t: ^testing.T) {
	project, _, dir := test_session_project(t, "resolve-restore-switches")
	defer test_cleanup(dir)
	line := `{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_root","content":"frozen prompt","cwd":"/x","model":"m","provider":"p","agent_name":"general","agent_depth":0,"parent_session_id":null,"tools":["read_file"]}`
	test_write_file(platform.session_file(project, "ses_root"), fmt.tprintf("%s\n", line))

	settings := settings_defaults()
	resolved, err := resolve_session(
		{
			kind = .Resume,
			project = project,
			settings = &settings,
			registry = test_registry("read_file", "bash"),
			source_session_id = "ses_root",
			agent_name = "other",
			model = "other-model",
			base_system_prompt = "IGNORED\n",
			prompt_sections = []string{"IGNORED\n"},
			tools = []string{"bash"},
		},
	)
	testing.expect(t, is_ok(err))
	testing.expect_value(t, resolved.system_prompt, "frozen prompt")
	testing.expect_value(t, strings.join(resolved.tools, ","), "read_file")
	warnings := strings.join(resolved.warnings[:], "\n")
	testing.expect(t, test_contains(warnings, "--base-system-prompt ignored on restore"))
	testing.expect(t, test_contains(warnings, "prompt sections ignored on restore"))
	testing.expect(t, test_contains(warnings, "tool set ignored on restore"))
	testing.expect(t, test_contains(warnings, "--agent ignored on restore"))
	testing.expect(t, test_contains(warnings, "--model ignored on restore"))
}

@(test)
test_resolve_restore_skips_unknown_frozen_tools :: proc(t: ^testing.T) {
	project, _, dir := test_session_project(t, "resolve-restore-unknown")
	defer test_cleanup(dir)
	line := `{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_unknown","content":"frozen prompt","cwd":"/x","model":"m","provider":"p","agent_name":"general","agent_depth":0,"parent_session_id":null,"tools":["read_file","gone"]}`
	test_write_file(platform.session_file(project, "ses_unknown"), fmt.tprintf("%s\n", line))

	settings := settings_defaults()
	resolved, err := resolve_session(
		{
			kind = .Resume,
			project = project,
			settings = &settings,
			registry = test_registry("read_file"),
			source_session_id = "ses_unknown",
		},
	)
	testing.expect(t, is_ok(err))
	testing.expect_value(t, strings.join(resolved.tools, ","), "read_file")
	warnings := strings.join(resolved.warnings[:], "\n")
	testing.expect(t, test_contains(warnings, "frozen tool \"gone\" is not registered"))
}

@(test)
test_resolve_restore_old_transcript_uses_all_tools :: proc(t: ^testing.T) {
	project, _, dir := test_session_project(t, "resolve-restore-old")
	defer test_cleanup(dir)
	line := `{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_old","content":"old prompt","cwd":"/x","model":"m","provider":"p","agent_name":"general","agent_depth":0,"parent_session_id":null}`
	test_write_file(platform.session_file(project, "ses_old"), fmt.tprintf("%s\n", line))

	settings := settings_defaults()
	resolved, err := resolve_session(
		{
			kind = .Resume,
			project = project,
			settings = &settings,
			registry = test_registry("read_file", "bash"),
			source_session_id = "ses_old",
		},
	)
	testing.expect(t, is_ok(err))
	testing.expect_value(t, strings.join(resolved.tools, ","), "read_file,bash")
	warnings := strings.join(resolved.warnings[:], "\n")
	testing.expect(t, test_contains(warnings, "using all registered tools"))
}

@(test)
test_session_open_freezes_tools_and_prompt :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	project, _, dir := test_session_project(t, "session-freeze-tools")
	defer test_cleanup(dir)
	settings := settings_defaults()
	session, info, err := session_open(
		{
			kind = .New,
			project = project,
			settings = &settings,
			registry = test_registry("read_file", "bash"),
			tools = []string{"read_file"},
			base_system_prompt = "BASE\n",
			prompt_sections = []string{"## 环境\n- cwd: x\n"},
		},
	)
	testing.expect(t, is_ok(err))
	testing.expect_value(t, session.session_id, info.session_id)
	transcript_close(&session.store)

	events, rerr := transcript_read_all(project, session.session_id)
	testing.expect(t, is_ok(rerr))
	start, found := last_session_start(events)
	testing.expect(t, found)
	frozen, ok := start.tools.?
	testing.expect(t, ok)
	testing.expect_value(t, strings.join(frozen, ","), "read_file")

	raw := ""
	for ev in events {
		if ev.type == "session_start" {
			raw = ev.line
		}
	}
	testing.expect(t, test_contains(raw, `"tools":["read_file"]`))
}

@(test)
test_session_open_tools_none_writes_empty_array :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	project, _, dir := test_session_project(t, "session-freeze-none")
	defer test_cleanup(dir)
	settings := settings_defaults()
	session, _, err := session_open(
		{
			kind = .New,
			project = project,
			settings = &settings,
			registry = test_registry("read_file"),
			tools = []string{},
		},
	)
	testing.expect(t, is_ok(err))
	transcript_close(&session.store)

	events, rerr := transcript_read_all(project, session.session_id)
	testing.expect(t, is_ok(rerr))
	start, found := last_session_start(events)
	testing.expect(t, found)
	frozen, ok := start.tools.?
	testing.expect(t, ok)
	testing.expect_value(t, len(frozen), 0)
	raw := ""
	for ev in events {
		if ev.type == "session_start" {
			raw = ev.line
		}
	}
	testing.expect(t, test_contains(raw, `"tools":[]`))
}

@(test)
test_fork_copies_frozen_tools :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	project, _, dir := test_session_project(t, "session-fork-tools")
	defer test_cleanup(dir)
	line := `{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_src","content":"frozen prompt","cwd":"/x","model":"m","provider":"p","agent_name":"general","agent_depth":0,"parent_session_id":null,"tools":["read_file"]}`
	test_write_file(platform.session_file(project, "ses_src"), fmt.tprintf("%s\n", line))

	settings := settings_defaults()
	session, _, err := session_open(
		{
			kind = .Fork,
			project = project,
			settings = &settings,
			registry = test_registry("read_file", "bash"),
			source_session_id = "ses_src",
		},
	)
	testing.expect(t, is_ok(err))
	testing.expect(t, session.session_id != "ses_src")
	transcript_close(&session.store)

	events, rerr := transcript_read_all(project, session.session_id)
	testing.expect(t, is_ok(rerr))
	start, found := last_session_start(events)
	testing.expect(t, found)
	frozen, ok := start.tools.?
	testing.expect(t, ok)
	testing.expect_value(t, strings.join(frozen, ","), "read_file")
}

@(test)
test_preview_and_session_open_have_identical_prompt :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	project, _, dir := test_session_project(t, "preview-identical")
	defer test_cleanup(dir)
	settings := settings_defaults()
	req := Session_Request {
		kind = .New,
		project = project,
		settings = &settings,
		registry = test_registry("read_file"),
		base_system_prompt = "BASE\n",
		prompt_sections = []string{"## 环境\n- cwd: fixed\n"},
		tools = []string{"read_file"},
	}
	info, perr := preview_prompt(req)
	testing.expect(t, is_ok(perr))
	session, sinfo, serr := session_open(req)
	testing.expect(t, is_ok(serr))
	defer transcript_close(&session.store)
	testing.expect_value(t, info.system_prompt, sinfo.system_prompt)
}
