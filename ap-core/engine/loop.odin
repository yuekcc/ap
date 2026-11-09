package engine

import "../platform"
import "../tool"

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:time"
import uuid "core:encoding/uuid"

MAX_LLM_RETRIES :: 5

// ---- 每 step 的临时分配区 ----
//
// context_build 按契约必须从完整 transcript 重新投影，所以每个 step 都会
// 产生一份新的 messages、arguments 字符串与请求体。它们的生命周期只有
// 一个 step，用 arena 一次性回收，避免长对话里 message 数量平方级增长。
Step_Arena :: struct {
	arena: virtual.Arena,
	alloc: runtime.Allocator,
}

step_arena_init :: proc(sa: ^Step_Arena) -> bool {
	if virtual.arena_init_growing(&sa.arena) != nil {
		return false
	}
	sa.alloc = virtual.arena_allocator(&sa.arena)
	return true
}

step_arena_destroy :: proc(sa: ^Step_Arena) {
	virtual.arena_destroy(&sa.arena)
	sa.alloc = {}
}

step_arena_allocator :: proc(sa: ^Step_Arena, enabled: bool) -> runtime.Allocator {
	if !enabled {
		return context.allocator
	}
	return sa.alloc
}

// 进度输出的排版提示：Block 是独立的 markdown 块（标题行、状态行），
// 输出端在块之间插入空行；Line 与上文同属一块，逐行追加。
Progress_Style :: tool.Progress_Kind

Emitter :: struct {
	user:              rawptr,
	on_transcript:     proc(user: rawptr, event: Event),
	on_text_delta:     proc(user: rawptr, message_id, text: string),
	on_reasoning_delta: proc(user: rawptr, message_id, text: string),
	on_tool_delta:     proc(user: rawptr, index: int, id, name, args_delta: string),
	on_tool_update:    proc(user: rawptr, tool_call_id, chunk: string),
	on_progress:       proc(user: rawptr, style: Progress_Style, line: string),
}

Loop_Result :: struct {
	stop_reason:  string,
	// 最终 assistant 文本的独立副本，归调用方所有（需要释放）。
	// 不能指向 Loop.last_text：loop 销毁后它就失效了。
	result_text:  string,
	num_steps:    int,
	usage:        Usage,
	session_usage: Usage,
	cancelled:    bool,
	error_kind:   Error_Kind,
	fatal_error:  string,
	// 交接成功时的正文与原因，归调用方所有（需要释放 content）。
	// 创建新 session 由 CLI adapter 负责，引擎只产文本。
	handoff_content: string,
	handoff_reason:  string,
	// 交接那次调用本身的用量。在没有主请求的预算耗尽路径上，它是本 turn
	// 唯一的真实用量。
	handoff_usage:   Usage,
}

Provider_Call :: #type proc(
	p: ^Provider,
	req: ^Chat_Message_Request,
	sink: Stream_Sink,
	cancel: ^platform.Cancel_Token,
) -> Provider_Error

Loop_Sleep_Fn :: #type proc(ms: int)

Loop :: struct {
	project:        Project,
	settings:       ^Settings,
	store:          ^Transcript_Store,
	provider:       Provider,
	provider_call:  Provider_Call,
	sleep_fn:       Loop_Sleep_Fn,
	registry:       tool.Registry,
	active_tools:   []string,
	model:          string,
	agent_name:     string,
	session_id:     string,
	agent_depth:    int,
	max_steps:      int,
	max_tokens:     int,
	cancel:         ^platform.Cancel_Token,
	emitter:        Emitter,
	events:         [dynamic]Event,
	// loop_init 复制进来的历史事件不属于 loop，销毁时不能释放它们的行。
	initial_event_count: int,
	historical_usage: Usage,
	turn_usage:     Usage,
	turn:           int,
	message_started: bool,
	current_message_id: string,
	current_tool_call_id: string,
	attempt_text:   [dynamic]byte,
	attempt_had_text: bool,
	pending_calls:  []Assembled_Tool_Call,
	pending_stop:   Stop_Reason,
	pending_end_seen: bool,
	last_text:      string,
	callback_error: Error,
	// ---- 上下文预算运行态 ----
	// 校准值只影响传入 context_build_budgeted 的 limit 与观测值，不进
	// transcript，因此不破坏投影的纯函数性。
	calibration_percent: int,
	last_request_estimate: int,
	last_observed_input: int,
	// 自动交接开关：--no-handoff 或 agent_depth > 0 时为 false。
	handoff_enabled: bool,
	// 本 turn 最后一次 step 的预算快照；预算关闭时保持 nil。
	turn_context: Maybe(Turn_Context),
	// provider 会把 message_id / tool call id/name 借给 loop 使用；assembler
	// 的临时缓冲在 provider_stream 返回时释放，所以 loop 需要自己持有副本。
	owned_message_id: string,
	owned_calls:      []Assembled_Tool_Call,
}

