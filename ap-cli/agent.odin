package apcli

import platform "../ap-core/platform"
import tool "../ap-core/tool"

import "core:fmt"
import "core:os"
import "core:strings"

// agent 定义属于应用层：解析 $AP_CONFIG/agents/<name>.md 的 frontmatter。
// SDK 只接收解析后的 agent_name / model / max_steps / tools。

Agent_Def :: struct {
	name:           string,
	description:    string,
	tools:          []string,
	tools_explicit: bool,
	model:          Maybe(string),
	max_steps:      Maybe(int),
	body:           string,
	source:         string,
	builtin:        bool,
}

agent_default_general :: proc() -> Agent_Def {
	return Agent_Def {
		name = "general",
		description = "默认 agent，适合多步骤搜索与修改",
		model = nil,
		max_steps = nil,
		body = "",
		source = "<builtin>",
		builtin = true,
	}
}

agent_file_path :: proc(config_dir, name: string) -> string {
	return fmt.tprintf("%s/agents/%s.md", config_dir, name)
}

agent_name_safe :: proc(name: string) -> bool {
	if len(name) == 0 || name == "." || name == ".." {
		return false
	}
	for ch in name {
		valid := (ch >= 'a' && ch <= 'z') ||
		         (ch >= 'A' && ch <= 'Z') ||
		         (ch >= '0' && ch <= '9') ||
		         ch == '-' || ch == '_'
		if !valid {
			return false
		}
	}
	return true
}

load_agent :: proc(config_dir, name: string) -> (Agent_Def, Error) {
	if !agent_name_safe(name) {
		return {}, make_error(.Usage, "invalid agent name %q", name)
	}
	path := agent_file_path(config_dir, name)
	if os.exists(path) {
		data, derr := os.read_entire_file_from_path(path, context.allocator)
		if derr != nil {
			return {}, make_error(.Usage, "cannot read agent definition %s: %v", path, derr)
		}
		if !platform.valid_utf8(data) {
			return {}, make_error(.Usage, "agent definition is not valid UTF-8: %s", path)
		}
		def, aerr := parse_agent_definition(path, name, string(data))
		if !is_ok(aerr) {
			return {}, aerr
		}
		return def, ok_error()
	}
	if name == "general" {
		return agent_default_general(), ok_error()
	}
	return {}, make_error(.Usage, "agent %q not found (expected %s)", name, path)
}

parse_agent_definition :: proc(path, file_name, content: string) -> (Agent_Def, Error) {
	def := Agent_Def {
		source = path,
	}
	body := content
	if strings.has_prefix(content, "---\r\n") || strings.has_prefix(content, "---\n") {
		first_end := strings.index_byte(content, '\n')
		rest := content[first_end + 1:]
		close_index := -1
		offset := 0
		lines, _ := strings.split(rest, "\n")
		for line in lines {
			trimmed := strings.trim_right(line, "\r")
			if trimmed == "---" {
				close_index = offset
				break
			}
			offset += len(line) + 1
		}
		if close_index < 0 {
			return {}, make_error(.Usage, "agent definition %s: missing closing ---", path)
		}
		frontmatter := rest[:close_index]
		after := rest[close_index:]
		if nl := strings.index_byte(after, '\n'); nl >= 0 {
			body = after[nl + 1:]
		} else {
			body = ""
		}

		front_lines, _ := strings.split(frontmatter, "\n")
		for raw_line in front_lines {
			line := strings.trim_space(strings.trim_right(raw_line, "\r"))
			if len(line) == 0 || strings.has_prefix(line, "#") {
				continue
			}
			colon := strings.index_byte(line, ':')
			if colon < 0 {
				log_warn("agent %s: ignoring malformed frontmatter line %q", path, line)
				continue
			}
			key := strings.trim_space(line[:colon])
			value := strings.trim_space(line[colon + 1:])
			if len(value) >= 2 {
				if (value[0] == '"' && value[len(value) - 1] == '"') ||
				   (value[0] == '\'' && value[len(value) - 1] == '\'') {
					value = value[1:len(value) - 1]
				}
			}
			switch key {
			case "name":
				def.name = value
			case "description":
				def.description = value
			case "tools":
				def.tools_explicit = true
				tools := make([dynamic]string, 0, 5)
				parts, _ := strings.split(value, ",")
				for part in parts {
					name := strings.trim_space(part)
					if len(name) == 0 {
						continue
					}
					append(&tools, strings.clone(name))
				}
				def.tools = tools[:]
			case "model":
				if len(value) > 0 {
					def.model = value
				}
			case "max_steps":
				if len(value) > 0 {
					parsed, ok_num := parse_positive_int(value)
					if !ok_num {
						return {}, make_error(.Usage, "agent definition %s: max_steps must be a positive integer", path)
					}
					def.max_steps = parsed
				}
			case:
				log_warn("agent definition %s: unknown field %q ignored", path, key)
			}
		}
	}

	def.body = strings.trim_left(body, "\r\n")
	if len(def.name) == 0 {
		return {}, make_error(.Usage, "agent definition %s: name is required", path)
	}
	if len(def.description) == 0 {
		return {}, make_error(.Usage, "agent definition %s: description is required", path)
	}
	if def.name != file_name {
		return {}, make_error(
			.Usage,
			"agent definition %s: name %q must match file name %q",
			path,
			def.name,
			file_name,
		)
	}
	return def, ok_error()
}

parse_positive_int :: proc(s: string) -> (int, bool) {
	value := 0
	if len(s) == 0 {
		return 0, false
	}
	for ch in s {
		if ch < '0' || ch > '9' {
			return 0, false
		}
		value = value * 10 + int(ch - '0')
		if value > 1_000_000_000 {
			return 0, false
		}
	}
	return value, value > 0
}

agent_has_tool :: proc(def: Agent_Def, name: string) -> bool {
	for tool_name in def.tools {
		if tool_name == name {
			return true
		}
	}
	return false
}

// 白名单规则：agent 定义 tools: > 全部已注册工具。
// task 在 agent_depth >= max_agent_depth 时从生效集合移除。
resolve_agent_tools :: proc(
	def: Agent_Def,
	registry: ^tool.Registry,
	agent_depth, max_agent_depth: int,
) -> ([]string, Error) {
	declared := def.tools
	if !def.tools_explicit {
		declared = tool.registry_names(registry)
	}
	selected, serr := tool.registry_select(registry, declared)
	if !platform.is_ok(serr) {
		return nil, make_error(.Usage, "%s", serr.message)
	}
	active := make([dynamic]string, 0, len(selected))
	for name in selected {
		if name == "task" && agent_depth >= max_agent_depth {
			continue
		}
		append(&active, name)
	}
	return active[:], ok_error()
}
