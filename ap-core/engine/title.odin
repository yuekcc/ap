package engine

import "../platform"

import "base:runtime"
import "core:encoding/json"
import "core:strings"

// 会话标题：一次不带工具的模型调用，把对话浓缩成一行文本，追加 session_title 事件。
//
// transcript 只追加：重新生成 = 再追加一条，读取方取最后一条。标题事件不进
// messages，context_build 仍是 (transcript, project) 的纯函数。

TITLE_PROMPT :: #load("prompts/title.md", string)

// 标题在侧栏只占一行，太长的会被 CSS 截断；没必要为它多花 token。
TITLE_MAX_RUNES :: 40
// digest 只取首条请求与最近一轮，够判主题，又不必把整段对话再喂一遍。
TITLE_DIGEST_BYTES :: 2000
TITLE_MAX_TOKENS :: 256

Session_Title_Result :: struct {
	title: string,
	usage: Usage,
}

session_title_destroy :: proc(result: ^Session_Title_Result) {
	delete(result.title)
	result.title = ""
}

// 最后一条写入的标题；没有时返回 false。解析失败按「没有标题」处理。
session_title_from_events :: proc(events: []Event) -> (string, bool) {
	for i := len(events) - 1; i >= 0; i -= 1 {
		if events[i].type != EVENT_SESSION_TITLE {
			continue
		}
		event: Session_Title_Event
		if json.unmarshal_string(events[i].line, &event, json.DEFAULT_SPECIFICATION, context.temp_allocator) != nil {
			return "", false
		}
		title := strings.trim_space(event.title)
		if len(title) > 0 {
			return title, true
		}
		return "", false
	}
	return "", false
}

// 生成标题的输入：首条用户消息说明意图，最近一轮说明当前进展与主题。
title_digest_in :: proc(
	project: Project,
	events: []Event,
	allocator: runtime.Allocator,
) -> (string, Error) {
	messages, _, merr := project_messages_with_slots_in(project, events, allocator)
	if !is_ok(merr) {
		return "", merr
	}
	first_user, last_user, last_assistant := "", "", ""
	have_user, have_assistant := false, false
	for message in messages {
		text, has_text := message.content.?
		if !has_text || len(text) == 0 {
			continue
		}
		switch message.role {
		case ROLE_USER:
			if !have_user {
				first_user = text
			}
			last_user = text
			have_user = true
		case ROLE_ASSISTANT:
			last_assistant = text
			have_assistant = true
		}
	}
	if !have_user {
		return "", make_error(.Usage, "session has no user message yet")
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "首次请求：\n")
	strings.write_string(&b, platform.utf8_prefix(transmute([]byte)first_user, TITLE_DIGEST_BYTES))
	if last_user != first_user {
		strings.write_string(&b, "\n\n最近的请求：\n")
		strings.write_string(&b, platform.utf8_prefix(transmute([]byte)last_user, TITLE_DIGEST_BYTES))
	}
	if have_assistant {
		strings.write_string(&b, "\n\n最近的回复：\n")
		strings.write_string(&b, platform.utf8_prefix(transmute([]byte)last_assistant, TITLE_DIGEST_BYTES))
	}
	return strings.to_string(b), ok_error()
}

