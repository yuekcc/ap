package engine

import "../platform"
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

Session_Request :: struct {
	kind:                 Session_Kind,
	project:              platform.Project,
	settings:             ^Settings,
	config_dir:           string,
	cwd:                  string,
	self_exe:             string,
	bash_path:            string,
	source_session_id:    string, // Resume 且为空时取最近的根 session
	model:                Maybe(string),
	agent:                Maybe(string),
	max_steps:            Maybe(int),
	max_tokens:           Maybe(int),
	append_system_prompt: Maybe(string),
	agent_depth:          Maybe(int),
	parent_session_id:    Maybe(string),
	parent_tool_call_id:  Maybe(string),
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
	project:     platform.Project,
	settings:    ^Settings,
	store:       Transcript_Store,
	agent:       Agent_Def,
	model:       string,
	config_dir:  string,
	self_exe:    string,
	bash_path:   string,
	session_id:  string,
	agent_depth: int,
	max_steps:   int,
	max_tokens:  int,
	events:      []Event,
}

Close_Options :: struct {
	cancelled: bool,
	reason:    string,
	usage:     Usage,
}

Turn_Result :: Loop_Result

Resolved_Session :: struct {
	agent:        Agent_Def,
	model:        string,
	agent_name:   string,
	max_steps:    int,
	max_tokens:   int,
	agent_depth:  int,
	source_id:    string,
	start:        Session_Start_Event,
	system_prompt: string,
	events:       []Event,
	warnings:     [dynamic]string,
}

// ---- 解析 ----

