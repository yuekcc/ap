package apcli

import apcore "../ap-core"
import protocol "../ap-core/protocol"
import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// 交接在 CLI 侧只做两件事：创建新 session、把交接正文塞进首条 user_message。
// 新 session 走正常 new session 路径，不复制源 transcript、不复用冻结值。

handoff_test_env :: proc(t: ^testing.T, dir: string) -> apcore.Env {
	config_dir := fmt.tprintf("%s/config", dir)
	os.make_directory_all(config_dir)
	env, err := apcore.env_open(
		{
			config_dir = config_dir,
			cwd = dir,
			settings = apcore.Settings {
				model = "test-model",
				base_url = "http://127.0.0.1:1/v1",
				api_key = "sk-test",
				max_steps = 3,
				max_tokens = 1024,
				llm_timeout_ms = 1000,
				blob_threshold_bytes = 4096,
				stream_include_usage = true,
				context_window_tokens = 100000,
			},
			tools = make([]apcore.Tool, 0),
		},
	)
	testing.expect_value(t, err.kind, apcore.Error_Kind.None)
	return env
}

@(test)
test_cli_handoff_session_seeds_user_message :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator()
	dir := cli_temp_dir(t, "handoff-session")
	defer os.remove_all(dir)
	env := handoff_test_env(t, dir)

	opts := apcore.Session_Options {
		kind = .New,
		agent_name = "general",
		model = "fresh-model",
		max_steps = 7,
		max_tokens = 1024,
		base_system_prompt = "fresh prompt\n",
		tools = make([]string, 0),
	}
	opened, err := open_handoff_session(&env, opts, "ses_source", "交接正文")
	testing.expect_value(t, err.kind, apcore.Error_Kind.None)
	testing.expect(t, len(opened.session.session_id) > 0)
	testing.expect(t, opened.session.session_id != "ses_source")

	events, rerr := apcore.session_events(&opened.session)
	testing.expect_value(t, rerr.kind, apcore.Error_Kind.None)
	testing.expect(t, len(events) >= 2)
	testing.expect_value(t, events[0].type, protocol.EVENT_SESSION_START)
	// 新 session 的 session_start 是从头组装的，不是源 session 的冻结值。
	start: protocol.Session_Start_Event
	json.unmarshal_string(events[0].line, &start)
	testing.expect_value(t, start.model, "fresh-model")
	testing.expect(t, strings.contains(start.content, "fresh prompt"))
	// stream-json 要先看到新 session 的 session_start，才能跟上交接后的 id。
	testing.expect(t, strings.contains(opened.initial_line, `"type":"session_start"`))
	testing.expect(t, strings.contains(opened.initial_line, opened.session.session_id))

	testing.expect_value(t, events[1].type, protocol.EVENT_USER_MESSAGE)
	user: protocol.User_Message_Event
	json.unmarshal_string(events[1].line, &user)
	testing.expect(t, strings.has_prefix(user.content, "## 上一会话交接\n来源 session: ses_source\n\n"))
	testing.expect(t, strings.has_suffix(user.content, "交接正文"))
	apcore.session_close(&opened.session, {reason = protocol.SESSION_END_EXIT})
}

@(test)
test_cli_build_new_session_opts_precedence :: proc(t: ^testing.T) {
	dir := cli_temp_dir(t, "handoff-opts")
	defer os.remove_all(dir)
	settings := apcore.Settings {
		model = "settings-model",
		max_steps = 10,
		max_tokens = 4096,
		blob_threshold_bytes = 4096,
	}
	tool_cfg := apcli_test_tool_config(dir)
	registry, rerr := apcore.registry_init(make([]apcore.Tool, 0))
	testing.expect_value(t, rerr.kind, apcore.Error_Kind.None)

	opts, err := build_new_session_opts(
		Options{model = "cli-model", max_steps = 2},
		settings,
		dir,
		dir,
		"",
		&tool_cfg,
		&registry,
	)
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, opts.model, "cli-model")
	testing.expect_value(t, opts.max_steps, 2)
	testing.expect_value(t, opts.max_tokens, 4096)
	testing.expect(t, opts.auto_handoff)

	// --no-handoff 只关自动交接，不影响 manual handoff。
	no_handoff, ok := build_new_session_opts(
		Options{no_handoff = true},
		settings,
		dir,
		dir,
		"",
		&tool_cfg,
		&registry,
	)
	testing.expect_value(t, ok.code, Exit_Code.OK)
	testing.expect(t, !no_handoff.auto_handoff)
	testing.expect_value(t, no_handoff.model, "settings-model")
}