loop_default_sleep :: proc(ms: int) {
	time.sleep(time.Duration(ms) * time.Millisecond)
}

// turn_end 覆盖一轮的量；handoff 是独立的一次模型调用（manual handoff 没有
// turn），所以两者都要累加，否则 session_end.usage 会漏掉交接那一次。
historical_usage_from_events :: proc(events: []Event) -> Usage {
	total := Usage{}
	for ev in events {
		switch ev.type {
		case EVENT_TURN_END:
			end: Turn_End_Event
			if json.unmarshal_string(ev.line, &end) == nil {
				total = usage_add(total, end.usage)
			}
		case EVENT_HANDOFF:
			handoff: Handoff_Event
			if json.unmarshal_string(ev.line, &handoff) == nil {
				if usage, has_usage := handoff.usage.?; has_usage {
					total = usage_add(total, usage)
				}
			}
		}
	}
	return total
}

next_turn_from_events :: proc(events: []Event) -> int {
	max_turn := 0
	for ev in events {
		if ev.type != EVENT_TURN_START {
			continue
		}
		start: Turn_Start_Event
		if json.unmarshal_string(ev.line, &start) == nil && start.turn > max_turn {
			max_turn = start.turn
		}
	}
	return max_turn + 1
}

loop_init :: proc(
	project: Project,
	settings: ^Settings,
	store: ^Transcript_Store,
	registry: tool.Registry,
	active_tools: []string,
	model, agent_name, session_id: string,
	agent_depth, max_steps, max_tokens: int,
	cancel: ^platform.Cancel_Token,
	events: []Event,
	emitter: Emitter,
) -> Loop {
	loop := Loop {
		project = project,
		settings = settings,
		store = store,
		provider = provider_init(settings),
		provider_call = provider_stream,
		sleep_fn = loop_default_sleep,
		registry = registry,
		active_tools = active_tools,
		model = model,
		agent_name = agent_name,
		session_id = session_id,
		agent_depth = agent_depth,
		max_steps = max_steps,
		max_tokens = max_tokens,
		cancel = cancel,
		emitter = emitter,
		historical_usage = historical_usage_from_events(events),
		turn = next_turn_from_events(events),
		calibration_percent = 100,
		// 子代理的职责是回一个结论，不是开新 session。
		handoff_enabled = agent_depth == 0,
	}
	loop.events = make([dynamic]Event, len(events), len(events) + 16)
	copy(loop.events[:], events)
	loop.initial_event_count = len(events)
	loop.attempt_text = make([dynamic]byte, 0, 256)
	return loop
}

loop_destroy :: proc(l: ^Loop) {
	// l.events 的前 len(initial_events) 项由调用方（session.events）持有，
	// 只释放本 loop 追加的那部分行。type 永远是静态字面量，不释放。
	for i in l.initial_event_count ..< len(l.events) {
		delete(l.events[i].line)
	}
	delete(l.events)
	delete(l.attempt_text)
	delete(l.last_text)
	loop_release_owned(l)
}

loop_release_owned :: proc(l: ^Loop) {
	delete(l.owned_message_id)
	l.owned_message_id = ""
	for call in l.owned_calls {
		delete(call.id)
		delete(call.name)
	}
	delete(l.owned_calls)
	l.owned_calls = nil
}

loop_append :: proc(l: ^Loop, event: any, header: Event_Header) -> Error {
	line, werr := transcript_append_line(l.store, event)
	if !is_ok(werr) {
		return werr
	}
	ev := Event {
		v = header.v,
		seq = header.seq,
		ts = header.ts,
		type = header.type,
		line = line,
	}
	append(&l.events, ev)
	if l.emitter.on_transcript != nil {
		l.emitter.on_transcript(l.emitter.user, ev)
	}
	return ok_error()
}

progress :: proc(l: ^Loop, style: Progress_Style, format: string, args: ..any) {
	if l.emitter.on_progress != nil {
		l.emitter.on_progress(l.emitter.user, style, fmt.tprintf(format, ..args))
	}
}

