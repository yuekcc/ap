package main

import "core:testing"

expect_command :: proc(t: ^testing.T, actual: []string, expected: []string) {
	testing.expect_value(t, len(actual), len(expected))
	if len(actual) != len(expected) {
		return
	}
	for value, i in expected {
		testing.expect_value(t, actual[i], value)
	}
}

@(test)
test_build_agent_command_minimal :: proc(t: ^testing.T) {
	options := Turn_Options {
		agent_bin  = "C:/bin/ap.exe",
		config_dir = "C:/cfg",
		cwd        = "C:/proj",
	}
	command := build_agent_command(&options)
	defer delete(command)

	expect_command(t, command[:], {"C:/bin/ap.exe", "--print0", "--output-format", "stream-json", "--config-dir", "C:/cfg"})
}

@(test)
test_build_agent_command_forwards_options :: proc(t: ^testing.T) {
	options := Turn_Options {
		agent_bin  = "C:/bin/ap.exe",
		session_id = "ses_1",
		config_dir = "C:/cfg",
		cwd        = "C:/proj",
		model      = "some-model",
		agent      = "general",
		max_steps  = 5,
		max_tokens = 1000,
		verbose    = true,
	}
	command := build_agent_command(&options)
	defer delete(command)

	expect_command(
		t,
		command[:],
		{
			"C:/bin/ap.exe",
			"--print0",
			"--output-format",
			"stream-json",
			"-s",
			"ses_1",
			"--model",
			"some-model",
			"--agent",
			"general",
			"--max-steps",
			"5",
			"--max-tokens",
			"1000",
			"--config-dir",
			"C:/cfg",
			"--verbose",
		},
	)
}
