package engine

import "../platform"
import "../tool"

import "core:encoding/uuid"
import "core:fmt"
import "core:os"

// ---- 会话生命周期 ----
// session_open 负责新会话/恢复/fork 的解析与 session_start 写入；
// turn_run 只跑一轮；session_close 重算 usage 并写 session_end。
// CLI 的退出码、输出格式、信号处理都不在这里。

Session_Kind :: enum {
	New,
	Resume,
	Fork,
}

// Session_Request 全部是已解析值：SDK 不读 agent 文件、技能目录或记忆文件。
Session_Request :: struct {
	kind:              Session_Kind,
	project:           platform.Project,
	settings:          ^Settings,
	registry:          tool.Registry,
	source_session_id: string, // Resume 且为空时取最近的根 session

	// prompt / tools / agent_name / model 只在新 session 生效；恢复 / fork 使用冻结值。
	// max_steps / max_tokens 不在 session_start 中冻结，恢复时仍取本次设置。
	agent_name:          string, // 仅作标签，不触发文件读取
	model:               string, // 空 = 用 Settings.model
	max_steps:           int,    // 0 = 用 Settings.max_steps
	max_tokens:          int,    // 0 = 用 Settings.max_tokens
	agent_depth:         int,
	// false 关闭自动交接（--no-handoff）。agent_depth > 0 时引擎自己也会关掉。
	auto_handoff:        bool,
	parent_session_id:   Maybe(string),
	parent_tool_call_id: Maybe(string),

	base_system_prompt: Maybe(string), // 空 = 用 SDK 内置 base
	prompt_sections:    []string,      // 按顺序 append；空串跳过
	tools:              []string,      // 生效工具集；空切片 = 零工具，不能省略
}

Session_Info :: struct {
	session_id:    string,
	model:         string,
	agent_name:    string,
	agent_depth:   int,
	system_prompt: string,
	initial_line:  string, // stream-json 首行
	warnings:      []string,
}

Session :: struct {
	project:      platform.Project,
	settings:     ^Settings,
	store:        Transcript_Store,
	registry:     tool.Registry,
	active_tools: []string,
	model:        string,
	agent_name:   string,
	session_id:   string,
	agent_depth:  int,
	max_steps:    int,
	max_tokens:   int,
	auto_handoff: bool,
	events:       []Event,
	// nil 表示走 provider_stream。测试用它换成假 provider，避免真实 HTTP。
	provider_call: Provider_Call,
}

Close_Options :: struct {
	cancelled: bool,
	reason:    string,
	usage:     Usage,
}

Turn_Result :: Loop_Result

Resolved_Session :: struct {
	model:         string,
	agent_name:    string,
	agent_depth:   int,
	max_steps:     int,
	max_tokens:    int,
	source_id:     string,
	start:         Session_Start_Event,
	system_prompt: string,
	tools:         []string,
	events:        []Event,
	warnings:      [dynamic]string,
}

// ---- 解析 ----

