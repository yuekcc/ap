package engine

import "../platform"
import "core:crypto"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

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
		config_dir = config_dir,
		cwd       = project.root,
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
test_resolve_new_context_and_tool_switches :: proc(t: ^testing.T) {
	project, config, dir := test_session_project(t, "resolve-switches")
	defer test_cleanup(dir)
	test_write_file(fmt.tprintf("%s/AGENTS.md", config), "GLOBAL_MEMORY")
	test_write_file(fmt.tprintf("%s/AGENTS.md", project.root), "PROJECT_MEMORY")

	settings := settings_defaults()
	req := Session_Request {
		kind               = .New,
		project            = project,
		settings           = &settings,
		config_dir         = config,
		cwd                = project.root,
		base_system_prompt = "CUSTOM_BASE\n",
		no_agents_md       = true,
		no_skills          = true,
		tools_set          = true,
		tools              = []string{"read_file"},
	}
	resolved, err := resolve_session(req)
	testing.expect(t, is_ok(err))
	testing.expect(t, strings.has_prefix(resolved.system_prompt, "CUSTOM_BASE\n"))
	testing.expect(t, !test_contains(resolved.system_prompt, "你是 AI Assistant"))
	testing.expect(t, !test_contains(resolved.system_prompt, "GLOBAL_MEMORY"))
	testing.expect(t, !test_contains(resolved.system_prompt, "PROJECT_MEMORY"))
	testing.expect(t, !test_contains(resolved.system_prompt, "## 可用技能"))
	testing.expect(t, test_contains(resolved.system_prompt, "### read_file"))
	testing.expect(t, !test_contains(resolved.system_prompt, "### bash"))
	testing.expect_value(t, len(resolved.agent.tools), 1)
	testing.expect_value(t, resolved.agent.tools[0], "read_file")
}

@(test)
test_resolve_new_tools_none :: proc(t: ^testing.T) {
	project, config, dir := test_session_project(t, "resolve-tools-none")
	defer test_cleanup(dir)
	settings := settings_defaults()
	resolved, err := resolve_session(
		{
			kind = .New,
			project = project,
			settings = &settings,
			config_dir = config,
			cwd = project.root,
			tools_set = true,
			tools = []string{},
		},
	)
	testing.expect(t, is_ok(err))
	testing.expect_value(t, len(resolved.agent.tools), 0)
	testing.expect(t, test_contains(resolved.system_prompt, "（本次没有可用工具）"))
}

@(test)
test_resolve_restore_warns_and_uses_frozen_tools :: proc(t: ^testing.T) {
	project, config, dir := test_session_project(t, "resolve-restore-switches")
	defer test_cleanup(dir)
	line := `{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_root","content":"frozen prompt","cwd":"/x","model":"m","provider":"p","agent_name":"general","agent_depth":0,"parent_session_id":null,"tools":["read_file"]}`
	test_write_file(platform.session_file(project, "ses_root"), fmt.tprintf("%s\n", line))

	settings := settings_defaults()
	resolved, err := resolve_session(
		{
			kind = .Resume,
			project = project,
			settings = &settings,
			config_dir = config,
			cwd = project.root,
			source_session_id = "ses_root",
			base_system_prompt = "IGNORED\n",
			no_agents_md = true,
			no_skills = true,
			tools_set = true,
			tools = []string{"bash"},
			append_system_prompt = "APPEND",
		},
	)
	testing.expect(t, is_ok(err))
	testing.expect_value(t, resolved.system_prompt, "frozen prompt")
	testing.expect_value(t, len(resolved.agent.tools), 1)
	testing.expect_value(t, resolved.agent.tools[0], "read_file")
	warnings := strings.join(resolved.warnings[:], "\n")
	testing.expect(t, test_contains(warnings, "--base-system-prompt ignored on restore"))
	testing.expect(t, test_contains(warnings, "--no-agents-md ignored on restore"))
	testing.expect(t, test_contains(warnings, "--no-skills ignored on restore"))
	testing.expect(t, test_contains(warnings, "tool override ignored on restore"))
	testing.expect(t, test_contains(warnings, "--append-system-prompt ignored on restore"))
}

@(test)
test_resolve_restore_old_transcript_falls_back_to_agent_tools :: proc(t: ^testing.T) {
	project, config, dir := test_session_project(t, "resolve-restore-old")
	defer test_cleanup(dir)
	line := `{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_old","content":"old prompt","cwd":"/x","model":"m","provider":"p","agent_name":"general","agent_depth":0,"parent_session_id":null}`
	test_write_file(platform.session_file(project, "ses_old"), fmt.tprintf("%s\n", line))

	settings := settings_defaults()
	resolved, err := resolve_session(
		{
			kind = .Resume,
			project = project,
			settings = &settings,
			config_dir = config,
			cwd = project.root,
			source_session_id = "ses_old",
		},
	)
	testing.expect(t, is_ok(err))
	testing.expect_value(t, len(resolved.agent.tools), 5)
}

@(test)
test_session_open_freezes_tools_in_session_start :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	project, config, dir := test_session_project(t, "session-freeze-tools")
	defer test_cleanup(dir)
	settings := settings_defaults()
	session, info, err := session_open(
		{
			kind = .New,
			project = project,
			settings = &settings,
			config_dir = config,
			cwd = project.root,
			tools_set = true,
			tools = []string{"read_file"},
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
	project, config, dir := test_session_project(t, "session-freeze-none")
	defer test_cleanup(dir)
	settings := settings_defaults()
	session, _, err := session_open(
		{
			kind = .New,
			project = project,
			settings = &settings,
			config_dir = config,
			cwd = project.root,
			tools_set = true,
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
	project, config, dir := test_session_project(t, "session-fork-tools")
	defer test_cleanup(dir)
	line := `{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_src","content":"frozen prompt","cwd":"/x","model":"m","provider":"p","agent_name":"general","agent_depth":0,"parent_session_id":null,"tools":["read_file"]}`
	test_write_file(platform.session_file(project, "ses_src"), fmt.tprintf("%s\n", line))

	settings := settings_defaults()
	session, _, err := session_open(
		{
			kind = .Fork,
			project = project,
			settings = &settings,
			config_dir = config,
			cwd = project.root,
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
test_restore_does_not_propagate_ignored_switches :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	project, config, dir := test_session_project(t, "restore-no-propagation")
	defer test_cleanup(dir)
	line := `{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_restore","content":"frozen prompt","cwd":"/x","model":"m","provider":"p","agent_name":"general","agent_depth":0,"parent_session_id":null,"tools":["read_file"]}`
	test_write_file(platform.session_file(project, "ses_restore"), fmt.tprintf("%s\n", line))

	settings := settings_defaults()
	session, _, err := session_open(
		{
			kind = .Resume,
			project = project,
			settings = &settings,
			config_dir = config,
			cwd = project.root,
			source_session_id = "ses_restore",
			base_system_prompt = "IGNORED\n",
			no_agents_md = true,
			no_skills = true,
			tools_set = true,
			tools = []string{"bash"},
		},
	)
	testing.expect(t, is_ok(err))
	transcript_close(&session.store)
	testing.expect(t, !session.no_agents_md)
	testing.expect(t, !session.no_skills)
	testing.expect_value(t, strings.join(session.agent.tools, ","), "read_file")
}
