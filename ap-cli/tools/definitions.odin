package aptools

import platform "../../ap-core/platform"
import tool "../../ap-core/tool"

import "core:encoding/json"
import "core:fmt"
import "core:strings"

Tool_Info :: struct {
	name:        string,
	description: string,
	parameters:  string,
}

TOOL_INFOS := [5]Tool_Info {
	{
		name = "read_file",
		description = "按行读取 UTF-8 文本文件；单次最多 2000 行，大文件用 start_line/end_line 分页读取，返回首行为元信息。",
		parameters = `{"type":"object","properties":{"file_path":{"type":"string","description":"文件路径，绝对或相对启动目录"},"start_line":{"type":"integer","minimum":1,"description":"起始行号（含），默认 1"},"end_line":{"type":"integer","minimum":1,"description":"结束行号（含），默认 start_line+499"}},"required":["file_path"],"additionalProperties":false}`,
	},
	{
		name = "write_file",
		description = "写入 UTF-8 文本文件；自动创建父目录，CRLF 统一为 LF，覆盖已有文件。",
		parameters = `{"type":"object","properties":{"file_path":{"type":"string","description":"文件路径，绝对或相对启动目录"},"content":{"type":"string","description":"完整文件内容"}},"required":["file_path","content"],"additionalProperties":false}`,
	},
	{
		name = "edit_file",
		description = "把文件中的 old_string 替换为 new_string；只支持 UTF-8，写回 LF。",
		parameters = `{"type":"object","properties":{"file_path":{"type":"string","description":"文件路径，绝对或相对启动目录"},"old_string":{"type":"string","description":"待替换文本，支持跨行"},"new_string":{"type":"string"},"replace_all":{"type":"boolean","default":false}},"required":["file_path","old_string","new_string"],"additionalProperties":false}`,
	},
	{
		name = "bash",
		description = "使用 bash -c <command> 执行 Bash/POSIX 命令；每次独立进程，不保留 cwd/环境变量，stdin 为 NUL。stdout/stderr 合并返回，最多 2000 行；超出时提供完整输出的 .txt 路径，用 read_file 分页续读。输出过大可能终止命令，必要时分段执行。",
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

// 按声明顺序返回全部内置工具。cfg 必须活得比 registry / session 长。
builtin_tools :: proc(cfg: ^Tool_Config) -> []tool.Tool {
	tools := make([]tool.Tool, len(TOOL_INFOS))
	for info, i in TOOL_INFOS {
		tools[i] = tool.Tool {
			name = info.name,
			description = info.description,
			parameters_json = info.parameters,
			user = cfg,
		}
		switch info.name {
		case "read_file":
			tools[i].execute = execute_read_file
		case "write_file":
			tools[i].execute = execute_write_file
		case "edit_file":
			tools[i].execute = execute_edit_file
		case "bash":
			tools[i].execute = execute_bash
		case "task":
			tools[i].execute = execute_task
		}
	}
	return tools
}

builtin_tool_names :: proc() -> []string {
	names := make([]string, len(TOOL_INFOS))
	for info, i in TOOL_INFOS {
		names[i] = info.name
	}
	return names
}

// 工具简表；供宿主展示，输出格式与旧 SDK 一致。
tools_brief :: proc(tool_names: []string) -> string {
	b := strings.builder_make()
	index := 0
	for name in tool_names {
		info, found := tool_info_by_name(name)
		if !found {
			continue
		}
		index += 1
		fmt.sbprintf(&b, "%d. %s: %s\n", index, info.name, info.description)
	}
	if index == 0 {
		return "No tool found\n"
	}
	return strings.to_string(b)
}

arg_error :: proc(err: platform.Error) -> tool.Tool_Result {
	return tool.tool_fail(err.message)
}

args_object :: proc(args: json.Value) -> (json.Object, bool) {
	obj, ok := args.(json.Object)
	return obj, ok
}

execute_read_file :: proc(user: rawptr, args: json.Value, ctx: ^tool.Tool_Context) -> tool.Tool_Result {
	obj, ok := args_object(args)
	if !ok {
		return tool.tool_fail("tool arguments must be a JSON object")
	}
	cfg := (^Tool_Config)(user)
	return tool_read_file(obj, cfg, ctx)
}

execute_write_file :: proc(user: rawptr, args: json.Value, ctx: ^tool.Tool_Context) -> tool.Tool_Result {
	obj, ok := args_object(args)
	if !ok {
		return tool.tool_fail("tool arguments must be a JSON object")
	}
	cfg := (^Tool_Config)(user)
	return tool_write_file(obj, cfg, ctx)
}

execute_edit_file :: proc(user: rawptr, args: json.Value, ctx: ^tool.Tool_Context) -> tool.Tool_Result {
	obj, ok := args_object(args)
	if !ok {
		return tool.tool_fail("tool arguments must be a JSON object")
	}
	cfg := (^Tool_Config)(user)
	return tool_edit_file(obj, cfg, ctx)
}

execute_bash :: proc(user: rawptr, args: json.Value, ctx: ^tool.Tool_Context) -> tool.Tool_Result {
	obj, ok := args_object(args)
	if !ok {
		return tool.tool_fail("tool arguments must be a JSON object")
	}
	cfg := (^Tool_Config)(user)
	return tool_bash(obj, cfg, ctx)
}

execute_task :: proc(user: rawptr, args: json.Value, ctx: ^tool.Tool_Context) -> tool.Tool_Result {
	obj, ok := args_object(args)
	if !ok {
		return tool.tool_fail("tool arguments must be a JSON object")
	}
	cfg := (^Tool_Config)(user)
	return tool_task(obj, cfg, ctx)
}