resolve_session :: proc(req: Session_Request) -> (Resolved_Session, Error) {
	resolved := Resolved_Session{}
	settings := req.settings
	registry := req.registry
	restoring := req.kind != .New

	if restoring {
		// Resume 与 Fork 都允许 source_session_id 为空：此时取最近根 session。
		// CLI 已保证 --fork-session 必须与 -s / -c 连用。
		source_id := req.source_session_id
		if len(source_id) == 0 {
			found, ferr := find_latest_root_session(req.project)
			if !is_ok(ferr) {
				return resolved, ferr
			}
			source_id = found
		}
		expected_path := platform.session_file(req.project, source_id)
		if !os.exists(expected_path) {
			return resolved, make_error(
				.Usage,
				"session %q not found in project %s (expected %s)\nhint: run ap from the directory where the session was created",
				source_id,
				req.project.hash,
				expected_path,
			)
		}
		source_events, rerr := transcript_read_all(req.project, source_id)
		if !is_ok(rerr) {
			return resolved, rerr
		}
		if len(source_events) > 0 && source_events[len(source_events) - 1].type != EVENT_SESSION_END {
			append(
				&resolved.warnings,
				fmt.tprintf(
					"previous run of session %s did not write session_end; recovering after abnormal exit",
					source_id,
				),
			)
		}
		start, frozen_prompt, crerr := session_system_prompt(req.project, source_events)
		if !is_ok(crerr) {
			return resolved, crerr
		}

		resolved.source_id = source_id
		resolved.start = start
		resolved.system_prompt = frozen_prompt
		resolved.events = source_events
		resolved.model = start.model
		resolved.agent_name = start.agent_name
		resolved.agent_depth = start.agent_depth

		// 工具集以 session_start.tools 为准；未知名字跳过并 warning，不终止。
		if frozen_tools, ok := start.tools.?; ok {
			active := make([dynamic]string, 0, len(frozen_tools))
			for name in frozen_tools {
				if _, found := tool.registry_find(&registry, name); !found {
					append(
						&resolved.warnings,
						fmt.tprintf("frozen tool %q is not registered; skipped", name),
					)
					continue
				}
				append(&active, name)
			}
			resolved.tools = active[:]
		} else {
			resolved.tools = tool.registry_names(&registry)
			append(
				&resolved.warnings,
				"session has no recorded tool set; using all registered tools",
			)
		}

		resolved.max_steps = settings.max_steps
		resolved.max_tokens = settings.max_tokens
		if req.max_tokens > 0 {
			resolved.max_tokens = req.max_tokens
		}
		if req.max_steps > 0 {
			resolved.max_steps = req.max_steps
		}

		if len(req.model) > 0 && req.model != start.model {
			append(&resolved.warnings, fmt.tprintf("--model ignored on restore: session is frozen to %q", start.model))
		}
		if len(req.agent_name) > 0 && req.agent_name != start.agent_name {
			append(&resolved.warnings, fmt.tprintf("--agent ignored on restore: session is frozen to %q", start.agent_name))
		}
		if _, ok := req.base_system_prompt.?; ok {
			append(&resolved.warnings, "--base-system-prompt ignored on restore: session prompt is frozen")
		}
		if len(req.prompt_sections) > 0 {
			append(&resolved.warnings, "prompt sections ignored on restore: session prompt is frozen")
		}
		if req.tools != nil {
			append(&resolved.warnings, "tool set ignored on restore: session is frozen to its recorded tool set")
		}
		if req.parent_session_id != nil || req.parent_tool_call_id != nil || req.agent_depth > 0 {
			append(&resolved.warnings, "parent/agent-depth arguments ignored on restore")
		}
		return resolved, ok_error()
	}

	if parent_id, ok := req.parent_session_id.?; ok {
		parent_path := platform.session_file(req.project, parent_id)
		if !os.exists(parent_path) {
			return resolved, make_error(
				.Usage,
				"parent session %q not found (expected %s)",
				parent_id,
				parent_path,
			)
		}
	}

	agent_name := "general"
	if len(req.agent_name) > 0 {
		agent_name = req.agent_name
	}
	resolved.agent_name = agent_name
	resolved.model = settings.model
	if len(req.model) > 0 {
		resolved.model = req.model
	}
	resolved.max_steps = settings.max_steps
	if req.max_steps > 0 {
		resolved.max_steps = req.max_steps
	}
	resolved.max_tokens = settings.max_tokens
	if req.max_tokens > 0 {
		resolved.max_tokens = req.max_tokens
	}
	resolved.agent_depth = req.agent_depth

	// 新 session 的未知工具名属于应用层错误；空切片表示零工具。
	selected, serr := tool.registry_select(&registry, req.tools)
	if !platform.is_ok(serr) {
		return resolved, from_platform(serr, .Usage)
	}
	resolved.tools = selected

	resolved.system_prompt = build_system_prompt(
		{
			base_override = req.base_system_prompt,
			tool_section = tool.registry_prompt_section(&registry, resolved.tools),
			sections = req.prompt_sections,
		},
	)
	return resolved, ok_error()
}

// ---- 入口 ----

// 只解析并生成 system prompt；不创建、不写 session。服务 --print-system-prompt。
preview_prompt :: proc(req: Session_Request) -> (Session_Info, Error) {
	resolved, err := resolve_session(req)
	if !is_ok(err) {
		return {}, err
	}
	info := Session_Info {
		session_id    = resolved.source_id,
		model         = resolved.model,
		agent_name    = resolved.agent_name,
		agent_depth   = resolved.agent_depth,
		system_prompt = resolved.system_prompt,
		warnings      = resolved.warnings[:],
	}
	return info, ok_error()
}

// 运行级上下文开关只在新 session 生效；恢复 / fork 时这些参数只 warning，
// 不能再透传给子代理。
make_session :: proc(
	req: Session_Request,
	resolved: Resolved_Session,
	store: Transcript_Store,
	session_id: string,
	agent_depth: int,
	events: []Event,
) -> Session {
	return {
		project      = req.project,
		settings     = req.settings,
		store        = store,
		registry     = req.registry,
		active_tools = resolved.tools,
		model        = resolved.model,
		agent_name   = resolved.agent_name,
		session_id   = session_id,
		agent_depth  = agent_depth,
		max_steps    = resolved.max_steps,
		max_tokens   = resolved.max_tokens,
		auto_handoff = req.auto_handoff,
		events       = events,
	}
}

make_info :: proc(
	resolved: Resolved_Session,
	session_id: string,
	agent_depth: int,
	initial_line: string,
) -> Session_Info {
	return {
		session_id    = session_id,
		model         = resolved.model,
		agent_name    = resolved.agent_name,
		agent_depth   = agent_depth,
		system_prompt = resolved.system_prompt,
		initial_line  = initial_line,
		warnings      = resolved.warnings[:],
	}
}

