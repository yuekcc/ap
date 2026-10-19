package ap

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

Chat_Tool_Call :: struct {
	id:       string,
	type:     string,
	function: Chat_Tool_Function,
}

Chat_Tool_Function :: struct {
	name:      string,
	arguments: string,
}

Chat_Message :: struct {
	role:         string,
	content:      Maybe(string) `json:"content"`,
	tool_calls:   []Chat_Tool_Call `json:"tool_calls,omitempty"`,
	tool_call_id: Maybe(string) `json:"tool_call_id,omitempty"`,
}

System_Prompt_Options :: struct {
	cwd:           string,
	config_dir:    string,
	agent:         Agent_Def,
	append_prompt: string,
	tool_section:  string,
}

FIXED_INSTRUCTIONS :: `你是 ap，一个命令行 coding agent。你通过工具读写文件、执行命令、启动子代理，完成用户给出的任务。

行为约束：
- 全自动执行，没有审批、没有沙箱；工具调用会直接生效。不要请求确认，也不要假设有交互界面。
- 工具串行执行；一次响应里的多个调用会按顺序执行，不共享 cwd、环境变量或 shell 变量。
- 不要臆造文件内容或命令输出；需要事实时用 read_file / bash 读取或验证。
- 修改前先读相关文件；改完后尽量用构建、测试或命令验证，不要只看代码。
- read_file 有分页上限（2000 行）；大文件按页读取，不要一次请求全文。
- bash 的完整输出会返回，超过阈值的内容通过 transcript 的 blob 间接存储，不影响你看到的内容；但超长输出会触发硬上限并终止命令，必要时分段处理。
- 相对路径相对启动目录；绝对路径可用；不支持 --add-dir。
- 工具失败是给你修正的输入，不会终止循环；只有基础设施故障才会终止。
- 最终回答保持简洁，说明做了什么、验证结果和仍未解决的问题。
`

JSON_EXAMPLE :: `
## 输出要求
正常使用 assistant 文本与 tool_calls 响应。完成前不要输出“我将要做”的空话；能直接做的就用工具做。`

system_prompt_tool_section :: proc(agent: Agent_Def, depth, max_depth: int) -> string {
	return tool_prompt_section(agent, depth, max_depth)
}

build_system_prompt :: proc(opts: System_Prompt_Options) -> string {
	b := strings.builder_make()
	strings.write_string(&b, FIXED_INSTRUCTIONS)
	strings.write_string(&b, JSON_EXAMPLE)
	strings.write_string(&b, "\n## 工具\n")
	strings.write_string(&b, opts.tool_section)
	strings.write_string(&b, "\n\n## 环境\n")
	fmt.sbprintf(&b, "- OS: %v\n", ODIN_OS)
	fmt.sbprintf(&b, "- cwd: %s\n", opts.cwd)
	fmt.sbprintf(&b, "- 当前时间: %v\n", time.now())
	fmt.sbprintf(&b, "- git 仓库: %s\n", "是" if find_git_root(opts.cwd) != "" else "否")

	global_memory := fmt.tprintf("%s/AGENTS.md", opts.config_dir)
	if os.exists(global_memory) {
		if data, err := os.read_entire_file_from_path(global_memory, context.allocator); err == nil {
			strings.write_string(&b, "\n## 全局记忆 (AGENTS.md)\n")
			strings.write_string(&b, string(data))
			strings.write_string(&b, "\n")
		}
	}

	project_files := project_memory_files(opts.cwd)
	for file in project_files {
		if data, err := os.read_entire_file_from_path(file, context.allocator); err == nil {
			fmt.sbprintf(&b, "\n## 项目记忆 (%s)\n", file)
			strings.write_string(&b, string(data))
			strings.write_string(&b, "\n")
		}
	}

	if len(opts.agent.body) > 0 {
		fmt.sbprintf(&b, "\n## Agent 定义 (%s)\n", opts.agent.name)
		strings.write_string(&b, opts.agent.body)
		strings.write_string(&b, "\n")
	}

	if len(opts.append_prompt) > 0 {
		strings.write_string(&b, "\n## 追加指令\n")
		strings.write_string(&b, opts.append_prompt)
		strings.write_string(&b, "\n")
	}
	return strings.to_string(b)
}

find_git_root :: proc(start: string) -> string {
	dir := start
	for len(dir) > 0 {
		git_path, _ := os.join_path([]string{dir, ".git"}, context.allocator)
		if os.exists(git_path) {
			return dir
		}
		parent := os.dir(dir)
		if parent == dir || len(parent) == 0 {
			break
		}
		dir = parent
	}
	return ""
}