loop_start_message :: proc(l: ^Loop, model: string) -> Error {
	if l.message_started {
		return ok_error()
	}
	id := l.current_message_id
	if len(id) == 0 {
		generated := uuid.generate_v4()
		id = uuid.to_string(generated, context.allocator)
		l.current_message_id = id
	}
	message_model := model
	if len(message_model) == 0 {
		message_model = l.model
	}
	h := make_header(l.store, EVENT_MESSAGE_START)
	ev := Message_Start_Event {
		header = h,
		message_id = id,
		role = ROLE_ASSISTANT,
		model = message_model,
	}
	if err := loop_append(l, ev, h); !is_ok(err) {
		return err
	}
	l.message_started = true
	return ok_error()
}

// 大于阈值的内容写入 blob，失败时调用方决定是保留原文还是报错。
make_text_block :: proc(l: ^Loop, text: string) -> (Content_Block, Error) {
	block := Content_Block{type = BLOCK_TEXT, text = text}
	if len(text) <= l.settings.blob_threshold_bytes {
		return block, ok_error()
	}
	fields, berr := maybe_blob(l.store, transmute([]byte)text)
	if !is_ok(berr) {
		return block, berr
	}
	block.text = nil
	block.text_ref = fields.ref
	block.text_bytes = fields.bytes
	block.text_preview = fields.preview
	return block, ok_error()
}

loop_write_message_end :: proc(l: ^Loop, end: Provider_Message_End) -> Error {
	if err := loop_start_message(l, ""); !is_ok(err) {
		return err
	}
	blocks := make([dynamic]Content_Block, 0, 2)
	if len(end.text) > 0 {
		block, berr := make_text_block(l, end.text)
		if !is_ok(berr) {
			return berr
		}
		append(&blocks, block)
	}
	for call in end.tool_calls {
		block := Content_Block{type = BLOCK_TOOL_USE, id = call.id, name = call.name}
		args_text := platform.json_arguments_string(call.input)
		if len(args_text) > l.settings.blob_threshold_bytes {
			fields, berr := maybe_blob(l.store, transmute([]byte)args_text)
			if !is_ok(berr) {
				return berr
			}
			block.input = nil
			block.input_ref = fields.ref
			block.input_bytes = fields.bytes
			block.input_preview = fields.preview
		} else {
			block.input = call.input
		}
		append(&blocks, block)
	}

	var_usage: Maybe(Usage)
	if usage_has_any(end.usage) {
		var_usage = end.usage
		l.turn_usage = usage_add(l.turn_usage, end.usage)
		// 这一次请求的真实输入长度。transcript 只追加，所以它就是下一步
		// messages 的前缀长度，可以直接拿来校准下一次估算。
		if observed, has_observed := end.usage.input_tokens.?; has_observed {
			l.last_observed_input = observed
		}
	}
	var_reasoning: Maybe(string)
	if len(end.reasoning) > 0 {
		var_reasoning = end.reasoning
	}
	h := make_header(l.store, EVENT_MESSAGE_END)
	ev := Message_End_Event {
		header = h,
		message_id = l.current_message_id,
		role = ROLE_ASSISTANT,
		content = blocks[:],
		stop_reason = stop_reason_string(end.stop_reason),
		usage = var_usage,
		reasoning = var_reasoning,
	}
	if err := loop_append(l, ev, h); !is_ok(err) {
		return err
	}
	if len(end.text) > 0 {
		// 每步都会走到这里；先释放上一步的副本，否则一个 turn 里每次覆盖都漏一份。
		delete(l.last_text)
		l.last_text = strings.clone(end.text)
	}
	l.message_started = false
	l.current_message_id = ""
	return ok_error()
}

loop_provider_event :: proc(user: rawptr, event: Provider_Event) {
	l := (^Loop)(user)
	switch ev in event {
	case Provider_Message_Start:
		if len(ev.message_id) > 0 {
			delete(l.owned_message_id)
			l.owned_message_id = strings.clone(ev.message_id)
			l.current_message_id = l.owned_message_id
		}
		if err := loop_start_message(l, ev.model); !is_ok(err) {
			l.callback_error = err
		}
	case Provider_Text_Delta:
		if err := loop_start_message(l, ""); !is_ok(err) {
			l.callback_error = err
			return
		}
		l.attempt_had_text = true
		append(&l.attempt_text, ..transmute([]byte)ev.text)
		if l.emitter.on_text_delta != nil {
			l.emitter.on_text_delta(l.emitter.user, l.current_message_id, ev.text)
		}
	case Provider_Reasoning_Delta:
		if l.emitter.on_reasoning_delta != nil {
			l.emitter.on_reasoning_delta(l.emitter.user, l.current_message_id, ev.text)
		}
	case Provider_Tool_Start:
		if l.emitter.on_tool_delta != nil {
			l.emitter.on_tool_delta(l.emitter.user, ev.index, ev.id, ev.name, "")
		}
	case Provider_Tool_Delta:
		if l.emitter.on_tool_delta != nil {
			l.emitter.on_tool_delta(l.emitter.user, ev.index, "", "", ev.args_delta)
		}
	case Provider_Tool_End:
	case Provider_Message_End:
		loop_own_calls(l, ev.tool_calls)
		l.pending_calls = l.owned_calls
		l.pending_stop = ev.stop_reason
		l.pending_end_seen = true
		if err := loop_write_message_end(l, ev); !is_ok(err) {
			l.callback_error = err
		}
	case Provider_Error_Event:
	}
}

