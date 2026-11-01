package apcli

import "core:fmt"
import "core:os"
import "core:strings"
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
test_cli_print_short_alias :: proc(t: ^testing.T) {
	opts, err := parse_args([]string{"ap", "-p", "hello"})
	testing.expect_value(t, err.code, Exit_Code.OK)
	prompt, ok := opts.print_prompt.?
	testing.expect(t, ok)
	testing.expect_value(t, prompt, "hello")
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

@(test)
test_cli_rejects_invalid_utf8_print_prompt :: proc(t: ^testing.T) {
	opts := Options {
		print_prompt = transmute(string)([]byte{0xd6, 0xd0, 0xce, 0xc4}),
	}
	_, err := read_prompt(opts, ".")
	testing.expect_value(t, err.code, Exit_Code.Usage)
}

@(test)
test_cli_requires_prompt_source :: proc(t: ^testing.T) {
	_, err := read_prompt(Options{}, ".")
	testing.expect_value(t, err.code, Exit_Code.Usage)
	testing.expect_value(t, err.message, "no prompt given; use --print, --input-file, or --print0")
}

cli_temp_dir :: proc(t: ^testing.T, name: string) -> string {
	base := os.get_env("TEMP", context.allocator)
	if len(base) == 0 {
		base = os.get_env("TMPDIR", context.allocator)
	}
	dir := fmt.tprintf("%s/ap-cli-test-%s-%d", base, name, os.get_pid())
	os.remove_all(dir)
	if err := os.make_directory_all(dir); err != nil {
		panic("cannot create temp dir")
	}
	return dir
}

@(test)
test_cli_new_context_flags_defaults :: proc(t: ^testing.T) {
	opts, err := parse_args([]string{"ap", "--print", "x"})
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect(t, !opts.no_agents_md)
	testing.expect(t, !opts.no_skills)
}

@(test)
test_cli_removed_context_flags_rejected :: proc(t: ^testing.T) {
	for flag in ([]string {
		"--base-system-prompt",
		"--base-system-prompt-file",
		"--append-system-prompt",
		"--tools",
		"--list-tools",
	}) {
		_, err := parse_args([]string{"ap", flag})
		testing.expect_value(t, err.code, Exit_Code.Usage)
	}

	_, err := parse_args([]string{"ap", "--tools=read_file"})
	testing.expect_value(t, err.code, Exit_Code.Usage)
	_, err2 := parse_args([]string{"ap", "--list-tools=1"})
	testing.expect_value(t, err2.code, Exit_Code.Usage)
}

@(test)
test_cli_normalize_system_prompt :: proc(t: ^testing.T) {
	text, err := normalize_system_prompt(" \r\nline1\r\n\r\n  line2\r  ")
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, text, "line1\n\n  line2\n")

	_, err2 := normalize_system_prompt(" \r\n\t ")
	testing.expect_value(t, err2.code, Exit_Code.Usage)
}

@(test)
test_cli_read_system_prompt :: proc(t: ^testing.T) {
	dir := cli_temp_dir(t, "system-md")
	defer os.remove_all(dir)

	value, err := read_system_prompt_override(dir)
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, value, Maybe(string)(nil))

	path := fmt.tprintf("%s/SYSTEM.md", dir)
	_ = os.write_entire_file_from_bytes(path, transmute([]byte)string("  hello\r\nworld  "))
	value2, err2 := read_system_prompt_override(dir)
	testing.expect_value(t, err2.code, Exit_Code.OK)
	testing.expect_value(t, value2.?, "hello\nworld\n")

	_ = os.write_entire_file_from_bytes(path, []byte{})
	_, err3 := read_system_prompt_override(dir)
	testing.expect_value(t, err3.code, Exit_Code.Usage)

	_ = os.write_entire_file_from_bytes(path, []byte{0xff, 0xfe, 0x00})
	_, err4 := read_system_prompt_override(dir)
	testing.expect_value(t, err4.code, Exit_Code.Usage)
}

@(test)
test_cli_context_switches_reject_inline_values :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"ap", "--no-agents-md=1"})
	testing.expect_value(t, err.code, Exit_Code.Usage)
	_, err2 := parse_args([]string{"ap", "--no-skills=1"})
	testing.expect_value(t, err2.code, Exit_Code.Usage)
}

@(test)
test_cli_workspace_removed :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"ap", "--workspace", "x"})
	testing.expect_value(t, err.code, Exit_Code.Usage)
}

@(test)
test_cli_help_lists_new_flags :: proc(t: ^testing.T) {
	for flag in ([]string {
		"--no-agents-md",
		"--no-skills",
		"--list-skills",
		"--print-system-prompt",
	}) {
		testing.expect(t, strings.contains(USAGE_TEXT, flag))
	}
	for flag in ([]string {
		"--base-system-prompt",
		"--base-system-prompt-file",
		"--append-system-prompt",
		"--tools",
		"--list-tools",
	}) {
		testing.expect(t, !strings.contains(USAGE_TEXT, flag))
	}
	testing.expect(t, strings.contains(USAGE_TEXT, "SYSTEM.md"))
	testing.expect(t, !strings.contains(USAGE_TEXT, "--workspace"))
}

@(test)
test_cli_help_requires_explicit_prompt_source :: proc(t: ^testing.T) {
	for flag in ([]string{"--print", "--input-file", "--print0"}) {
		testing.expect(t, strings.contains(USAGE_TEXT, flag))
	}
	testing.expect(t, strings.contains(USAGE_TEXT, "不会隐式读取 stdin"))
	testing.expect(t, !strings.contains(USAGE_TEXT, "stdin 不是 TTY"))
	testing.expect(t, !strings.contains(USAGE_TEXT, "ap [选项]"))
}
