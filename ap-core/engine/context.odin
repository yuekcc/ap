package engine

import "../platform"
import "../tool"

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

Chat_Tool_Call :: struct {
	id:       string,
	type:     string,
	function: Chat_Tool_Function,
}

Chat_Tool_Function :: struct {
	name:      string,
	arguments: string,
}

// 文本块之间的分隔符。
NEWLINE_SEP :: "\n"

Chat_Message :: struct {
	role:              string,
	content:           Maybe(string) `json:"content"`,
	reasoning_content: Maybe(string) `json:"reasoning_content,omitempty"`,
	tool_calls:        []Chat_Tool_Call `json:"tool_calls,omitempty"`,
	tool_call_id:      Maybe(string) `json:"tool_call_id,omitempty"`,
}

System_Prompt_Options :: struct {
	// 非空时替换内置 base；空字符串表示使用 SYSTEM_PROMPT。
	base_override: Maybe(string),
	tool_section:  string,
	// 应用层按调用顺序追加的原始 Markdown 块。
	sections:      []string,
}

// 固定指令与输出要求在编译期从 ap-core/engine/prompts/system.md 内嵌进二进制。
// 编辑提示词直接改那个 markdown 文件即可；运行时不依赖 prompts/ 目录。
SYSTEM_PROMPT :: #load("prompts/system.md", string)

// SDK 只固定 base 与工具段；其余段落由应用层按顺序 append。
build_system_prompt :: proc(opts: System_Prompt_Options) -> string {
	b := strings.builder_make()
	base := SYSTEM_PROMPT
	if value, ok := opts.base_override.?; ok && len(value) > 0 {
		base = value
	}
	strings.write_string(&b, base)
	if !strings.has_suffix(base, "\n") {
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, "\n## 工具\n")
	strings.write_string(&b, opts.tool_section)
	strings.write_string(&b, "\n")

	for section in opts.sections {
		if len(section) == 0 {
			continue
		}
		strings.write_byte(&b, '\n')
		strings.write_string(&b, section)
		if !strings.has_suffix(section, "\n") {
			strings.write_byte(&b, '\n')
		}
	}
	return strings.to_string(b)
}

context_build :: proc(project: Project, events: []Event) -> (string, []Chat_Message, Error) {
	return context_build_in(project, events, context.allocator)
}

// context_build_in 与 context_build 语义相同（仍是纯函数：同样的 transcript
// 与 project 得到逐字节相同的 messages），只是把全部中间分配放到 allocator。
// Loop 每个 step 都要重建一次上下文，用 step arena 承接这些分配可以随 step
// 结束整体回收，调用方不必逐个 delete。
context_build_in :: proc(
	project: Project,
	events: []Event,
	allocator: runtime.Allocator,
) -> (string, []Chat_Message, Error) {
	_, system_prompt, serr := session_system_prompt_in(project, events, allocator)
	if !is_ok(serr) {
		return "", nil, serr
	}
	messages, merr := project_messages_in(project, events, allocator)
	if !is_ok(merr) {
		return "", nil, merr
	}
	return system_prompt, messages, ok_error()
}

content_block_text :: proc(project: Project, block: Content_Block) -> (string, Error) {
	return content_block_text_in(project, block, context.allocator)
}

content_block_text_in :: proc(
	project: Project,
	block: Content_Block,
	allocator: runtime.Allocator,
) -> (string, Error) {
	text, err := tool.content_block_text_in(project, block, allocator)
	return text, from_platform(err, .Usage)
}

content_block_input :: proc(project: Project, block: Content_Block) -> (json.Value, Error) {
	return content_block_input_in(project, block, context.allocator)
}

content_block_input_in :: proc(
	project: Project,
	block: Content_Block,
	allocator: runtime.Allocator,
) -> (json.Value, Error) {
	if ref, has_ref := block.input_ref.?; has_ref {
		data, berr := blob_read(project, ref, allocator)
		if !is_ok(berr) {
			return nil, berr
		}
		value, perr := json.parse_string(string(data), .JSON, true, allocator)
		if perr != nil {
			return nil, make_error(.Usage, "tool input blob %s is not valid JSON: %v", ref, perr)
		}
		return value, ok_error()
	}
	return block.input, ok_error()
}

tool_result_content :: proc(project: Project, end: Tool_Execution_End_Event) -> (string, Error) {
	return tool_result_content_in(project, end, context.allocator)
}

tool_result_content_in :: proc(
	project: Project,
	end: Tool_Execution_End_Event,
	allocator: runtime.Allocator,
) -> (string, Error) {
	content := ""
	if ref, has_ref := end.content_ref.?; has_ref {
		data, berr := blob_read(project, ref, allocator)
		if !is_ok(berr) {
			return "", berr
		}
		content = string(data)
	} else if value, has_value := end.content.?; has_value {
		content = value
	}
	if end.ok {
		return content, ok_error()
	}
	err_text := "tool failed"
	if value, has_value := end.error.?; has_value {
		err_text = value
	}
	if len(content) > 0 {
		return fmt.tprintf("%s\n%s", err_text, content), ok_error()
	}
	return err_text, ok_error()
}

project_messages :: proc(project: Project, events: []Event) -> ([]Chat_Message, Error) {
	return project_messages_in(project, events, context.allocator)
}