project_memory_files :: proc(cwd: string) -> []string {
	git_root := find_git_root(cwd)
	dirs := make([dynamic]string, 0, 8)
	dir := cwd
	for len(dir) > 0 {
		append(&dirs, dir)
		if len(git_root) > 0 && dir == git_root {
			break
		}
		parent := os.dir(dir)
		if parent == dir || len(parent) == 0 {
			break
		}
		dir = parent
	}

	// 近 → 远收集，再反转为远 → 近。
	files := make([dynamic]string, 0, len(dirs))
	for memory_dir in dirs {
		base := os.base(memory_dir)
		if strings.has_prefix(base, ".") {
			continue
		}
		path, _ := os.join_path([]string{memory_dir, "AGENTS.md"}, context.allocator)
		if os.exists(path) && os.is_file(path) {
			canonical, cerr := canonicalize_path(path, true)
			if cerr.code != .OK {
				canonical = path
			}
			append(&files, canonical)
		}
	}
	// 去重（符号链接可能让不同祖先落到同一物理文件）；保留更近的文件。
	seen := make(map[string]bool, len(files))
	unique := make([dynamic]string, 0, len(files))
	for path in files {
		if path in seen {
			continue
		}
		seen[path] = true
		append(&unique, path)
	}
	ordered := make([dynamic]string, 0, len(unique))
	for i := len(unique) - 1; i >= 0; i -= 1 {
		append(&ordered, unique[i])
	}
	return ordered[:]
}

context_build :: proc(project: Project, events: []Event) -> (string, []Chat_Message, Error) {
	start, system_prompt, serr := session_system_prompt(project, events)
	if !is_ok(serr) {
		return "", nil, serr
	}
	_ = start
	messages, merr := project_messages(project, events)
	if !is_ok(merr) {
		return "", nil, merr
	}
	return system_prompt, messages, ok_error()
}

content_block_text :: proc(project: Project, block: Content_Block) -> (string, Error) {
	if ref, has_ref := block.text_ref.?; has_ref {
		data, berr := blob_read(project, ref)
		if !is_ok(berr) {
			return "", berr
		}
		return string(data), ok_error()
	}
	if text, has_text := block.text.?; has_text {
		return text, ok_error()
	}
	return "", ok_error()
}

content_block_input :: proc(project: Project, block: Content_Block) -> (json.Value, Error) {
	if ref, has_ref := block.input_ref.?; has_ref {
		data, berr := blob_read(project, ref)
		if !is_ok(berr) {
			return nil, berr
		}
		value, perr := json.parse_string(string(data), .JSON, true)
		if perr != nil {
			return nil, make_error(.Usage, "tool input blob %s is not valid JSON: %v", ref, perr)
		}
		return value, ok_error()
	}
	return block.input, ok_error()
}

tool_result_content :: proc(project: Project, end: Tool_Execution_End_Event) -> (string, Error) {
	content := ""
	if ref, has_ref := end.content_ref.?; has_ref {
		data, berr := blob_read(project, ref)
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
	// 先收集 tool result，之后按 assistant 的 tool_use 顺序配对。
	results := make(map[string]Tool_Execution_End_Event, 8)
	for ev in events {
		if ev.type != "tool_execution_end" {
			continue
		}
		end: Tool_Execution_End_Event
		if uerr := json.unmarshal_string(ev.line, &end); uerr != nil {
			return nil, make_error(.Usage, "cannot parse tool_execution_end event: %v", uerr)
		}
		results[end.tool_call_id] = end
	}

	messages := make([dynamic]Chat_Message, 0, len(events))
	for ev in events {
		switch ev.type {
		case "user_message":
			user: User_Message_Event
			if uerr := json.unmarshal_string(ev.line, &user); uerr != nil {
				return nil, make_error(.Usage, "cannot parse user_message event: %v", uerr)
			}
			append_chat_message(&messages, Chat_Message{role = "user", content = user.content})
		case "message_end":
			end: Message_End_Event
			if uerr := json.unmarshal_string(ev.line, &end); uerr != nil {
				return nil, make_error(.Usage, "cannot parse message_end event: %v", uerr)
			}
			if end.stop_reason == "cancelled" {
				continue
			}

			text_parts := make([dynamic]string, 0, 2)
			tool_calls := make([dynamic]Chat_Tool_Call, 0, 2)
			has_any_block := false
			for block in end.content {
				switch block.type {
				case "text":
					text, terr := content_block_text(project, block)
					if !is_ok(terr) {
						return nil, terr
					}
					if len(text) > 0 {
						append(&text_parts, text)
						has_any_block = true
					}
				case "tool_use":
					id, has_id := block.id.?
					name, has_name := block.name.?
					if !has_id || len(id) == 0 || !has_name || len(name) == 0 {
						continue
					}
					if _, has_result := results[id]; !has_result {
						// 未闭合的 tool call：投影时删除，不写修复事件。
						continue
					}
					input, ierr := content_block_input(project, block)
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
								arguments = json_arguments_string(input),
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
				role = "assistant",
				tool_calls = tool_calls[:],
			}
			if len(text_parts) > 0 {
				msg.content = strings.join(text_parts[:], "\n", context.allocator)
			}
			append_chat_message(&messages, msg)

			for call in msg.tool_calls {
				end := results[call.id]
				content, rerr := tool_result_content(project, end)
				if !is_ok(rerr) {
					return nil, rerr
				}
				append(
					&messages,
					Chat_Message {
						role = "tool",
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
			case "user":
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
			case "assistant":
				left, left_ok := last.content.?
				right, right_ok := msg.content.?
				if left_ok && right_ok && len(left) > 0 && len(right) > 0 {
					last.content = fmt.tprintf("%s\n%s", left, right)
				} else if !left_ok && right_ok {
					last.content = msg.content
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
	data, err := json.marshal(messages)
	if err != nil {
		return nil
	}
	return data
}