loop_write_error :: proc(
	l: ^Loop,
	scope: string,
	kind: Provider_Error_Kind,
	message: string,
	retryable: bool,
	attempt: int,
) -> Error {
	var_kind: Maybe(string)
	kind_name := provider_error_kind_string(kind)
	if len(kind_name) > 0 {
		var_kind = kind_name
	}
	h := make_header(l.store, EVENT_ERROR)
	ev := Error_Event {
		header = h,
		scope = scope,
		kind = var_kind,
		message = message,
		retryable = retryable,
		attempt = attempt,
	}
	return loop_append(l, ev, h)
}

loop_write_cancel :: proc(l: ^Loop, scope: string, target: string) -> Error {
	var_target: Maybe(string)
	if len(target) > 0 {
		var_target = target
	}
	h := make_header(l.store, EVENT_CANCEL)
	ev := Cancel_Event {
		header = h,
		scope = scope,
		target_id = var_target,
	}
	return loop_append(l, ev, h)
}

loop_write_turn_end :: proc(l: ^Loop, stop_reason: string) -> Error {
	h := make_header(l.store, EVENT_TURN_END)
	ev := Turn_End_Event {
		header = h,
		turn = l.turn - 1,
		stop_reason = stop_reason,
		usage = l.turn_usage,
		context_info = l.turn_context,
	}
	return loop_append(l, ev, h)
}

loop_write_cancelled_message :: proc(l: ^Loop) {
	if !l.message_started {
		return
	}
	blocks := make([dynamic]Content_Block, 0, 1)
	if len(l.attempt_text) > 0 {
		block, _ := make_text_block(l, string(l.attempt_text[:]))
		append(&blocks, block)
	}
	h := make_header(l.store, EVENT_MESSAGE_END)
	ev := Message_End_Event {
		header = h,
		message_id = l.current_message_id,
		role = ROLE_ASSISTANT,
		content = blocks[:],
		stop_reason = STOP_REASON_CANCELLED,
		usage = nil,
		reasoning = nil,
	}
	_ = loop_append(l, ev, h)
	l.message_started = false
}

loop_tool_update :: proc(user: rawptr, chunk: string) {
	l := (^Loop)(user)
	if l.emitter.on_tool_update != nil {
		l.emitter.on_tool_update(l.emitter.user, l.current_tool_call_id, chunk)
	}
}

