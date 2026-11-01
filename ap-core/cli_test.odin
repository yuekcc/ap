package apcore

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
	testing.expect_value(t, opts.base_system_prompt, Maybe(string)(nil))
	testing.expect_value(t, opts.base_system_prompt_file, Maybe(string)(nil))
	testing.expect(t, !opts.no_agents_md)
	testing.expect(t, !opts.no_skills)
	testing.expect(t, !opts.tools_set)
	testing.expect(t, !opts.list_tools)
}

@(test)
test_cli_base_prompt_and_append_coexist :: proc(t: ^testing.T) {
	opts, err := parse_args(
		[]string{"ap", "--base-system-prompt=base", "--append-system-prompt", "append", "--print", "x"},
	)
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, opts.base_system_prompt.?, "base")
	testing.expect_value(t, opts.append_system_prompt.?, "append")

	_, err2 := parse_args([]string{"ap", "--base-system-prompt", "a", "--base-system-prompt-file", "f"})
	testing.expect_value(t, err2.code, Exit_Code.Usage)
}

@(test)
test_cli_base_prompt_rejects_empty :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"ap", "--base-system-prompt", ""})
	testing.expect_value(t, err.code, Exit_Code.Usage)
	_, err2 := parse_args([]string{"ap", "--base-system-prompt", "   \r\n\t"})
	testing.expect_value(t, err2.code, Exit_Code.Usage)
	_, err3 := parse_args([]string{"ap", "--base-system-prompt-file="})
	testing.expect_value(t, err3.code, Exit_Code.Usage)
}

@(test)
test_cli_normalize_prompt_block :: proc(t: ^testing.T) {
	text, err := normalize_prompt_block(" \r\nline1\r\n\r\n  line2\r  ", true)
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, text, "line1\n\n  line2\n")

	text2, err2 := normalize_prompt_block("  a  ", false)
	testing.expect_value(t, err2.code, Exit_Code.OK)
	testing.expect_value(t, text2, "a")

	_, err3 := normalize_prompt_block(" \r\n\t ", true)
	testing.expect_value(t, err3.code, Exit_Code.Usage)
}

@(test)
test_cli_read_base_system_prompt_file :: proc(t: ^testing.T) {
	dir := cli_temp_dir(t, "base-file")
	defer os.remove_all(dir)

	path := fmt.tprintf("%s/base.txt", dir)
	_ = os.write_entire_file_from_bytes(path, transmute([]byte)string("  hello\r\nworld  "))
	opts := Options {
		base_system_prompt_file = "base.txt",
	}
	value, err := read_base_system_prompt(opts, dir)
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, value.?, "hello\nworld\n")

	empty_path := fmt.tprintf("%s/empty.txt", dir)
	_ = os.write_entire_file_from_bytes(empty_path, []byte{})
	_, err2 := read_base_system_prompt(Options{base_system_prompt_file = empty_path}, dir)
	testing.expect_value(t, err2.code, Exit_Code.Usage)

	bad_path := fmt.tprintf("%s/bad.txt", dir)
	_ = os.write_entire_file_from_bytes(bad_path, []byte{0xff, 0xfe, 0x00})
	_, err3 := read_base_system_prompt(Options{base_system_prompt_file = bad_path}, dir)
	testing.expect_value(t, err3.code, Exit_Code.Usage)

	_, err4 := read_base_system_prompt(Options{base_system_prompt_file = "missing.txt"}, dir)
	testing.expect_value(t, err4.code, Exit_Code.Usage)
}

@(test)
test_cli_append_prompt_empty_is_unset :: proc(t: ^testing.T) {
	value, err := read_append_system_prompt(Options{append_system_prompt = "  \r\n "})
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, value, Maybe(string)(nil))

	value2, err2 := read_append_system_prompt(Options{append_system_prompt = " \r\nX  "})
	testing.expect_value(t, err2.code, Exit_Code.OK)
	testing.expect_value(t, value2.?, "X")
}

@(test)
test_cli_tools_list :: proc(t: ^testing.T) {
	opts, err := parse_args([]string{"ap", "--tools", " bash, read_file, ,bash "})
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect(t, opts.tools_set)
	testing.expect_value(t, strings.join(opts.tools, ","), "read_file,bash")

	all, err2 := parse_tool_list("all")
	testing.expect_value(t, err2.code, Exit_Code.OK)
	testing.expect_value(t, len(all), 5)

	none, err3 := parse_tool_list("none")
	testing.expect_value(t, err3.code, Exit_Code.OK)
	testing.expect_value(t, len(none), 0)
}

@(test)
test_cli_tools_list_errors :: proc(t: ^testing.T) {
	_, err := parse_tool_list("all,read_file")
	testing.expect_value(t, err.code, Exit_Code.Usage)
	_, err2 := parse_tool_list("")
	testing.expect_value(t, err2.code, Exit_Code.Usage)
	_, err3 := parse_tool_list(" , ")
	testing.expect_value(t, err3.code, Exit_Code.Usage)
	_, err4 := parse_tool_list("grep")
	testing.expect_value(t, err4.code, Exit_Code.Usage)
	_, err5 := parse_args([]string{"ap", "--tools="})
	testing.expect_value(t, err5.code, Exit_Code.Usage)
	_, err6 := parse_tool_list("all,all")
	testing.expect_value(t, err6.code, Exit_Code.Usage)
	_, err7 := parse_tool_list("none,none")
	testing.expect_value(t, err7.code, Exit_Code.Usage)
}

@(test)
test_cli_context_switches_reject_inline_values :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"ap", "--no-agents-md=1"})
	testing.expect_value(t, err.code, Exit_Code.Usage)
	_, err2 := parse_args([]string{"ap", "--no-skills=1"})
	testing.expect_value(t, err2.code, Exit_Code.Usage)
	_, err3 := parse_args([]string{"ap", "--list-tools=1"})
	testing.expect_value(t, err3.code, Exit_Code.Usage)
}

@(test)
test_cli_list_tools_conflicts_and_precedence :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"ap", "--list-skills", "--list-tools"})
	testing.expect_value(t, err.code, Exit_Code.Usage)

	opts, err2 := parse_args([]string{"ap", "--list-tools", "--print-system-prompt"})
	testing.expect_value(t, err2.code, Exit_Code.OK)
	testing.expect(t, opts.list_tools)
	testing.expect(t, opts.print_system_prompt)
}

@(test)
test_cli_workspace_removed :: proc(t: ^testing.T) {
	_, err := parse_args([]string{"ap", "--workspace", "x"})
	testing.expect_value(t, err.code, Exit_Code.Usage)
}

@(test)
test_cli_help_lists_new_flags :: proc(t: ^testing.T) {
	for flag in ([]string {
		"--base-system-prompt",
		"--base-system-prompt-file",
		"--no-agents-md",
		"--no-skills",
		"--tools",
		"--list-tools",
	}) {
		testing.expect(t, strings.contains(USAGE_TEXT, flag))
	}
	testing.expect(t, !strings.contains(USAGE_TEXT, "--workspace"))
}
