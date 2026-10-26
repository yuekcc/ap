package main

import client "../ap/client"

import "core:testing"

@(test)
test_parse_args_defaults :: proc(t: ^testing.T) {
	opts, err := parse_args({"ap-web"})
	testing.expect(t, client.is_ok(err))
	testing.expect_value(t, opts.port, 8417)
	testing.expect_value(t, opts.host, "127.0.0.1")
	testing.expect(t, !opts.host_explicit)
	testing.expect(t, opts.web_root == nil)
	testing.expect(t, opts.agent_bin == nil)
	testing.expect(t, !opts.continue_session)
}

@(test)
test_parse_args_values_and_inline :: proc(t: ^testing.T) {
	opts, err := parse_args(
		{
			"ap-web",
			"--port=9000",
			"--host",
			"0.0.0.0",
			"--web-root",
			"ap-web/dist",
			"--agent-bin=./bin/ap",
			"-s",
			"ses_1",
			"--model",
			"m",
			"--max-steps=3",
			"--max-tokens",
			"44",
			"--config-dir=cfg",
			"--cwd",
			".",
		},
	)
	testing.expect(t, client.is_ok(err))
	testing.expect_value(t, opts.port, 9000)
	testing.expect_value(t, opts.host, "0.0.0.0")
	testing.expect(t, opts.host_explicit)
	testing.expect_value(t, opts.web_root.?, "ap-web/dist")
	testing.expect_value(t, opts.agent_bin.?, "./bin/ap")
	testing.expect_value(t, opts.session_id.?, "ses_1")
	testing.expect_value(t, opts.model.?, "m")
	testing.expect_value(t, opts.max_steps.?, 3)
	testing.expect_value(t, opts.max_tokens.?, 44)
	testing.expect_value(t, opts.config_dir.?, "cfg")
	testing.expect_value(t, opts.cwd.?, ".")
}

@(test)
test_parse_args_continue_flag :: proc(t: ^testing.T) {
	opts, err := parse_args({"ap-web", "-c"})
	testing.expect(t, client.is_ok(err))
	testing.expect(t, opts.continue_session)
	testing.expect_value(t, opts.host, "127.0.0.1")
}

@(test)
test_parse_args_bool_rejects_inline_value :: proc(t: ^testing.T) {
	_, err := parse_args({"ap-web", "--continue=yes"})
	testing.expect(t, !client.is_ok(err))
}

@(test)
test_parse_args_session_and_continue_exclusive :: proc(t: ^testing.T) {
	_, err := parse_args({"ap-web", "-s", "ses_1", "-c"})
	testing.expect(t, !client.is_ok(err))
}

@(test)
test_parse_args_port_range :: proc(t: ^testing.T) {
	_, err := parse_args({"ap-web", "--port", "0"})
	testing.expect(t, !client.is_ok(err))
	_, err2 := parse_args({"ap-web", "--port", "65536"})
	testing.expect(t, !client.is_ok(err2))
	_, err3 := parse_args({"ap-web", "--port", "abc"})
	testing.expect(t, !client.is_ok(err3))
}

@(test)
test_parse_args_unknown_argument :: proc(t: ^testing.T) {
	_, err := parse_args({"ap-web", "--nope"})
	testing.expect(t, !client.is_ok(err))
}

@(test)
test_parse_args_agent :: proc(t: ^testing.T) {
	opts, err := parse_args({"ap-web", "--agent", "general"})
	testing.expect(t, client.is_ok(err))
	testing.expect_value(t, opts.agent.?, "general")

	opts2, err2 := parse_args({"ap-web", "--agent=reviewer"})
	testing.expect(t, client.is_ok(err2))
	testing.expect_value(t, opts2.agent.?, "reviewer")
}
