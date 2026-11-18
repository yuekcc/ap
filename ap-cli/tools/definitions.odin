package aptools

import platform "../../ap-core/platform"
import tool "../../ap-core/tool"

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// 工具说明是模型可见的提示词，用英文并符合 ASD-STE100。
Tool_Info :: struct {
	name:        string,
	description: string,
	parameters:  string,
}

TOOL_INFOS := [5]Tool_Info {
	{
		name = "read_file",
		description = "Read the content of a file. A text read returns at most 2000 lines or 50KB, whichever comes first. To page through a large file, use offset and limit. To get the complete content, continue from the offset in the result.",
		parameters = `{"type":"object","properties":{"file_path":{"type":"string","description":"Path of the file (text or image). Use an absolute path or a path relative to the start directory."},"offset":{"type":"integer","minimum":1,"description":"Line number of the first line to read (starts at 1)."},"limit":{"type":"integer","minimum":1,"description":"Maximum number of lines to read."}},"required":["file_path"],"additionalProperties":false}`,
	},
	{
		name = "write_file",
		description = "Write the content of a file. If the file does not exist, the tool creates it. If the file exists, the tool replaces it. The tool also creates the parent directory.",
		parameters = `{"type":"object","properties":{"file_path":{"type":"string","description":"Path of the file. Use an absolute path or a path relative to the start directory."},"content":{"type":"string","description":"Complete content to write to the file."}},"required":["file_path","content"],"additionalProperties":false}`,
	},
	{
		name = "edit_file",
		description = "Edit one file with exact text replacement. Each edits[].oldText must match one unique sequence in the original file. The sequences must not overlap. Merge changes to the same block or to adjacent lines into one edit. Do not include a large unchanged region only to connect two distant changes.",
		parameters = `{"type":"object","properties":{"file_path":{"type":"string","description":"Path of the file. Use an absolute path or a path relative to the start directory."},"edits":{"type":"array","description":"One or more replacements. The tool matches each replacement against the original file, not against the result of an earlier replacement. Do not overlap or nest the replacements. Merge adjacent changes into one edit.","items":{"type":"object","properties":{"oldText":{"type":"string","description":"Unique sequence that matches the original file exactly. It must not overlap with an oldText of another edit in the same call."},"newText":{"type":"string","description":"Replacement text for this edit."}},"required":["oldText","newText"],"additionalProperties":false}}},"required":["file_path","edits"],"additionalProperties":false}`,
	},
	{
		name = "bash",
		description = "Run a Bash or POSIX command with bash -c <command>. Each call starts a separate process. The process keeps no cwd and no environment variable. stdin is NUL. The tool returns stdout and stderr together, at most 2000 lines. If the output is longer, the result gives the path of a .txt file with the complete output. Continue with read_file and offset. A very large output can stop the command. Divide the command into smaller parts when necessary.",
		parameters = `{"type":"object","properties":{"command":{"type":"string","description":"POSIX shell command, at most 8000 characters."},"timeout_ms":{"type":"integer","minimum":1,"maximum":600000,"description":"Timeout in milliseconds. The default value comes from the configuration."}},"required":["command"],"additionalProperties":false}`,
	},
	{
		name = "task",
		description = "Start a separate ap subprocess for a self-contained task. The tool returns only the final result. There is no timeout. A cancel from the parent process stops the task.",
		parameters = `{"type":"object","properties":{"prompt":{"type":"string","description":"Prompt for the subagent. It must be self-contained."},"agent_name":{"type":"string","description":"Name of the agent. The default is general."},"description":{"type":"string","description":"Summary of the task in 3 to 5 words. The tool uses it for display."}},"required":["prompt"],"additionalProperties":false}`,
	},
}

// read_file 的描述随配置变化：模型只有看到图片能力时才会对图片路径调用
// read_file，而不是绕去 bash。
read_file_description :: proc(cfg: ^Tool_Config) -> string {
	base := TOOL_INFOS[0].description
	if cfg != nil && cfg.image_input {
		return fmt.tprintf(
			"%s The tool also reads an image. It identifies PNG, JPEG, GIF, and WebP from the file signature. Pass the file_path only. The tool returns the image as a visual attachment. offset and limit have no effect on an image. The size limit is %d bytes for one image.",
			base,
			cfg.image_max_bytes,
		)
	}
	return fmt.tprintf("%s Image input is off. PNG, JPEG, GIF, and WebP return an error.", base)
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