project_messages_in :: proc(
	project: Project,
	events: []Event,
	allocator: runtime.Allocator,
) -> ([]Chat_Message, Error) {
	// 先收集 tool result，之后按 assistant 的 tool_use 顺序配对。
	results := make(map[string]Tool_Execution_End_Event, 8, allocator)
	for ev in events {
		if ev.type != EVENT_TOOL_EXECUTION_END {
			continue
		}
		end: Tool_Execution_End_Event
		if uerr := json.unmarshal_string(ev.line, &end, json.DEFAULT_SPECIFICATION, allocator); uerr != nil {
			return nil, make_error(.Usage, "cannot parse tool_execution_end event: %v", uerr)
		}
		results[end.tool_call_id] = end
	}

	messages := make([dynamic]Chat_Message, 0, len(events), allocator)
	for ev in events {
		switch ev.type {
		case EVENT_USER_MESSAGE:
			user: User_Message_Event
			if uerr := json.unmarshal_string(ev.line, &user, json.DEFAULT_SPECIFICATION, allocator); uerr != nil {
				return nil, make_error(.Usage, "cannot parse user_message event: %v", uerr)
			}
			append_chat_message(&messages, Chat_Message{role = ROLE_USER, content = user.content})
		case EVENT_MESSAGE_END:
			end: Message_End_Event
			if uerr := json.unmarshal_string(ev.line, &end, json.DEFAULT_SPECIFICATION, allocator); uerr != nil {
				return nil, make_error(.Usage, "cannot parse message_end event: %v", uerr)
			}
			if end.stop_reason == STOP_REASON_CANCELLED {
				continue
			}

			text_parts := make([dynamic]string, 0, 2, allocator)
			tool_calls := make([dynamic]Chat_Tool_Call, 0, 2, allocator)
			has_any_block := false
			for block in end.content {
				switch block.type {
				case BLOCK_TEXT:
					text, terr := content_block_text_in(project, block, allocator)
					if !is_ok(terr) {
						return nil, terr
					}
					if len(text) > 0 {
						append(&text_parts, text)
						has_any_block = true
					}
				case BLOCK_TOOL_USE:
					id, has_id := block.id.?
					name, has_name := block.name.?
					if !has_id || len(id) == 0 || !has_name || len(name) == 0 {
						continue
					}
					if _, has_result := results[id]; !has_result {
						// 未闭合的 tool call：投影时删除，不写修复事件。
						continue
					}
					input, ierr := content_block_input_in(project, block, allocator)
					if !is_ok(ierr) {
						return nil, ierr
					}
					append(
						&tool_calls,
						Chat_Tool_Call {
							id = id,
							type = "function",
							function = Chat_Tool_Function {
								name = name,
								arguments = platform.json_arguments_string(input),
							},
						},
					)
					has_any_block = true
				}
			}
			if !has_any_block {
				continue
			}
			msg := Chat_Message {
				role = ROLE_ASSISTANT,
				tool_calls = tool_calls[:],
			}
			if reasoning, has_reasoning := end.reasoning.?; has_reasoning && len(reasoning) > 0 {
				msg.reasoning_content = reasoning
			}
			if len(text_parts) > 0 {
				msg.content = strings.join(text_parts[:], NEWLINE_SEP, allocator)
			}
			append_chat_message(&messages, msg)

			for call in msg.tool_calls {
				end := results[call.id]
				content, rerr := tool_result_content_in(project, end, allocator)
				if !is_ok(rerr) {
					return nil, rerr
				}
				append(
					&messages,
					Chat_Message {
						role = ROLE_TOOL,
						content = content,
						tool_call_id = call.id,
					},
				)
			}
		}
	}
	return messages[:], ok_error()
}

append_chat_message :: proc(messages: ^[dynamic]Chat_Message, msg: Chat_Message) {
	if len(messages^) > 0 {
		last := &messages[len(messages) - 1]
		if last.role == msg.role {
			switch msg.role {
			case ROLE_USER:
				left, left_ok := last.content.?
				right, right_ok := msg.content.?
				if left_ok && right_ok {
					last.content = fmt.tprintf("%s\n%s", left, right)
					return
				}
				if !left_ok {
					last.content = msg.content
					return
				}
				return
			case ROLE_ASSISTANT:
				left, left_ok := last.content.?
				right, right_ok := msg.content.?
				if left_ok && right_ok && len(left) > 0 && len(right) > 0 {
					last.content = fmt.tprintf("%s\n%s", left, right)
				} else if !left_ok && right_ok {
					last.content = msg.content
				}
				if new_reasoning, has_reasoning := msg.reasoning_content.?; has_reasoning {
					if old_reasoning, old_ok := last.reasoning_content.?; old_ok && len(old_reasoning) > 0 && len(new_reasoning) > 0 {
						last.reasoning_content = fmt.tprintf("%s\n%s", old_reasoning, new_reasoning)
					} else {
						last.reasoning_content = msg.reasoning_content
					}
				}
				if len(msg.tool_calls) > 0 {
					tools := make([dynamic]Chat_Tool_Call, 0, len(last.tool_calls) + len(msg.tool_calls))
					append(&tools, ..last.tool_calls)
					append(&tools, ..msg.tool_calls)
					last.tool_calls = tools[:]
				}
				return
			}
		}
	}
	append(messages, msg)
}

messages_bytes :: proc(messages: []Chat_Message) -> []byte {
	data, err := platform.json_marshal_utf8(messages)
	if err != nil {
		return nil
	}
	return data
}