session_open :: proc(req: Session_Request) -> (Session, Session_Info, Error) {
	resolved, rerr := resolve_session(req)
	if !is_ok(rerr) {
		return {}, {}, rerr
	}

	store: Transcript_Store
	session_id := ""
	var_events: []Event
	agent_depth := resolved.agent_depth

	if req.kind == .New {
		session_id = new_session_id()
		created, cerr := new_transcript_store(req.project, session_id, req.settings)
		if !is_ok(cerr) {
			return {}, {}, cerr
		}
		store = created

		stored_content := resolved.system_prompt
		var_ref: Maybe(string)
		var_bytes: Maybe(int)
		if len(resolved.system_prompt) > req.settings.blob_threshold_bytes {
			sha, berr := blob_write(req.project, transmute([]byte)resolved.system_prompt)
			if !is_ok(berr) {
				transcript_close(&store)
				return {}, {}, berr
			}
			stored_content = ""
			var_ref = sha
			var_bytes = len(resolved.system_prompt)
		}
		start := Session_Start_Event {
			content       = stored_content,
			cwd           = req.project.root,
			model         = resolved.model,
			provider      = PROVIDER_NAME,
			agent_name    = resolved.agent_name,
			tools         = resolved.tools,
			content_ref   = var_ref,
			content_bytes = var_bytes,
		}
		line, evs, aerr := append_session_start(
			&store,
			start,
			session_id,
			agent_depth,
			req.parent_session_id,
			req.parent_tool_call_id,
			"",
		)
		if !is_ok(aerr) {
			transcript_close(&store)
			return {}, {}, aerr
		}
		var_events = evs
		session := make_session(req, resolved, store, session_id, agent_depth, var_events)
		return session, make_info(resolved, session_id, agent_depth, line), ok_error()
	}

	// Resume / Fork
	parent_session_id := resolved.start.parent_session_id
	parent_tool_call_id := resolved.start.parent_tool_call_id
	if req.kind == .Fork {
		forked_id := new_session_id()
		forked, ferr := fork_transcript(req.project, resolved.source_id, forked_id, req.settings)
		if !is_ok(ferr) {
			return {}, {}, ferr
		}
		store = forked
		session_id = forked_id
		agent_depth = 0
		parent_session_id = nil
		parent_tool_call_id = nil
	} else {
		resumed, resume_err := resume_transcript_store(req.project, resolved.source_id, req.settings)
		if !is_ok(resume_err) {
			return {}, {}, resume_err
		}
		store = resumed
		session_id = resolved.source_id
	}

	line, evs, aerr := append_session_start(
		&store,
		resolved.start,
		session_id,
		agent_depth,
		parent_session_id,
		parent_tool_call_id,
		resolved.source_id,
	)
	if !is_ok(aerr) {
		transcript_close(&store)
		return {}, {}, aerr
	}
	var_events = evs
	session := make_session(req, resolved, store, session_id, agent_depth, var_events)
	return session, make_info(resolved, session_id, agent_depth, line), ok_error()
}

turn_run :: proc(
	s: ^Session,
	prompt: string,
	cancel: ^platform.Cancel_Token,
	emitter: Emitter,
) -> (Turn_Result, Error) {
	loop := loop_init(
		s.project,
		s.settings,
		&s.store,
		s.registry,
		s.active_tools,
		s.model,
		s.agent_name,
		s.session_id,
		s.agent_depth,
		s.max_steps,
		s.max_tokens,
		cancel,
		s.events,
		emitter,
	)
	loop.handoff_enabled = loop.handoff_enabled && s.auto_handoff
	defer loop_destroy(&loop)
	return loop_run_turn(&loop, prompt), ok_error()
}

session_close :: proc(s: ^Session, opts: Close_Options) -> (string, Error) {
	reason := opts.reason
	if len(reason) == 0 {
		reason = SESSION_END_SIGNAL if opts.cancelled else SESSION_END_EXIT
	}
	usage := opts.usage
	if events_now, eerr := transcript_read_all(s.project, s.session_id); is_ok(eerr) {
		summed := historical_usage_from_events(events_now)
		if usage_has_any(summed) || !usage_has_any(opts.usage) {
			usage = summed
		}
	}
	h := make_header(&s.store, EVENT_SESSION_END)
	ev := Session_End_Event {
		header = h,
		reason = reason,
		usage  = usage,
	}
	line, err := transcript_append_line(&s.store, ev)
	transcript_close(&s.store)
	return line, err
}

