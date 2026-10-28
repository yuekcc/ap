package protocol

import "core:encoding/json"

// 一行 transcript + 解析出的信封字段。引擎与输出层用这个类型转发事件。
Transcript_Event :: struct {
	v:    int,
	seq:  int,
	ts:   i64,
	type: string,
	line: string,
}

// ---- 类型化 transcript 事件 ----
// 引擎写 transcript、前端历史重建都按这些结构 unmarshal。

Session_Start_Event :: struct {
	using header: Event_Header,
	session_id:          string,
	content:             string,
	role:                string,
	cwd:                 string,
	model:               string,
	provider:            string,
	agent_name:          string,
	agent_depth:         int,
	parent_session_id:   Maybe(string),
	parent_tool_call_id: Maybe(string),
	resumed_from:        Maybe(string),
	content_ref:         Maybe(string) `json:"content_ref,omitempty"`,
	content_bytes:       Maybe(int)    `json:"content_bytes,omitempty"`,
}

Session_End_Event :: struct {
	using header: Event_Header,
	reason: string,
	usage:  Usage,
}

User_Message_Event :: struct {
	using header: Event_Header,
	content: string,
}

Turn_Start_Event :: struct {
	using header: Event_Header,
	turn: int,
}

Turn_End_Event :: struct {
	using header: Event_Header,
	turn:        int,
	stop_reason: string,
	usage:       Usage,
}

Step_Start_Event :: struct {
	using header: Event_Header,
	step: int,
}

Message_Start_Event :: struct {
	using header: Event_Header,
	message_id: string,
	role:       string,
	model:      string,
}

Content_Block :: struct {
	type:          string,
	text:          Maybe(string) `json:"text,omitempty"`,
	text_ref:      Maybe(string) `json:"text_ref,omitempty"`,
	text_bytes:    Maybe(int)    `json:"text_bytes,omitempty"`,
	text_preview:  Maybe(string) `json:"text_preview,omitempty"`,
	id:            Maybe(string) `json:"id,omitempty"`,
	name:          Maybe(string) `json:"name,omitempty"`,
	input:         json.Value    `json:"input,omitempty"`,
	input_ref:     Maybe(string) `json:"input_ref,omitempty"`,
	input_bytes:   Maybe(int)    `json:"input_bytes,omitempty"`,
	input_preview: Maybe(string) `json:"input_preview,omitempty"`,
}

Message_End_Event :: struct {
	using header: Event_Header,
	message_id:  string,
	role:        string,
	content:     []Content_Block,
	stop_reason: string,
	usage:       Maybe(Usage),
	reasoning:   Maybe(string) `json:"reasoning"`,
}

Tool_Execution_Start_Event :: struct {
	using header: Event_Header,
	tool_call_id: string,
	name:         string,
	args:         json.Value    `json:"args,omitempty"`,
	args_ref:     Maybe(string) `json:"args_ref,omitempty"`,
	args_bytes:   Maybe(int)    `json:"args_bytes,omitempty"`,
	args_preview: Maybe(string) `json:"args_preview,omitempty"`,
}

Tool_Execution_End_Event :: struct {
	using header: Event_Header,
	tool_call_id:    string,
	ok:              bool,
	content:         Maybe(string) `json:"content"`,
	content_ref:     Maybe(string) `json:"content_ref,omitempty"`,
	content_bytes:   Maybe(int)    `json:"content_bytes,omitempty"`,
	content_preview: Maybe(string) `json:"content_preview,omitempty"`,
	error:           Maybe(string) `json:"error"`,
	duration_ms:     Maybe(int)    `json:"duration_ms"`,
	exit_code:       Maybe(int)    `json:"exit_code"`,
	metadata:        json.Value    `json:"metadata"`,
}

Error_Event :: struct {
	using header: Event_Header,
	scope:     string,
	kind:      Maybe(string) `json:"kind"`,
	message:   string,
	retryable: bool,
	attempt:   int,
}

Cancel_Event :: struct {
	using header: Event_Header,
	scope:     string,
	target_id: Maybe(string) `json:"target_id"`,
}

// ---- 前端宽松事件 ----

Tool_Call_Delta :: struct {
	index:      int    `json:"index"`,
	id:         string `json:"id"`,
	name:       string `json:"name"`,
	args_delta: string `json:"args_delta"`,
}

Delta :: struct {
	text:      Maybe(string)          `json:"text"`,
	reasoning: Maybe(string)          `json:"reasoning"`,
	tool_call: Maybe(Tool_Call_Delta) `json:"tool_call"`,
}

// stream-json 的 transcript/stream 事件在客户端里共用一个宽松结构。
// content 在不同事件里可能是 string、array 或 null，所以用 json.Value 承载。
Stream_Event :: struct {
	using _: Event_Header,

	session_id:          string        `json:"session_id"`,
	parent_session_id:   Maybe(string) `json:"parent_session_id"`,
	parent_tool_call_id: Maybe(string) `json:"parent_tool_call_id"`,

	role:       string `json:"role"`,
	message_id: string `json:"message_id"`,
	model:      string `json:"model"`,
	delta:      Delta  `json:"delta"`,

	content:     json.Value    `json:"content"`,
	stop_reason: string        `json:"stop_reason"`,
	usage:       Usage         `json:"usage"`,
	reasoning:   Maybe(string) `json:"reasoning"`,

	tool_call_id: string        `json:"tool_call_id"`,
	name:         string        `json:"name"`,
	args:         json.Value    `json:"args"`,
	args_ref:     Maybe(string) `json:"args_ref"`,
	args_bytes:   Maybe(int)    `json:"args_bytes"`,
	args_preview: Maybe(string) `json:"args_preview"`,

	ok:              bool          `json:"ok"`,
	content_ref:     Maybe(string) `json:"content_ref"`,
	content_bytes:   Maybe(int)    `json:"content_bytes"`,
	content_preview: Maybe(string) `json:"content_preview"`,
	error:           Maybe(string) `json:"error"`,
	duration_ms:     Maybe(int)    `json:"duration_ms"`,
	exit_code:       Maybe(int)    `json:"exit_code"`,

	scope:     string        `json:"scope"`,
	kind:      Maybe(string) `json:"kind"`,
	message:   string        `json:"message"`,
	retryable: bool          `json:"retryable"`,
	attempt:   int           `json:"attempt"`,

	target_id: Maybe(string) `json:"target_id"`,
	reason:    string        `json:"reason"`,
	chunk:     string        `json:"chunk"`,

	turn: int `json:"turn"`,
	step: int `json:"step"`,
}
