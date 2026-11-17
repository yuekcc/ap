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
		description = "读取文件内容。文本单次最多 2000 行或 50KB（先到者为准），大文件用 offset/limit 分页；需要完整内容时按返回里的 offset 继续读。",
		parameters = `{"type":"object","properties":{"file_path":{"type":"string","description":"文件路径（文本或图片），绝对或相对启动目录"},"offset":{"type":"integer","minimum":1,"description":"起始行号（从 1 开始）"},"limit":{"type":"integer","minimum":1,"description":"最多读取的行数"}},"required":["file_path"],"additionalProperties":false}`,
	},
	{
		name = "write_file",
		description = "写入文件内容。文件不存在时创建，已存在时覆盖，自动创建父目录。",
		parameters = `{"type":"object","properties":{"file_path":{"type":"string","description":"文件路径，绝对或相对启动目录"},"content":{"type":"string","description":"要写入的完整文件内容"}},"required":["file_path","content"],"additionalProperties":false}`,
	},
	{
		name = "edit_file",
		description = "用精确文本替换编辑单个文件。每处 edits[].oldText 必须匹配原文件中唯一、不重叠的片段；同一块或相邻行的多处改动合并成一条，不要为了连接相距较远的改动而包含大段未变内容。",
		parameters = `{"type":"object","properties":{"file_path":{"type":"string","description":"文件路径，绝对或相对启动目录"},"edits":{"type":"array","description":"一处或多处替换。每条都按原文件匹配，不是按增量匹配；不要重叠或嵌套；相邻改动合并成一条。","items":{"type":"object","properties":{"oldText":{"type":"string","description":"与原文件精确匹配的唯一片段，不能与同一调用中的其他 edits[].oldText 重叠"},"newText":{"type":"string","description":"这条编辑的替换文本"}},"required":["oldText","newText"],"additionalProperties":false}}},"required":["file_path","edits"],"additionalProperties":false}`,
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

// read_file 的描述随配置变化：模型只有看到图片能力时才会对图片路径调用
// read_file，而不是绕去 bash。
read_file_description :: proc(cfg: ^Tool_Config) -> string {
	base := TOOL_INFOS[0].description
	if cfg != nil && cfg.image_input {
		return fmt.tprintf(
			"%s也支持读取图片：按魔数识别 PNG、JPEG、GIF、WebP，直接传 file_path 即可，图片会作为视觉附件返回；offset/limit 对图片无效；单张上限 %d 字节。",
			base,
			cfg.image_max_bytes,
		)
	}
	return fmt.tprintf("%s当前未启用图片读取；PNG/JPEG/GIF/WebP 会返回错误。", base)
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
		description := info.description
		if info.name == "read_file" {
			description = read_file_description(cfg)
		}
		tools[i] = tool.Tool {
			name = info.name,
			description = description,
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
		case:
			// 新增工具忘了加 case 时，execute 会是 nil，延迟到运行时才炸。
			assert(false, "tool info without an execute implementation")
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