resolve_session :: proc(req: Session_Request) -> (Resolved_Session, Error) {
	resolved := Resolved_Session{}
	settings := req.settings
	restoring := req.kind != .New

	if restoring {
		if req.kind == .Fork && len(req.source_session_id) == 0 {
			return resolved, make_error(.Usage, "--fork-session requires --session or --continue")
		}
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
		if len(source_events) > 0 && source_events[len(source_events) - 1].type != "session_end" {
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
		agent, aerr := load_agent(req.config_dir, resolved.agent_name)
		if !is_ok(aerr) {
			return resolved, aerr
		}
		resolved.agent = agent
		resolved.max_steps = settings.max_steps
		resolved.max_tokens = settings.max_tokens
		if value, ok := req.max_tokens.?; ok {
			resolved.max_tokens = value
		}
		agent_steps_applies := req.max_steps == nil || req.parent_session_id != nil
		if agent_steps_applies {
			if value, ok := agent.max_steps.?; ok {
				resolved.max_steps = value
			}
		}
		if opts_model, ok := req.model.?; ok && opts_model != start.model {
			append(&resolved.warnings, fmt.tprintf("--model ignored on restore: session is frozen to %q", start.model))
		}
		if opts_agent, ok := req.agent.?; ok && opts_agent != start.agent_name {
			append(&resolved.warnings, fmt.tprintf("--agent ignored on restore: session is frozen to %q", start.agent_name))
		}
		if value, ok := req.append_system_prompt.?; ok && len(value) > 0 {
			append(&resolved.warnings, "--append-system-prompt ignored on restore")
		}
		if req.parent_session_id != nil || req.parent_tool_call_id != nil || req.agent_depth != nil {
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
	if value, ok := req.agent.?; ok {
		agent_name = value
	}
	agent, aerr := load_agent(req.config_dir, agent_name)
	if !is_ok(aerr) {
		return resolved, aerr
	}
	resolved.agent = agent
	resolved.agent_name = agent_name
	resolved.model = settings.model
	if value, ok := req.model.?; ok {
		resolved.model = value
	}
	resolved.max_steps = settings.max_steps
	if value, ok := req.max_steps.?; ok {
		resolved.max_steps = value
	}
	resolved.max_tokens = settings.max_tokens
	if value, ok := req.max_tokens.?; ok {
		resolved.max_tokens = value
	}
	agent_model_applies := req.model == nil || req.parent_session_id != nil
	agent_steps_applies := req.max_steps == nil || req.parent_session_id != nil
	if agent_model_applies {
		if value, ok := agent.model.?; ok {
			resolved.model = value
		}
	}
	if agent_steps_applies {
		if value, ok := agent.max_steps.?; ok {
			resolved.max_steps = value
		}
	}
	if value, ok := req.agent_depth.?; ok {
		resolved.agent_depth = value
	}
	append_prompt := ""
	if value, ok := req.append_system_prompt.?; ok {
		append_prompt = value
	}
	skill_section := skills_prompt_block(discover_skills(req.cwd))
	resolved.system_prompt = build_system_prompt(
		{
			cwd = req.cwd,
			config_dir = req.config_dir,
			agent = agent,
			append_prompt = append_prompt,
			tool_section = tool_prompt_section(agent, resolved.agent_depth, settings.max_agent_depth),
			skill_section = skill_section,
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

session_open :: proc(req: Session_Request) -> (Session, Session_Info, Error) {
	resolved, rerr := resolve_session(req)
	if !is_ok(rerr) {
		return {}, {}, rerr
	}

	store: Transcript_Store
	session_id := ""
	var_events: []Event
	agent := resolved.agent
	model := resolved.model
	agent_depth := resolved.agent_depth
	max_steps := resolved.max_steps
	max_tokens := resolved.max_tokens

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
			model         = model,
			provider      = PROVIDER_NAME,
			agent_name    = agent.name,
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
		info := Session_Info {
			session_id    = session_id,
			model         = model,
			agent_name    = agent.name,
			agent_depth   = agent_depth,
			system_prompt = resolved.system_prompt,
			initial_line  = line,
			warnings      = resolved.warnings[:],
		}
		session := Session {
			project     = req.project,
			settings    = req.settings,
			store       = store,
			agent       = agent,
			model       = model,
			config_dir  = req.config_dir,
			self_exe    = req.self_exe,
			bash_path   = req.bash_path,
			session_id  = session_id,
			agent_depth = agent_depth,
			max_steps   = max_steps,
			max_tokens  = max_tokens,
			events      = var_events,
		}
		return session, info, ok_error()
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
	info := Session_Info {
		session_id    = session_id,
		model         = model,
		agent_name    = agent.name,
		agent_depth   = agent_depth,
		system_prompt = resolved.system_prompt,
		initial_line  = line,
		warnings      = resolved.warnings[:],
	}
	session := Session {
		project     = req.project,
		settings    = req.settings,
		store       = store,
		agent       = agent,
		model       = model,
		config_dir  = req.config_dir,
		self_exe    = req.self_exe,
		bash_path   = req.bash_path,
		session_id  = session_id,
		agent_depth = agent_depth,
		max_steps   = max_steps,
		max_tokens  = max_tokens,
		events      = var_events,
	}
	return session, info, ok_error()
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
		s.agent,
		s.model,
		s.config_dir,
		s.self_exe,
		s.bash_path,
		s.session_id,
		s.agent_depth,
		s.settings.max_agent_depth,
		s.max_steps,
		s.max_tokens,
		cancel,
		s.events,
		emitter,
	)
	defer loop_destroy(&loop)
	return loop_run_turn(&loop, prompt), ok_error()
}

session_close :: proc(s: ^Session, opts: Close_Options) -> (string, Error) {
	usage := opts.usage
	if events_now, eerr := transcript_read_all(s.project, s.session_id); is_ok(eerr) {
		summed := historical_usage_from_events(events_now)
		if usage_has_any(summed) || !usage_has_any(opts.usage) {
			usage = summed
		}
	}
	h := make_header(&s.store, "session_end")
	ev := Session_End_Event {
		header = h,
		reason = opts.reason,
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
	h := make_header(store, "session_start")
	ev := Session_Start_Event {
		header              = h,
		session_id          = session_id,
		content             = start.content,
		role                = "system",
		cwd                 = start.cwd,
		model               = start.model,
		provider            = start.provider,
		agent_name          = start.agent_name,
		agent_depth         = agent_depth,
		parent_session_id   = parent_session_id,
		parent_tool_call_id = parent_tool_call_id,
		resumed_from        = var_resumed,
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
	return fmt.tprintf(
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