loop_execute_tools :: proc(l: ^Loop) -> (cancelled: bool, err: Error, error_kind: Error_Kind) {
	for call in l.pending_calls {
		if platform.cancel_token_cancelled(l.cancel) {
			_ = loop_write_cancel(l, SCOPE_STEP, l.current_tool_call_id)
			_ = loop_write_turn_end(l, STOP_REASON_CANCELLED)
			return true, ok_error(), .None
		}

		l.current_tool_call_id = call.id
		args_text := platform.json_arguments_string(call.input)
		start_ev := Tool_Execution_Start_Event {
			tool_call_id = call.id,
			name = call.name,
		}
		if len(args_text) > l.settings.blob_threshold_bytes {
			args_bytes: []byte = transmute([]byte)args_text
			sha, berr := blob_write(l.project, args_bytes)
			if !is_ok(berr) {
				_ = loop_write_error(l, SCOPE_SESSION, .None, berr.message, false, 1)
				return false, berr, .Tool
			}
			start_ev.args = nil
			start_ev.args_ref = sha
			start_ev.args_bytes = len(args_bytes)
			start_ev.args_preview = platform.utf8_prefix(args_bytes, PREVIEW_BYTES)
		} else {
			start_ev.args = call.input
		}
		h := make_header(l.store, EVENT_TOOL_EXECUTION_START)
		start_ev.header = h
		if aerr := loop_append(l, start_ev, h); !is_ok(aerr) {
			return false, aerr, .Internal
		}
		progress(l, .Block, "### %s", call.name)

		tool_ctx := tool.Tool_Context {
			cwd = l.project.root,
			project = l.project,
			cancel = l.cancel,
			session_id = l.session_id,
			tool_call_id = call.id,
			agent_name = l.agent_name,
			agent_depth = l.agent_depth,
			on_update = loop_tool_update,
			update_user = l,
			on_progress = l.emitter.on_progress,
			progress_user = l.emitter.user,
		}
		res := tool.tool_execute(&l.registry, call.name, call.input, &tool_ctx)

		was_cancelled := platform.cancel_token_cancelled(l.cancel) || (!res.ok && res.error == TOOL_ERROR_CANCELLED)
		if was_cancelled {
			_ = loop_write_cancel(l, SCOPE_STEP, call.id)
			res.ok = false
			res.error = TOOL_ERROR_CANCELLED
			res.content = ""
		}

		end_ev := Tool_Execution_End_Event {
			tool_call_id = call.id,
			ok = res.ok,
			duration_ms = res.duration_ms,
			exit_code = res.exit_code,
			metadata = res.metadata,
		}
		if res.ok {
			if len(res.content) > l.settings.blob_threshold_bytes {
				content_bytes: []byte = transmute([]byte)res.content
				sha, berr := blob_write(l.project, content_bytes)
				if !is_ok(berr) {
					end_ev.ok = false
					end_ev.error = "failed to persist output blob"
					end_ev.content = nil
				} else {
					end_ev.content = nil
					end_ev.content_ref = sha
					end_ev.content_bytes = len(content_bytes)
					end_ev.content_preview = platform.utf8_prefix(content_bytes, PREVIEW_BYTES)
				}
			} else {
				end_ev.content = res.content
			}
		} else {
			end_ev.content = nil
			end_ev.error = res.error
		}
		h2 := make_header(l.store, EVENT_TOOL_EXECUTION_END)
		end_ev.header = h2
		if aerr := loop_append(l, end_ev, h2); !is_ok(aerr) {
			return false, aerr, .Internal
		}
		progress(l, .Block, "_%s %s (%dms)_", call.name, "ok" if end_ev.ok else "failed", res.duration_ms)
		if was_cancelled {
			_ = loop_write_turn_end(l, STOP_REASON_CANCELLED)
			return true, ok_error(), .None
		}
		if res.fatal {
			_ = loop_write_error(l, SCOPE_TOOL, .None, res.error, false, 1)
			return false, make_error(.Tool, "%s", res.error), .Tool
		}
	}
	return false, ok_error(), .None
}

loop_reset_attempt :: proc(l: ^Loop) {
	l.message_started = false
	l.current_message_id = ""
	l.current_tool_call_id = ""
	l.attempt_had_text = false
	clear(&l.attempt_text)
	loop_release_owned(l)
	l.pending_calls = nil
	l.pending_stop = .Stop
	l.pending_end_seen = false
	l.callback_error = ok_error()
}