append_session_start :: proc(
	store: ^Transcript_Store,
	start: Session_Start_Event,
	session_id: string,
	agent_depth: int,
	parent_session_id, parent_tool_call_id: Maybe(string),
	resumed_from: string,
) -> (string, []Event, Error) {
	var_resumed: Maybe(string)
	if len(resumed_from) > 0 {
		var_resumed = resumed_from
	}
	h := make_header(store, EVENT_SESSION_START)
	ev := Session_Start_Event {
		header              = h,
		session_id          = session_id,
		content             = start.content,
		role                = ROLE_SYSTEM,
		cwd                 = start.cwd,
		model               = start.model,
		provider            = start.provider,
		agent_name          = start.agent_name,
		agent_depth         = agent_depth,
		parent_session_id   = parent_session_id,
		parent_tool_call_id = parent_tool_call_id,
		resumed_from        = var_resumed,
		tools               = start.tools,
		content_ref         = start.content_ref,
		content_bytes       = start.content_bytes,
	}
	line, aerr := transcript_append_line(store, ev)
	if !is_ok(aerr) {
		return "", nil, aerr
	}
	refreshed, rerr := transcript_read_all(store.project, session_id)
	if !is_ok(rerr) {
		return "", nil, rerr
	}
	return line, refreshed, ok_error()
}

new_session_id :: proc() -> string {
	id := uuid.generate_v4()
	text := uuid.to_string(id, context.allocator)
	defer delete(text)

	hex: [12]u8
	n := 0
	for i in 0 ..< len(text) {
		ch := text[i]
		if ch == '-' {
			continue
		}
		if n == len(hex) {
			break
		}
		hex[n] = ch
		n += 1
	}

	year, month, day, hour, minute, second := platform.local_now()
	return fmt.aprintf(
		"ses_%04d%02d%02d_%02d%02d%02d_%s",
		year,
		month,
		day,
		hour,
		minute,
		second,
		string(hex[:n]),
	)
}

// 往 session 里写一条 user_message，不开始 turn。
// 只用于交接：新 session 的第一条事件是承载交接文档的 user_message，
// manual handoff 不带 prompt 时没有 turn 可跑。
session_seed_user_message :: proc(s: ^Session, content: string) -> (string, Error) {
	h := make_header(&s.store, EVENT_USER_MESSAGE)
	line, err := transcript_append_line(&s.store, User_Message_Event{header = h, content = content})
	if !is_ok(err) {
		return "", err
	}
	events := make([]Event, len(s.events) + 1)
	copy(events, s.events)
	events[len(s.events)] = Event{v = h.v, seq = h.seq, ts = h.ts, type = h.type, line = line}
	s.events = events
	return line, ok_error()
}

// ---- handoff（会话级） ----
//
// 引擎只产交接文本并写 handoff 事件；创建新 session、打印 id、决定退出码
// 都属于 CLI adapter。session_handoff 同时服务自动交接（turn 内已经跑过一次
// 投影）与 manual handoff（--handoff，没有 turn）。

Session_Handoff_Result :: struct {
	content: string,
	reason:  string,
	usage:   Usage,
}

session_handoff_destroy :: proc(result: ^Session_Handoff_Result) {
	delete(result.content)
	result.content = ""
}

session_handoff :: proc(
	s: ^Session,
	reason: string,
	focus_prompt: string,
	cancel: ^platform.Cancel_Token,
	emitter: Emitter,
) -> (Session_Handoff_Result, Error) {
	out := Session_Handoff_Result{reason = reason}
	if reason == HANDOFF_REASON_MANUAL && !session_has_user_message(s.events) {
		return out, make_error(.Usage, "--handoff requires a session with at least one user_message")
	}
	frozen_prompt, perr := handoff_frozen_prompt(s.project, s.events)
	if !is_ok(perr) {
		return out, perr
	}
	defer delete(frozen_prompt)

	provider := provider_init(s.settings)
	call := s.provider_call
	if call == nil {
		call = provider_stream
	}
	// 事件行由 handoff_run 通过 emitter 转发；这里只需要正文与用量。
	handoff, written, herr := handoff_run(
		{
			project = s.project,
			store = &s.store,
			settings = s.settings,
			provider = &provider,
			provider_call = call,
			model = s.model,
			frozen_system_prompt = frozen_prompt,
			events = s.events,
			focus_prompt = focus_prompt,
			reason = reason,
			cancel = cancel,
			on_transcript = emitter.on_transcript,
			user = emitter.user,
		},
		context.allocator,
	)
	if herr.kind != .None {
		return out, make_error(.Provider, "handoff failed: %s", herr.message)
	}
	// 这条 line 是 transcript_append_line 的独立副本，session 层没有持有者。
	delete(written.line)
	out.content = handoff.content
	out.usage = handoff.usage
	return out, ok_error()
}

session_has_user_message :: proc(events: []Event) -> bool {
	for ev in events {
		if ev.type == EVENT_USER_MESSAGE {
			return true
		}
	}
	return false
}
