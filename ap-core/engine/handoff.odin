package engine

import "../platform"

import "base:runtime"
import "core:strings"

// handoff：上下文真的不够用时，用一次不带工具的模型调用生成交接文档。
//
// 引擎只负责产交接文本并写 handoff 事件；创建新 session、决定退出码属于
// CLI adapter。原始 message_end、tool_execution_end、user_message 一律不动，
// handoff 只追加。见 docs/context-management.md。

// Handoff_Result 归调用方所有：content 需要 delete。
Handoff_Result :: struct {
	reason:  string,
	content: string,
	usage:   Usage,
}

handoff_result_destroy :: proc(result: ^Handoff_Result) {
	delete(result.content)
	result.content = ""
}

// 一次交接调用的输入。全部是已解析值，不读 argv、不读时钟。
Handoff_Request :: struct {
	project:              Project,
	store:                ^Transcript_Store,
	settings:             ^Settings,
	provider:             ^Provider,
	provider_call:        Provider_Call,
	model:                string,
	frozen_system_prompt: string,
	events:               []Event,
	// --handoff "<prompt>" 的聚焦提示词；同时是新 session 的第一个 turn。
	focus_prompt:         string,
	reason:               string,
	cancel:               ^platform.Cancel_Token,
	// 新写出的事件交给调用方转发给 emitter 并决定是否持有 line。
	on_transcript:        proc(user: rawptr, event: Event),
	user:                 rawptr,
}

// handoff_request_messages 组装交接请求的 messages：省略后的投影，加上可选的
// 聚焦提示词。system 消息由调用方拼上 handoff.md，不在这里。
handoff_request_messages :: proc(
	context_in: Budgeted_Context,
	focus_prompt: string,
	allocator: runtime.Allocator,
) -> []Chat_Message {
	messages := make([dynamic]Chat_Message, 0, len(context_in.messages) + 1, allocator)
	append(&messages, ..context_in.messages)
	if len(focus_prompt) > 0 {
		append(&messages, Chat_Message{role = ROLE_USER, content = focus_prompt})
	}
	return messages[:]
}

// handoff_run 跑一次交接调用并写 handoff 事件。
//
// 只尝试一次，不重试：交接是尽力而为的产物，失败时由调用方按现有路径结束。
// 写入顺序遵循 blob 先写后引用。
handoff_run :: proc(
	req: Handoff_Request,
	allocator: runtime.Allocator,
) -> (
	Handoff_Result,
	Event,
	Provider_Error,
) {
	// 投影、拼接好的 messages 与请求体只活到这次调用结束。
	scratch: Step_Arena
	scratch_ok := step_arena_init(&scratch)
	defer if scratch_ok {
		step_arena_destroy(&scratch)
	}
	work := step_arena_allocator(&scratch, scratch_ok)
	result := Handoff_Result{reason = req.reason}

	// 交接调用自己也要装得下：system 消息、投影与输出上限共用同一个窗口。
	limit := handoff_budget_target(req.settings)
	context_in, cerr := context_build_budgeted(
		req.project,
		req.events,
		0,
		limit,
		100,
		work,
	)
	if !is_ok(cerr) {
		return result, {}, {kind = .Internal, message = cerr.message}
	}

	handoff_prompt := handoff_system_prompt(req.frozen_system_prompt, work)
	all_messages := make([dynamic]Chat_Message, 0, len(context_in.messages) + 2, work)
	append(&all_messages, Chat_Message{role = ROLE_SYSTEM, content = handoff_prompt})
	append(&all_messages, ..handoff_request_messages(context_in, req.focus_prompt, work))
	request := Chat_Message_Request {
		model         = req.model,
		messages      = all_messages[:],
		// 交接调用不带工具：它只产文本；输出上限取 handoff_max_tokens，
		// 与 --max-tokens 无关。
		tools         = nil,
		max_tokens    = req.settings.handoff_max_tokens,
		include_usage = req.settings.stream_include_usage,
	}

	capture: One_Shot_Capture
	defer one_shot_capture_destroy(&capture)
	perr := req.provider_call(
		req.provider,
		&request,
		Stream_Sink{user = &capture, on_event = one_shot_capture_event},
		req.cancel,
	)
	if perr.kind != .None {
		return result, {}, perr
	}
	if capture.error.kind != .None {
		return result, {}, capture.error
	}
	if !capture.seen_end {
		return result, {}, {kind = .Protocol, message = "handoff returned no message_end", retryable = false}
	}

	text := one_shot_capture_text(&capture)
	if len(text) == 0 {
		return result, {}, {kind = .Protocol, message = "handoff returned no text", retryable = false}
	}

	var_ref: Maybe(string)
	var_bytes: Maybe(int)
	var_preview: Maybe(string)
	stored := text
	content_bytes := len(text)
	if content_bytes > req.settings.blob_threshold_bytes {
		sha, berr := blob_write(req.project, transmute([]byte)text)
		if !is_ok(berr) {
			return result, {}, {kind = .Internal, message = berr.message}
		}
		stored = ""
		var_ref = sha
		var_bytes = content_bytes
		var_preview = platform.utf8_prefix(transmute([]byte)text, PREVIEW_BYTES)
	}

	var_usage: Maybe(Usage)
	if usage_has_any(capture.usage) {
		var_usage = capture.usage
	}
	header := make_header(req.store, EVENT_HANDOFF)
	event := Handoff_Event {
		header          = header,
		reason          = req.reason,
		content         = stored,
		content_ref     = var_ref,
		content_bytes   = var_bytes,
		content_preview = var_preview,
		usage           = var_usage,
		source_events   = len(req.events),
	}
	line, aerr := transcript_append_line(req.store, event)
	if !is_ok(aerr) {
		return result, {}, {kind = .Internal, message = aerr.message}
	}
	written := Event {
		v    = header.v,
		seq  = header.seq,
		ts   = header.ts,
		type = header.type,
		line = line,
	}
	if req.on_transcript != nil {
		req.on_transcript(req.user, written)
	}

	result.content = strings.clone(text, allocator)
	result.usage = capture.usage
	return result, written, provider_error_none()
}

// 把 handoff 事件里存的正文取出来；恢复后的 manual 交接与前端富化都用它。
handoff_event_content :: proc(
	project: Project,
	event: Handoff_Event,
	allocator: runtime.Allocator,
) -> (string, Error) {
	if ref, has_ref := event.content_ref.?; has_ref {
		data, berr := blob_read(project, ref, allocator)
		if !is_ok(berr) {
			return "", berr
		}
		return string(data), ok_error()
	}
	return event.content, ok_error()
}