loop_run_turn :: proc(l: ^Loop, prompt: string) -> (result: Loop_Result) {
	result.error_kind = .None
	l.turn_usage = Usage{}
	// 上一轮的结果文本已随 Loop_Result 交给调用方（独立副本），这里释放 loop 内的。
	delete(l.last_text)
	l.last_text = ""

	h_user := make_header(l.store, EVENT_USER_MESSAGE)
	if err := loop_append(l, User_Message_Event{header = h_user, content = prompt}, h_user); !is_ok(err) {
		result.error_kind = .Internal
		result.fatal_error = err.message
		return result
	}
	// 校准值属于本次 turn 的运行态：新 turn 的第一份 messages 与上一 turn 的
	// 请求前缀关系已经变（多了一条 user_message），沿用旧观测会偏。
	l.last_request_estimate = 0
	l.last_observed_input = 0
	turn := l.turn
	l.turn += 1
	h_turn := make_header(l.store, EVENT_TURN_START)
	if err := loop_append(l, Turn_Start_Event{header = h_turn, turn = turn}, h_turn); !is_ok(err) {
		result.error_kind = .Internal
		result.fatal_error = err.message
		return result
	}

	step := 0
	for {
		if platform.cancel_token_cancelled(l.cancel) {
			_ = loop_write_cancel(l, SCOPE_TURN, "")
			loop_write_cancelled_message(l)
			_ = loop_write_turn_end(l, STOP_REASON_CANCELLED)
			result.cancelled = true
			result.stop_reason = STOP_REASON_CANCELLED
			result.num_steps = step
			result.session_usage = usage_add(l.historical_usage, l.turn_usage)
			return result
		}
		if step >= l.max_steps {
			_ = loop_write_turn_end(l, STOP_REASON_MAX_STEPS)
			result.stop_reason = STOP_REASON_MAX_STEPS
			result.result_text = strings.clone(l.last_text)
			result.num_steps = step
			result.usage = l.turn_usage
			result.session_usage = usage_add(l.historical_usage, l.turn_usage)
			return result
		}
		step += 1
		h_step := make_header(l.store, EVENT_STEP_START)
		if err := loop_append(l, Step_Start_Event{header = h_step, step = step}, h_step); !is_ok(err) {
			result.error_kind = .Internal
			result.fatal_error = err.message
			result.num_steps = step
			return result
		}
		progress(l, .Block, "## Step %d", step)

		// 一个 step 的上下文、工具定义与请求体只活到本 step 结束。
		// 用 arena 统一回收：长对话里这些中间量随 message 数线性增长，
		// 每 step 都不释放会让进程内存在 turn 内平方级上涨。
		step_arena: Step_Arena
		arena_ok := step_arena_init(&step_arena)
		defer if arena_ok {
			step_arena_destroy(&step_arena)
		}

		alloc := step_arena_allocator(&step_arena, arena_ok)
		tools, terr := tool.registry_definitions_in(&l.registry, l.active_tools, alloc)
		if !platform.is_ok(terr) {
			_ = loop_write_error(l, SCOPE_SESSION, .None, terr.message, false, 1)
			result.error_kind = .Internal
			result.fatal_error = terr.message
			result.num_steps = step
			return result
		}
		// 每个 step 计算一次预算决策：先看不省略的投影，超阈值才省略，
		// 省略后仍超阈值就交接。context_window_tokens = 0 时整段退化。
		target := context_budget_target(l.settings, l.max_tokens)
		if context_budget_invalid(l.settings, target) {
			message := fmt.tprintf(
				"context budget is invalid: context_window_tokens (%d) - max_tokens (%d) - reserve (%d) <= 0",
				l.settings.context_window_tokens,
				l.max_tokens,
				DEFAULT_CONTEXT_RESERVE_TOKENS,
			)
			_ = loop_write_error(l, SCOPE_SESSION, .None, message, false, 1)
			result.error_kind = .Usage
			result.fatal_error = message
			result.num_steps = step
			return result
		}
		calibration := calibration_percent_from(l.last_request_estimate, l.last_observed_input)
		l.calibration_percent = calibration
		context_in, cerr := context_build_budgeted(
			l.project,
			l.events[:],
			estimate_tool_defs_tokens(tools),
			target,
			calibration,
			alloc,
		)
		if !is_ok(cerr) {
			_ = loop_write_error(l, SCOPE_SESSION, .None, cerr.message, false, 1)
			result.error_kind = .Usage
			result.fatal_error = cerr.message
			result.num_steps = step
			return result
		}
		loop_record_context(l, context_in, target)
		if context_in.elided_results > 0 {
			progress(
				l,
				.Line,
				"[context] elided %d tool results, ~%d tokens saved",
				context_in.elided_results,
				context_in.tokens_saved,
			)
		}
		if target > 0 &&
		   context_in.estimated_tokens * 100 >= target * HANDOFF_TRIGGER_PERCENT {
			if !l.handoff_enabled {
				return loop_context_exhausted(l, result, step)
			}
			return loop_handoff_turn(l, result, step, HANDOFF_REASON_BUDGET_EXHAUSTED)
		}
		all_messages := make([dynamic]Chat_Message, 0, len(context_in.messages) + 1, alloc)
		append(&all_messages, Chat_Message{role = ROLE_SYSTEM, content = context_in.system_prompt})
		append(&all_messages, ..context_in.messages)
		req := Chat_Message_Request {
			model = l.model,
			messages = all_messages[:],
			tools = tools,
			max_tokens = l.max_tokens,
			include_usage = l.settings.stream_include_usage,
		}
		sink := Stream_Sink{user = l, on_event = loop_provider_event}
		l.last_request_estimate = request_raw_estimate(context_in)

		attempt := 1
		success := false
		cancelled := false
		context_too_long := false
		tightened := false
		var_final_error: Provider_Error
		for {
			loop_reset_attempt(l)
			perr := l.provider_call(&l.provider, &req, sink, l.cancel)
			if !is_ok(l.callback_error) {
				err := l.callback_error
				_ = loop_write_error(l, SCOPE_SESSION, .None, err.message, false, attempt)
				result.error_kind = .Tool if err.kind == .Tool else .Internal
				result.fatal_error = err.message
				result.num_steps = step
				return result
			}
			if perr.kind == .None {
				if !l.pending_end_seen {
					perr = {kind = .Protocol, message = "provider returned no message_end", retryable = false}
				} else {
					success = true
					break
				}
			}
			if perr.kind == .Cancelled || platform.cancel_token_cancelled(l.cancel) {
				cancelled = true
				break
			}
			if perr.kind == .Context_Too_Long {
				// 估算失误不该直接放弃：第一次收到超限时收紧预算重发同一 step，
				// 不写 error、不增加 step、不写 turn_end。第二次才进入交接。
				if target > 0 && l.handoff_enabled && !tightened {
					tightened = true
					if tightened_request(l, context_in, alloc, target, &req) {
						progress(
							l,
							.Line,
							"[context] provider rejected request as too long; recomputing with tighter budget",
						)
						continue
					}
				}
				context_too_long = true
				break
			}

			_ = loop_write_error(l, SCOPE_LLM, perr.kind, perr.message, perr.retryable, attempt)
			if perr.retryable && attempt <= MAX_LLM_RETRIES {
				delay := 1000 * (1 << uint(attempt - 1))
				if delay > 16000 {
					delay = 16000
				}
				if retry_ms, ok := perr.retry_after_ms.?; ok && retry_ms > 0 {
					delay = retry_ms
				} else {
					// 指数退避加一点抖动，避免多实例同时重试。
					delay += int(time.time_to_unix_nano(time.now()) % 251)
				}
				progress(l, .Line, "[retry] %s (attempt %d, %dms)", perr.message, attempt, delay)
				if l.attempt_had_text {
					progress(l, .Line, "[retry] 上一次尝试已展示的文本作废")
				}
				l.sleep_fn(delay)
				attempt += 1
				continue
			}
			var_final_error = perr
			break
		}

		if cancelled {
			_ = loop_write_cancel(l, SCOPE_STEP, l.current_message_id)
			loop_write_cancelled_message(l)
			_ = loop_write_turn_end(l, STOP_REASON_CANCELLED)
			result.cancelled = true
			result.stop_reason = STOP_REASON_CANCELLED
			result.num_steps = step
			result.session_usage = usage_add(l.historical_usage, l.turn_usage)
			return result
		}
		if context_too_long {
			// 允许交接时，先强制重算一次并换一份更紧的投影，仍不够就交接。
			if target > 0 && l.handoff_enabled {
				return loop_handoff_turn(l, result, step, HANDOFF_REASON_CONTEXT_TOO_LONG)
			}
			return loop_context_exhausted(l, result, step)
		}
		if !success {
			result.error_kind = .Provider
			result.fatal_error = var_final_error.message
			result.num_steps = step
			result.session_usage = usage_add(l.historical_usage, l.turn_usage)
			return result
		}

		l.current_message_id = ""
		l.current_tool_call_id = ""
		if l.pending_stop == .Tool_Use {
			cancelled_tools, terr2, tool_error_kind := loop_execute_tools(l)
			if cancelled_tools {
				result.cancelled = true
				result.stop_reason = STOP_REASON_CANCELLED
				result.num_steps = step
				result.session_usage = usage_add(l.historical_usage, l.turn_usage)
				return result
			}
			if !is_ok(terr2) {
				result.error_kind = tool_error_kind
				result.fatal_error = terr2.message
				result.num_steps = step
				result.session_usage = usage_add(l.historical_usage, l.turn_usage)
				return result
			}
			continue
		}

		stop_reason := stop_reason_string(l.pending_stop)
		_ = loop_write_turn_end(l, stop_reason)
		result.stop_reason = stop_reason
		result.result_text = strings.clone(l.last_text)
		result.num_steps = step
		result.usage = l.turn_usage
		result.session_usage = usage_add(l.historical_usage, l.turn_usage)
		return result
	}
}

