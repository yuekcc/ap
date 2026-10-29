package engine

import "core:encoding/json"
import "core:fmt"
import "core:strings"

Tool_Def :: struct {
	type:     string,
	function: Function_Def,
}

Function_Def :: struct {
	name:        string,
	description: string,
	parameters:  json.Value,
}

Tool_Info :: struct {
	name:        string,
	description: string,
	parameters:  string,
}

TOOL_INFOS := [5]Tool_Info {
	{
		name = "read_file",
		description = "按行读取 UTF-8 文本文件；单次最多 2000 行，返回首行为元信息。",
		parameters = `{"type":"object","properties":{"file_path":{"type":"string","description":"文件路径，绝对或相对启动目录"},"start_line":{"type":"integer","minimum":1,"description":"起始行号（含），默认 1"},"end_line":{"type":"integer","minimum":1,"description":"结束行号（含），默认 start_line+499"}},"required":["file_path"],"additionalProperties":false}`,
	},
	{
		name = "write_file",
		description = "写入 UTF-8 文本文件；自动创建父目录，CRLF 统一为 LF，覆盖已有文件。",
		parameters = `{"type":"object","properties":{"file_path":{"type":"string","description":"文件路径"},"content":{"type":"string","description":"完整文件内容"}},"required":["file_path","content"],"additionalProperties":false}`,
	},
	{
		name = "edit_file",
		description = "把文件中的 old_string 替换为 new_string；只支持 UTF-8，写回 LF。",
		parameters = `{"type":"object","properties":{"file_path":{"type":"string"},"old_string":{"type":"string","description":"待替换文本，支持跨行"},"new_string":{"type":"string"},"replace_all":{"type":"boolean","default":false}},"required":["file_path","old_string","new_string"],"additionalProperties":false}`,
	},
	{
		name = "bash",
		description = "使用 bash -c <command> 执行命令；Bash/POSIX 语法；每次独立进程，不保留 cwd/环境变量，stdin 为 NUL，stdout/stderr 合并返回。",
		parameters = `{"type":"object","properties":{"command":{"type":"string","description":"POSIX shell 命令，最多 8000 字符"},"timeout_ms":{"type":"integer","minimum":1,"maximum":600000,"description":"超时毫秒数，默认取配置"}},"required":["command"],"additionalProperties":false}`,
	},
	{
		name = "task",
		description = "启动一个独立 ap 子进程完成自包含任务，只回传最终结论；不设超时，靠父进程中断取消。",
		parameters = `{"type":"object","properties":{"prompt":{"type":"string","description":"子代理提示词，必须自包含"},"agent_name":{"type":"string","description":"agent 名称，默认 general"},"description":{"type":"string","description":"3-5 词任务概括，用于展示"}},"required":["prompt"],"additionalProperties":false}`,
	},
}

tool_info_by_name :: proc(name: string) -> (Tool_Info, bool) {
	for info in TOOL_INFOS {
		if info.name == name {
			return info, true
		}
	}
	return {}, false
}

tool_available :: proc(agent: Agent_Def, name: string, depth, max_depth: int) -> bool {
	if !agent_has_tool(agent, name) {
		return false
	}
	if name == "task" && depth >= max_depth {
		return false
	}
	return true
}

available_tool_names :: proc(agent: Agent_Def, depth, max_depth: int) -> []string {
	names := make([dynamic]string, 0, len(agent.tools))
	for info in TOOL_INFOS {
		if tool_available(agent, info.name, depth, max_depth) {
			append(&names, info.name)
		}
	}
	return names[:]
}

tool_definitions :: proc(agent: Agent_Def, depth, max_depth: int) -> ([]Tool_Def, Error) {
	defs := make([dynamic]Tool_Def, 0, 5)
	for info in TOOL_INFOS {
		if !tool_available(agent, info.name, depth, max_depth) {
			continue
		}
		params, perr := json.parse_string(info.parameters, .JSON, true)
		if perr != nil {
			return nil, make_error(.Internal, "invalid tool schema for %s: %v", info.name, perr)
		}
		append(
			&defs,
			Tool_Def {
				type = "function",
				function = Function_Def {
					name = info.name,
					description = info.description,
					parameters = params,
				},
			},
		)
	}
	return defs[:], ok_error()
}

tool_prompt_section :: proc(agent: Agent_Def, depth, max_depth: int) -> string {
	b := strings.builder_make()
	names := available_tool_names(agent, depth, max_depth)
	if len(names) == 0 {
		return "（本次没有可用工具）"
	}
	for name in names {
		info, _ := tool_info_by_name(name)
		fmt.sbprintf(&b, "\n### %s\n%s\n参数 JSON Schema: %s\n", info.name, info.description, info.parameters)
	}
	return strings.to_string(b)
}
