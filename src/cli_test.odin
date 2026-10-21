package ap

import "core:testing"

@(test)
test_cli_defaults :: proc(t: ^testing.T) {
	opts, err := parse_args([]string{"ap", "--print", "hello"})
	testing.expect_value(t, err.code, Exit_Code.OK)
	prompt, ok := opts.print_prompt.?
	testing.expect(t, ok)
	testing.expect_value(t, prompt, "hello")
	testing.expect_value(t, opts.output_format, Output_Format.Text)
	testing.expect_value(t, opts.max_steps, Maybe(int)(nil))
}

@(test)
test_cli_inline_values :: proc(t: ^testing.T) {
	opts, err := parse_args(
		[]string{"ap", "--print=do it", "--output-format=stream-json", "--max-steps=3", "--session=abc"},
	)
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, opts.output_format, Output_Format.Stream_Json)
	testing.expect_value(t, opts.max_steps.?, 3)
	testing.expect_value(t, opts.session_id.?, "abc")
}

@(test)
test_cli_rejects_conflicting_prompt_sources :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"ap", "--print", "x", "--print0"})
	testing.expect_value(t, err.code, Exit_Code.Usage)

	_, err2 := parse_args([]string{"ap", "--print", "x", "--input-file", "a.txt"})
	testing.expect_value(t, err2.code, Exit_Code.Usage)
}

@(test)
test_cli_requires_restore_for_fork :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"ap", "--print", "x", "--fork-session"})
	testing.expect_value(t, err.code, Exit_Code.Usage)
}

@(test)
test_cli_rejects_bad_numbers :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"ap", "--print", "x", "--max-steps", "0"})
	testing.expect_value(t, err.code, Exit_Code.Usage)
	_, err2 := parse_args([]string{"ap", "--print", "x", "--max-tokens", "-1"})
	testing.expect_value(t, err2.code, Exit_Code.Usage)
	_, err3 := parse_args([]string{"ap", "--print", "x", "--agent-depth", "-1"})
	testing.expect_value(t, err3.code, Exit_Code.Usage)
}

@(test)
test_cli_parent_tool_call_requires_parent_session :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"ap", "--print", "x", "--parent-tool-call-id", "call_1"})
	testing.expect_value(t, err.code, Exit_Code.Usage)
}

@(test)
test_cli_unknown_flag :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"ap", "--nope"})
	testing.expect_value(t, err.code, Exit_Code.Usage)
}

@(test)
test_cli_help_and_version :: proc(t: ^testing.T) {
	opts, err := parse_args([]string{"ap", "--help"})
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect(t, opts.help)
	opts2, err2 := parse_args([]string{"ap", "--version"})
	testing.expect_value(t, err2.code, Exit_Code.OK)
	testing.expect(t, opts2.version)
}

@(test)
test_cli_list_skills :: proc(t: ^testing.T) {
	opts, err := parse_args([]string{"ap", "--list-skills"})
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect(t, opts.list_skills)

	_, err2 := parse_args([]string{"ap", "--list-skills=yes"})
	testing.expect_value(t, err2.code, Exit_Code.Usage)
}

@(test)
test_cli_print_system_prompt :: proc(t: ^testing.T) {
	opts, err := parse_args([]string{"ap", "--print-system-prompt"})
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect(t, opts.print_system_prompt)

	_, err2 := parse_args([]string{"ap", "--print-system-prompt=yes"})
	testing.expect_value(t, err2.code, Exit_Code.Usage)
}
