package tool

import "../platform"

import "core:encoding/json"
import "core:strings"
import "core:testing"

make_tool :: proc(name: string, out: string) -> Tool {
	return {
		name = name,
		description = strings.concatenate([]string{"does ", name}),
		parameters_json = `{"type":"object"}`,
		execute = proc(user: rawptr, args: json.Value, ctx: ^Tool_Context) -> Tool_Result {
			return tool_ok("out")
		},
	}
}

@(test)
test_registry_rejects_duplicate_and_empty_names :: proc(t: ^testing.T) {
	_, err := registry_init([]Tool{make_tool("a", "x"), make_tool("a", "y")})
	testing.expect(t, !platform.is_ok(err))

	_, err2 := registry_init([]Tool{make_tool("", "x")})
	testing.expect(t, !platform.is_ok(err2))

	reg, err3 := registry_init([]Tool{make_tool("a", "x")})
	testing.expect(t, platform.is_ok(err3))
	testing.expect_value(t, len(reg.tools), 1)
}

@(test)
test_registry_select_follows_declaration_order :: proc(t: ^testing.T) {
	reg, _ := registry_init(
		[]Tool{make_tool("read_file", "r"), make_tool("bash", "b"), make_tool("task", "t")},
	)
	selected, err := registry_select(&reg, []string{"task", "read_file"})
	testing.expect(t, platform.is_ok(err))
	testing.expect_value(t, strings.join(selected, ","), "read_file,task")

	none, nerr := registry_select(&reg, []string{})
	testing.expect(t, platform.is_ok(nerr))
	testing.expect_value(t, len(none), 0)

	_, unknown := registry_select(&reg, []string{"nope"})
	testing.expect(t, !platform.is_ok(unknown))
}

@(test)
test_registry_definitions_and_prompt_section :: proc(t: ^testing.T) {
	reg, _ := registry_init([]Tool{make_tool("read_file", "r"), make_tool("bash", "b")})
	defs, err := registry_definitions(&reg, []string{"bash", "read_file"})
	testing.expect(t, platform.is_ok(err))
	testing.expect_value(t, len(defs), 2)
	testing.expect_value(t, defs[0].function.name, "read_file")
	testing.expect_value(t, defs[1].function.name, "bash")
	testing.expect(t, defs[0].function.parameters != nil)

	section := registry_prompt_section(&reg, []string{"bash"})
	testing.expect(t, strings.contains(section, "### bash"))
	testing.expect(t, !strings.contains(section, "### read_file"))

	none_section := registry_prompt_section(&reg, []string{})
	testing.expect_value(t, none_section, "（本次没有可用工具）")
}

@(test)
test_tool_execute_passes_result_through :: proc(t: ^testing.T) {
	reg, _ := registry_init([]Tool {
		{
			name = "x",
			description = "x",
			parameters_json = `{"type":"object"}`,
			execute = proc(user: rawptr, args: json.Value, ctx: ^Tool_Context) -> Tool_Result {
				return {ok = false, error = "boom", fatal = true, exit_code = 7}
			},
		},
	})
	args, _ := json.parse_string(`{}`, .JSON, true)
	ctx := Tool_Context{}
	res := tool_execute(&reg, "x", args, &ctx)
	testing.expect(t, !res.ok)
	testing.expect_value(t, res.error, "boom")
	testing.expect(t, res.fatal)
	testing.expect_value(t, res.exit_code.?, 7)
	testing.expect(t, res.duration_ms >= 0)

	missing := tool_execute(&reg, "nope", args, &ctx)
	testing.expect(t, !missing.ok)
}
