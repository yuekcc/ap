package engine

import "../platform"

import "core:fmt"
import "core:os"
import "core:strings"

ALL_TOOL_NAMES := [5]string{"read_file", "write_file", "edit_file", "bash", "task"}

tool_name_valid :: proc(name: string) -> bool { 
	for tool in ALL_TOOL_NAMES {
		if tool == name {
			return true
		}
	}
	return false
}

tool_name_known :: proc(name: string) -> bool {
	return tool_name_valid(name)
}

// 用 CLI 白名单覆盖 agent 定义；顺序按 ALL_TOOL_NAMES，重复项去重。
apply_tool_override :: proc(agent: ^Agent_Def, names: []string) -> Error {
	for name in names {
		if !tool_name_valid(name) {
			return make_error(.Usage, "unknown tool %q", name)
		}
	}
	agent.tools = select_tools(names)
	agent.tools_explicit = true
	return ok_error()
}

// 去重后按 ALL_TOOL_NAMES 的固定顺序返回；忽略未知名字，由调用方负责校验。
select_tools :: proc(names: []string) -> []string {
	selected := make(map[string]bool, len(names))
	for name in names {
		selected[name] = true
	}
	tools := make([dynamic]string, 0, len(selected))
	for tool in ALL_TOOL_NAMES {
		if tool in selected {
			append(&tools, tool)
		}
	}
	return tools[:]
}

Settings :: struct {
	model:                 string,
	base_url:              string,
	api_key:               string,
	max_steps:             int,
	max_agent_depth:       int,
	max_tokens:            int,
	tool_timeout_ms:       int,
	llm_timeout_ms:        int,
	blob_threshold_bytes:  int,
	max_capture_bytes:     int,
	stream_include_usage:  bool,
	path:                  string,
}

DEFAULT_BASE_URL :: "https://api.openai.com/v1"

settings_defaults :: proc() -> Settings {
	return Settings {
		base_url = DEFAULT_BASE_URL,
		max_steps = 100,
		max_agent_depth = 1,
		max_tokens = 8192,
		tool_timeout_ms = 120000,
		llm_timeout_ms = 600000,
		blob_threshold_bytes = 102400,
		max_capture_bytes = 67108864,
		stream_include_usage = true,
	}
}

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
		tools = default_tools(),
		model = nil,
		max_steps = nil,
		body = "",
		source = "<builtin>",
		builtin = true,
	}
}

default_tools :: proc() -> []string {
	tools := make([]string, len(ALL_TOOL_NAMES))
	copy(tools, ALL_TOOL_NAMES[:])
	return tools
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

parse_agent_definition :: proc(path, file_name: string, content: string) -> (Agent_Def, Error) {
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
					if !tool_name_valid(name) {
						return {}, make_error(.Usage, "agent definition %s: unknown tool %q", path, name)
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
	if !def.tools_explicit {
		def.tools = default_tools()
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
	for tool in def.tools {
		if tool == name {
			return true
		}
	}
	return false
}
