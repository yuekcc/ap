package tool

import "../platform"

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

Registry :: struct {
	tools: []Tool,
}

// 注册表在 session 生命周期内不可变。空名与重复名在注册时拒绝。
registry_init :: proc(tools: []Tool) -> (Registry, platform.Error) {
	seen := make(map[string]bool, len(tools))
	defer delete(seen)
	for tool in tools {
		if len(tool.name) == 0 {
			return {}, platform.errorf("tool name must not be empty")
		}
		if tool.name in seen {
			return {}, platform.errorf("duplicate tool name %q", tool.name)
		}
		seen[tool.name] = true
	}
	return {tools = tools}, platform.ok_error()
}

registry_find :: proc(registry: ^Registry, name: string) -> (^Tool, bool) {
	if registry == nil {
		return nil, false
	}
	for i in 0 ..< len(registry.tools) {
		if registry.tools[i].name == name {
			return &registry.tools[i], true
		}
	}
	return nil, false
}

registry_names :: proc(registry: ^Registry) -> []string {
	if registry == nil {
		return nil
	}
	names := make([]string, len(registry.tools))
	for tool, i in registry.tools {
		names[i] = tool.name
	}
	return names
}

// 过滤 active_tools；输出顺序始终按 Registry.tools 的声明顺序。
// 未知名字返回错误；空切片表示零工具。
registry_select :: proc(registry: ^Registry, names: []string) -> ([]string, platform.Error) {
	active := make(map[string]bool, len(names))
	defer delete(active)
	for name in names {
		if _, found := registry_find(registry, name); !found {
			return nil, platform.errorf("unknown tool %q", name)
		}
		active[name] = true
	}
	selected := make([dynamic]string, 0, len(active))
	if registry != nil {
		for tool in registry.tools {
			if tool.name in active {
				append(&selected, tool.name)
			}
		}
	}
	return selected[:], platform.ok_error()
}

registry_definitions :: proc(
	registry:     ^Registry,
	active_tools: []string,
) -> ([]Tool_Def, platform.Error) {
	return registry_definitions_in(registry, active_tools, context.allocator)
}

// registry_definitions_in 语义与 registry_definitions 相同，只是把工具 schema
// 的解析结果放到 allocator。Loop 每个 step 都要重建一次，交给 step arena
// 可以随 step 结束整体回收。
registry_definitions_in :: proc(
	registry:     ^Registry,
	active_tools: []string,
	allocator:    runtime.Allocator,
) -> ([]Tool_Def, platform.Error) {
	active := active_set(active_tools)
	defer delete(active)

	defs := make([dynamic]Tool_Def, 0, len(active), allocator)
	if registry != nil {
		for tool in registry.tools {
			if !(tool.name in active) {
				continue
			}
			params, perr := json.parse_string(tool.parameters_json, .JSON, true, allocator)
			if perr != nil {
				return nil, platform.errorf("invalid tool schema for %s: %v", tool.name, perr)
			}
			append(
				&defs,
				Tool_Def {
					type = "function",
					function = Function_Def {
						name = tool.name,
						description = tool.description,
						parameters = params,
					},
				},
			)
		}
	}
	return defs[:], platform.ok_error()
}

registry_prompt_section :: proc(registry: ^Registry, active_tools: []string) -> string {
	active := active_set(active_tools)
	defer delete(active)

	b := strings.builder_make()
	wrote_any := false
	if registry != nil {
		for tool in registry.tools {
			if !(tool.name in active) {
				continue
			}
			wrote_any = true
			fmt.sbprintf(
				&b,
				"\n### %s\n%s\n参数 JSON Schema: %s\n",
				tool.name,
				tool.description,
				tool.parameters_json,
			)
		}
	}
	if !wrote_any {
		return "（本次没有可用工具）"
	}
	return strings.to_string(b)
}

active_set :: proc(names: []string) -> map[string]bool {
	set := make(map[string]bool, len(names))
	for name in names {
		set[name] = true
	}
	return set
}