// session_title_generate 生成标题并追加 session_title 事件。
// 失败时 transcript 不变，调用方按普通错误处理；session_end 由调用方补写。
session_title_generate :: proc(
	s: ^Session,
	cancel: ^platform.Cancel_Token,
	emitter: Emitter,
) -> (Session_Title_Result, Error) {
	result := Session_Title_Result{}
	digest, derr := title_digest_in(s.project, s.events, context.allocator)
	if !is_ok(derr) {
		return result, derr
	}
	defer delete(digest)

	messages := []Chat_Message {
		{role = ROLE_SYSTEM, content = TITLE_PROMPT},
		{role = ROLE_USER, content = digest},
	}
	request := Chat_Message_Request {
		model         = s.model,
		messages      = messages,
		// 标题调用不带工具：它只产一行文本。
		tools         = nil,
		max_tokens    = TITLE_MAX_TOKENS,
		include_usage = s.settings.stream_include_usage,
	}
	provider := provider_init(s.settings)
	call := s.provider_call
	if call == nil {
		call = provider_stream
	}

	capture: One_Shot_Capture
	defer one_shot_capture_destroy(&capture)
	perr := call(
		&provider,
		&request,
		Stream_Sink{user = &capture, on_event = one_shot_capture_event},
		cancel,
	)
	if perr.kind != .None {
		return result, make_error(.Provider, "title generation failed: %s", perr.message)
	}
	if capture.error.kind != .None {
		return result, make_error(.Provider, "title generation failed: %s", capture.error.message)
	}
	if !capture.seen_end {
		return result, make_error(.Provider, "title generation returned no message_end")
	}

	title := title_sanitize(one_shot_capture_text(&capture), context.allocator)
	if len(title) == 0 {
		return result, make_error(.Provider, "title generation returned no usable text")
	}

	var_usage: Maybe(Usage)
	if usage_has_any(capture.usage) {
		var_usage = capture.usage
	}
	header := make_header(&s.store, EVENT_SESSION_TITLE)
	event := Session_Title_Event {
		header = header,
		title  = title,
		usage  = var_usage,
	}
	line, aerr := transcript_append_line(&s.store, event)
	if !is_ok(aerr) {
		delete(title)
		return result, aerr
	}
	if emitter.on_transcript != nil {
		emitter.on_transcript(
			emitter.user,
			Event{v = header.v, seq = header.seq, ts = header.ts, type = header.type, line = line},
		)
	}

	result.title = title
	result.usage = capture.usage
	return result, ok_error()
}

// 模型偶尔会带上标签、引号或句号；统一清成侧栏能直接用的一行。
title_sanitize :: proc(raw: string, allocator: runtime.Allocator) -> string {
	line := title_first_line(raw)
	if len(line) == 0 {
		return ""
	}
	// 去掉「标题：」「Title:」这类前缀与行首的 markdown 标记。
	for {
		trimmed := strings.trim_left(line, " \t#>-*`")
		lowered := strings.to_lower(trimmed, allocator)
		cut := 0
		switch {
		case strings.has_prefix(lowered, "标题："), strings.has_prefix(lowered, "标题:"):
			cut = len("标题：") if strings.has_prefix(lowered, "标题：") else len("标题:")
		case strings.has_prefix(lowered, "title:"):
			cut = len("title:")
		case strings.has_prefix(lowered, "topic:"):
			cut = len("topic:")
		}
		if cut == 0 {
			line = trimmed
			break
		}
		line = strings.trim_left(trimmed[cut:], " \t")
	}
	line = strings.trim(line, "\"'`“”「」『』*_")
	line = strings.trim_right(line, "。．.!！?？;；:：,，、*_")
	line = title_collapse_spaces(line, allocator)
	line = title_truncate_runes(line, TITLE_MAX_RUNES)
	return strings.trim_space(line)
}

// 只要第一行非空内容：模型有时会在标题后面补解释。
title_first_line :: proc(raw: string) -> string {
	rest := raw
	for len(rest) > 0 {
		nl := strings.index_byte(rest, '\n')
		line := rest if nl < 0 else rest[:nl]
		trimmed := strings.trim_space(line)
		if len(trimmed) > 0 {
			return trimmed
		}
		if nl < 0 {
			break
		}
		rest = rest[nl + 1:]
	}
	return ""
}

title_collapse_spaces :: proc(text: string, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	previous_space := false
	for r in text {
		is_space := r == ' ' || r == '\t' || r == '\r' || r == '\n' || r == '\u3000'
		if is_space {
			if !previous_space {
				strings.write_byte(&b, ' ')
			}
			previous_space = true
			continue
		}
		previous_space = false
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}

// 按字符（不是字节）截断，避免把一个汉字或 emoji 劈成两半。
title_truncate_runes :: proc(text: string, limit: int) -> string {
	count := 0
	for _, index in text {
		if count == limit {
			return text[:index]
		}
		count += 1
	}
	return text
}
