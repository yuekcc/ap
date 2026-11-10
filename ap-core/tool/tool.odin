package tool

import "../platform"

import "core:encoding/json"

// ---- 工具契约 ----
//
// SDK 只定义工具的形状与执行管线；具体工具（文件、bash、子代理）属于应用层。
// Tool.user 是宿主绑定的不透明配置，SDK 不解释。

Progress_Kind :: enum {
	Block,
	Line,
}

Function_Def :: struct {
	name:        string,
	description: string,
	parameters:  json.Value,
}

Tool_Def :: struct {
	type:     string,
	function: Function_Def,
}

// Tool_Image 是工具返回给引擎的图片附件。data 由工具用 context.allocator
// 分配，引擎写入 blob 后负责释放；name 与 mime_type 只用于记录和提示词。
Tool_Image :: struct {
	name:      string,
	mime_type: string,
	data:      []byte,
}

Tool_Result :: struct {
	ok:          bool,
	content:     string,
	error:       string,
	duration_ms: int,
	exit_code:   Maybe(int),
	metadata:    json.Value,
	images:      []Tool_Image,
	fatal:       bool,
}

Tool_Context :: struct {
	cwd:               string,
	project:           platform.Project,
	cancel:            ^platform.Cancel_Token,
	session_id:        string,
	parent_session_id: Maybe(string),
	tool_call_id:      string,
	agent_name:        string,
	agent_depth:       int,
	transcript_path:   string,

	on_update:     proc(user: rawptr, chunk: string),
	update_user:   rawptr,
	on_progress:   proc(user: rawptr, kind: Progress_Kind, line: string),
	progress_user: rawptr,
}

Tool :: struct {
	name:            string,
	description:     string,
	parameters_json: string, // JSON Schema 文本
	user:            rawptr, // 应用层配置；SDK 视为不透明
	execute: proc(
		user: rawptr,
		args: json.Value,
		ctx:  ^Tool_Context,
	) -> Tool_Result,
}

tool_ok :: proc(content: string) -> Tool_Result {
	return {ok = true, content = content}
}

tool_fail :: proc(message: string) -> Tool_Result {
	return {ok = false, error = message}
}
