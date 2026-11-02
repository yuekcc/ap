package apcli

import tool "../ap-core/tool"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

agent_test_write :: proc(path, content: string) {
	dir, _ := os.split_path(path)
	if len(dir) > 0 {
		os.make_directory_all(dir)
	}
	if err := os.write_entire_file_from_bytes(path, transmute([]byte)content); err != nil {
		panic("cannot write test file")
	}
}

agent_test_registry :: proc() -> tool.Registry {
	tools := make([]tool.Tool, 3)
	names := []string{"read_file", "bash", "task"}
	for name, i in names {
		tools[i] = tool.Tool {
			name = name,
			description = name,
			parameters_json = `{"type":"object"}`,
			execute = proc(user: rawptr, args: json.Value, ctx: ^tool.Tool_Context) -> tool.Tool_Result {
				return {ok = true}
			},
		}
	}
	registry, _ := tool.registry_init(tools)
	return registry
}

@(test)
test_agent_definition_roundtrip :: proc(t: ^testing.T) {
	content := "---\nname: scout\ndescription: 搜索代码\ntools: read_file, bash\nmodel: small\nmax_steps: 30\n---\n\n你是搜索代理。\n"
	def, err := parse_agent_definition("C:/x/scout.md", "scout", content)
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, def.name, "scout")
	testing.expect_value(t, def.description, "搜索代码")
	testing.expect_value(t, len(def.tools), 2)
	testing.expect(t, agent_has_tool(def, "read_file"))
	testing.expect(t, !agent_has_tool(def, "task"))
	testing.expect_value(t, def.model.?, "small")
	testing.expect_value(t, def.max_steps.?, 30)
	testing.expect_value(t, def.body, "你是搜索代理。\n")
}

@(test)
test_agent_definition_errors :: proc(t: ^testing.T) {
	_, err := parse_agent_definition("x.md", "x", "---\nname: x\n---\nbody")
	testing.expect_value(t, err.code, Exit_Code.Usage)

	_, err3 := parse_agent_definition("x.md", "y", "---\nname: x\ndescription: d\n---\n")
	testing.expect_value(t, err3.code, Exit_Code.Usage)

	_, err4 := parse_agent_definition("x.md", "x", "no frontmatter")
	testing.expect_value(t, err4.code, Exit_Code.Usage)
}

@(test)
test_agent_general_builtin_and_override :: proc(t: ^testing.T) {
	dir := cli_temp_dir(t, "agents")
	defer os.remove_all(dir)
	def, err := load_agent(dir, "general")
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect(t, def.builtin)
	testing.expect(t, !def.tools_explicit)

	agent_test_write(
		fmt.tprintf("%s/agents/general.md", dir),
		"---\nname: general\ndescription: overridden\ntools: read_file\n---\n正文\n",
	)
	def2, err2 := load_agent(dir, "general")
	testing.expect_value(t, err2.code, Exit_Code.OK)
	testing.expect(t, !def2.builtin)
	testing.expect_value(t, def2.description, "overridden")
	testing.expect_value(t, len(def2.tools), 1)
}

@(test)
test_agent_unknown_name :: proc(t: ^testing.T) {
	dir := cli_temp_dir(t, "agents-missing")
	defer os.remove_all(dir)
	_, err := load_agent(dir, "nope")
	testing.expect_value(t, err.code, Exit_Code.Usage)
}

@(test)
test_resolve_agent_tools_applies_defaults_and_depth :: proc(t: ^testing.T) {
	registry := agent_test_registry()
	def := agent_default_general()
	all, err := resolve_agent_tools(def, &registry, 0, 1)
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, strings.join(all, ","), "read_file,bash,task")

	depth, derr := resolve_agent_tools(def, &registry, 1, 1)
	testing.expect_value(t, derr.code, Exit_Code.OK)
	testing.expect_value(t, strings.join(depth, ","), "read_file,bash")

	def.tools_explicit = true
	def.tools = []string{"bash", "read_file"}
	selected, serr := resolve_agent_tools(def, &registry, 0, 1)
	testing.expect_value(t, serr.code, Exit_Code.OK)
	testing.expect_value(t, strings.join(selected, ","), "read_file,bash")

	def.tools = []string{"grep"}
	_, uerr := resolve_agent_tools(def, &registry, 0, 1)
	testing.expect_value(t, uerr.code, Exit_Code.Usage)
}