// 把本次 message_end 的 tool call 元数据拷进 loop 自己的所有权。
// json.Value 参数本身由 provider 在事件期间持有，执行阶段仍可用；
// id / name 需要单独持有，因为 provider 的缓冲随后就释放。
loop_own_calls :: proc(l: ^Loop, calls: []Assembled_Tool_Call) {
	loop_release_owned(l)
	if len(calls) == 0 {
		return
	}
	owned := make([]Assembled_Tool_Call, len(calls))
	for call, i in calls {
		owned[i] = {
			id    = strings.clone(call.id),
			name  = strings.clone(call.name),
			input = call.input,
		}
	}
	l.owned_calls = owned
}

// ---- 上下文预算的 step 辅助 ----

// 记录本 turn 最后一次 step 的预算快照；预算关闭时保持 null。
loop_record_context :: proc(l: ^Loop, context_in: Budgeted_Context, target: int) {
	if target <= 0 {
		l.turn_context = nil
		return
	}
	l.turn_context = Turn_Context {
		estimated_tokens    = context_in.estimated_tokens,
		limit_tokens        = target,
		elided_results      = context_in.elided_results,
		elided_bytes        = context_in.elided_bytes,
		calibration_percent = context_in.calibration_percent,
	}
}

// 实际发出的这一份请求的原始估算，作为下一次 usage 校准的分母。
request_raw_estimate :: proc(context_in: Budgeted_Context) -> int {
	return estimate_request_tokens(
		context_in.system_prompt,
		context_in.messages,
		context_in.tools_tokens,
	)
}

// 收紧预算重发同一 step：把水位压到目标的 80% 再减半，并重新省略。
// 只有投影层会变，transcript 不动，也没有新增事件。
tightened_request :: proc(
	l: ^Loop,
	context_in: Budgeted_Context,
	allocator: runtime.Allocator,
	target: int,
	req: ^Chat_Message_Request,
) -> bool {
	tighter := target * CONTEXT_ELIDE_TARGET_PERCENT / 100 / 2
	if tighter <= 0 {
		return false
	}
	rebuilt, cerr := context_build_budgeted(
		l.project,
		l.events[:],
		context_in.tools_tokens,
		tighter,
		context_in.calibration_percent,
		allocator,
	)
	if !is_ok(cerr) {
		return false
	}
	merged := make([dynamic]Chat_Message, 0, len(rebuilt.messages) + 1, allocator)
	append(&merged, Chat_Message{role = ROLE_SYSTEM, content = rebuilt.system_prompt})
	append(&merged, ..rebuilt.messages)
	req.messages = merged[:]
	l.last_request_estimate = request_raw_estimate(rebuilt)
	loop_record_context(l, rebuilt, target)
	return true
}

// 不允许交接时的现状出口：写 error、写 turn_end、按 provider 错误返回。
loop_context_exhausted :: proc(l: ^Loop, result: Loop_Result, step: int) -> Loop_Result {
	out := result
	_ = loop_write_error(
		l,
		SCOPE_LLM,
		.Context_Too_Long,
		"context too long; start a new session or reduce input",
		false,
		1,
	)
	_ = loop_write_turn_end(l, STOP_REASON_CONTEXT_TOO_LONG)
	out.error_kind = .Provider
	out.fatal_error = "context_too_long"
	out.stop_reason = STOP_REASON_CONTEXT_TOO_LONG
	out.result_text = strings.clone(l.last_text)
	out.num_steps = step
	out.session_usage = usage_add(l.historical_usage, l.turn_usage)
	return out
}

// 交接请求的 system 前缀是本次 session 冻结的 prompt 的独立副本，
// 由 loop_handoff_turn 释放。
handoff_frozen_prompt :: proc(project: Project, events: []Event) -> (string, Error) {
	_, prompt, err := session_system_prompt(project, events)
	if !is_ok(err) {
		return "", err
	}
	return strings.clone(prompt), ok_error()
}

// 生成交接文档并结束本次 turn。失败时退回 loop_context_exhausted 的路径。
loop_handoff_turn :: proc(l: ^Loop, result: Loop_Result, step: int, reason: string) -> Loop_Result {
	out := result
	frozen_prompt, serr := handoff_frozen_prompt(l.project, l.events[:])
	if !is_ok(serr) {
		return loop_context_exhausted(l, result, step)
	}
	defer delete(frozen_prompt)
	handoff, written, herr := handoff_run(
		{
			project = l.project,
			store = l.store,
			settings = l.settings,
			provider = &l.provider,
			provider_call = l.provider_call,
			model = l.model,
			frozen_system_prompt = frozen_prompt,
			events = l.events[:],
			// 自动交接没有聚焦提示词：那个入口只有 --handoff，走的是 session_handoff。
			focus_prompt = "",
			reason = reason,
			cancel = l.cancel,
			on_transcript = l.emitter.on_transcript,
			user = l.emitter.user,
		},
		context.allocator,
	)
	if herr.kind != .None {
		_ = loop_write_error(l, SCOPE_LLM, herr.kind, fmt.tprintf("handoff failed: %s", herr.message), false, 1)
		return loop_context_exhausted(l, result, step)
	}
	// 事件行归 loop.events 所有，随 loop_destroy 释放。
	append(&l.events, written)
	_ = loop_write_turn_end(l, STOP_REASON_HANDOFF)
	out.stop_reason = STOP_REASON_HANDOFF
	out.handoff_content = handoff.content
	out.handoff_reason = reason
	out.handoff_usage = handoff.usage
	out.result_text = strings.clone(l.last_text)
	out.num_steps = step
	out.usage = l.turn_usage
	out.session_usage = usage_add(l.historical_usage, l.turn_usage)
	return out
}
