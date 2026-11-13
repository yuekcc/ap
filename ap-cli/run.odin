package apcli

import apcore "../ap-core"
import platform "../ap-core/platform"
import protocol "../ap-core/protocol"
import apskills "skills"
import aptools "tools"

import "core:fmt"
import "core:os"

// CLI 适配层：参数、settings、环境发现、输出、退出码、信号，以及组装根。
// agent loop / provider / transcript 在 apcore；具体工具在 ap-cli/tools；
// 技能发现与 system prompt 段落组装在这里。
//
// 交接（handoff）拆成两半：引擎产交接文本并写 handoff 事件，这里拿文本
// 创建新 session、打印 session id、决定退出码。

run :: proc(args: []string) -> int {
	platform.setup_console()
	normalized := platform.normalize_args(args)
	opts, perr := parse_args(normalized)
	if !is_ok(perr) {
		apcore.log_error("%s", perr.message)
		fmt.eprintln("hint: run ap --help for usage")
		return int(Exit_Code.Usage)
	}
	if opts.help {
		print_usage()
		return 0
	}
	if opts.version {
		fmt.printfln("ap %s", VERSION)
		return 0
	}
	if opts.list_skills {
		return list_skills()
	}
	if opts.debug {
		apcore.log_set_level(.Debug)
	} else if opts.verbose {
		apcore.log_set_level(.Info)
	} else {
		apcore.log_set_level(.Warn)
	}

	config_dir, cerr := platform.default_config_dir(opts.config_dir)
	if !platform.is_ok(cerr) {
		apcore.log_error("%s", cerr.message)
		return int(Exit_Code.Usage)
	}
	// 日志目录确定后立刻挂上文件日志；未初始化时日志只写 stderr。
	apcore.log_file_open(config_dir)
	defer apcore.log_file_close()

	// 配置文件（settings.jsonc 优先，否则 settings.json）只由 CLI 读取；
	// preview 不调用模型，因此不要求 API key。
	loaded, serr := load_settings(config_dir, !opts.print_system_prompt)
	if !apcore.is_ok(serr) {
		apcore.log_error("%s", serr.message)
		return exit_code_for(serr.kind)
	}
	if value, ok := opts.context_window.?; ok {
		loaded.sdk.context_window_tokens = value
	}
	// --context-window 覆盖之后要重新校验：它可能与 max_tokens 或余量冲突。
	if verr := validate_context_budget(loaded.sdk); !apcore.is_ok(verr) {
		apcore.log_error("settings: %s", verr.message)
		return int(Exit_Code.Usage)
	}
	cwd, cwderr := platform.canonicalize_path(".", true)
	if !platform.is_ok(cwderr) {
		apcore.log_error("%s", cwderr.message)
		return int(Exit_Code.Usage)
	}
	bash_path, berr := platform.find_bash()
	if !platform.is_ok(berr) {
		apcore.log_error("%s", berr.message)
		return int(Exit_Code.Usage)
	}
	home_dir := ""
	if home, herr := os.user_home_dir(context.allocator); herr == nil {
		home_dir = home
	}

	kind := apcore.Session_Kind.New
	if opts.session_id != nil || opts.continue_session {
		kind = .Fork if opts.fork_session else .Resume
	}
	source_id := ""
	if value, ok := opts.session_id.?; ok {
		source_id = value
	}

	// manual handoff：带上提示词时它既是交接的聚焦点，也是新 session 的第一个 turn。
	manual_handoff := opts.handoff != nil
	focus_prompt := ""
	if manual_handoff {
		value, _ := opts.handoff.?
		focus_prompt = value
	}

	prompt := ""
	if !opts.print_system_prompt && !manual_handoff {
		value, prerr := read_prompt(opts, cwd)
		if !is_ok(prerr) {
			apcore.log_error("%s", prerr.message)
			return int(Exit_Code.Usage)
		}
		prompt = value
	}

	// 工具注册表与宿主配置。session 期间 tool_cfg 必须存活。
	tool_cfg := loaded.tool
	tool_cfg.bash_path = bash_path
	tool_cfg.self_exe = platform.resolve_self_exe()
	tool_cfg.model = loaded.sdk.model
	tool_cfg.max_steps = loaded.sdk.max_steps
	if kind == .New {
		// 恢复 / fork 沿用冻结值，这两个开关只对新 session 及它的子代理生效。
		tool_cfg.no_agents_md = opts.no_agents_md
		tool_cfg.no_skills = opts.no_skills
	}
	tool_defs := aptools.builtin_tools(&tool_cfg)
	registry, rerr := apcore.registry_init(tool_defs)
	if !apcore.is_ok(rerr) {
		apcore.log_error("%s", rerr.message)
		return exit_code_for(rerr.kind)
	}

	env, eerr := apcore.env_open({
		config_dir = config_dir,
		cwd        = cwd,
		settings   = loaded.sdk,
		tools      = tool_defs,
	})
	if !apcore.is_ok(eerr) {
		apcore.log_error("%s", eerr.message)
		return exit_code_for(eerr.kind)
	}
	// 提示词文件的相对路径按启动目录解析。
	cwd = env.cwd

	new_opts: apcore.Session_Options
	if kind == .New || manual_handoff {
		built, nerr := build_new_session_opts(
			opts,
			loaded.sdk,
			config_dir,
			cwd,
			home_dir,
			&tool_cfg,
			&registry,
		)
		if !is_ok(nerr) {
			apcore.log_error("%s", nerr.message)
			return int(nerr.code)
		}
		new_opts = built
	}

	session_opts := new_opts
	session_opts.kind = kind
	session_opts.source_session_id = source_id
	session_opts.parent_session_id = opts.parent_session_id
	session_opts.parent_tool_call_id = opts.parent_tool_call_id
	session_opts.auto_handoff = !opts.no_handoff
	if kind != .New {
		// 恢复 / fork 使用冻结 prompt 与工具集；只把显式选项传下去以便 warning。
		session_opts.agent_name = ""
		session_opts.model = ""
		session_opts.max_steps = 0
		session_opts.max_tokens = 0
		session_opts.agent_depth = 0
		session_opts.base_system_prompt = nil
		session_opts.prompt_sections = nil
		session_opts.tools = nil
		if value, ok := opts.agent.?; ok {
			session_opts.agent_name = value
		}
		if value, ok := opts.model.?; ok {
			session_opts.model = value
		}
		if value, ok := opts.max_steps.?; ok {
			session_opts.max_steps = value
		}
		if value, ok := opts.max_tokens.?; ok {
			session_opts.max_tokens = value
		}
		if value, ok := opts.agent_depth.?; ok {
			session_opts.agent_depth = value
		}
		// tools 保持 nil：恢复时忽略，不应产生显式覆盖 warning。
	}

	if opts.print_system_prompt {
		info, ierr := apcore.preview_prompt(&env, session_opts)
		if !apcore.is_ok(ierr) {
			apcore.log_error("%s", ierr.message)
			return exit_code_for(ierr.kind)
		}
		for warning in info.warnings {
			apcore.log_warn("%s", warning)
		}
		print_system_prompt_text(info.system_prompt)
		return int(Exit_Code.OK)
	}

	session, info, oerr := apcore.session_open(&env, session_opts)
	if !apcore.is_ok(oerr) {
		apcore.log_error("%s", oerr.message)
		return exit_code_for(oerr.kind)
	}
	for warning in info.warnings {
		apcore.log_warn("%s", warning)
	}
	// task 子代理沿用本次 session 实际使用的 model / max_steps。
	tool_cfg.model = session.model
	tool_cfg.max_steps = session.max_steps

	cancel: apcore.Cancel_Token
	install_signal_handlers(&cancel)
	out := Output_State{format = opts.output_format}
	if out.format == .Text {
		// text 的 stderr 用 ap-tui 风格渲染；非 TTY（管道、重定向）时关掉颜色。
		console_init(&out.console, os.stderr, env.project, console_color_enabled())
	}
	if out.format == .Stream_Json && len(info.initial_line) > 0 {
		write_stdout(transmute([]byte)info.initial_line)
		write_stdout(transmute([]byte)string("\n"))
	}
	emitter := make_loop_emitter(&out)

	if manual_handoff {
		return run_manual_handoff(
			&env,
			&session,
			new_opts,
			&out,
			emitter,
			&cancel,
			focus_prompt,
			normalized,
		)
	}

	result, terr := apcore.turn_run(&session, prompt, &cancel, emitter)
	if out.format == .Text {
		console_finish(&out.console)
	}
	if !apcore.is_ok(terr) {
		apcore.log_error("%s", terr.message)
		err_end_line, _ := apcore.session_close(&session, {reason = protocol.SESSION_END_ERROR, usage = {}})
		if out.format == .Stream_Json {
			write_stdout(transmute([]byte)err_end_line)
			write_stdout(transmute([]byte)string("\n"))
		}
		return exit_code_for(terr.kind)
	}

	if result.error_kind == .None && !result.cancelled && signal_exit_code() != 0 {
		result.cancelled = true
		result.stop_reason = protocol.STOP_REASON_CANCELLED
	}
	platform.cleanup_jobs()
	reason := protocol.SESSION_END_EXIT
	if result.cancelled {
		reason = protocol.SESSION_END_SIGNAL
	} else if result.error_kind != .None {
		reason = protocol.SESSION_END_ERROR
	}
	end_line, end_err := apcore.session_close(
		&session,
		{
			cancelled = result.cancelled,
			reason = reason,
			usage = result.session_usage,
		},
	)
	if !apcore.is_ok(end_err) {
		apcore.log_error("%s", end_err.message)
		return int(Exit_Code.Internal)
	}
	if out.format == .Stream_Json {
		write_stdout(transmute([]byte)end_line)
		write_stdout(transmute([]byte)string("\n"))
	}

	// 自动交接：引擎已经把交接文档写进 handoff 事件，这里创建承载它的新 session。
	var_handoff: Maybe(Final_Handoff)
	if result.stop_reason == apcore.STOP_REASON_HANDOFF {
		handoff, herr := open_handoff_session(
			&env,
			new_opts,
			session.session_id,
			result.handoff_content,
		)
		if !apcore.is_ok(herr) {
			apcore.log_error("%s", herr.message)
			delete(result.result_text)
			delete(result.handoff_content)
			return exit_code_for(herr.kind)
		}
		// 新 session 只承载交接文档，不跑 turn。仍然要写 session_end，
		// 否则下次恢复会误判成异常退出。
		write_handoff_start(&out, handoff)
		handoff_end, close_err := apcore.session_close(
			&handoff.session,
			{reason = protocol.SESSION_END_EXIT},
		)
		if out.format == .Stream_Json && apcore.is_ok(close_err) {
			write_stdout(transmute([]byte)handoff_end)
			write_stdout(transmute([]byte)string("\n"))
		}
		var_handoff = Final_Handoff {
			reason     = result.handoff_reason,
			session_id = handoff.session.session_id,
			content    = result.handoff_content,
			usage      = result.handoff_usage,
		}
	}

	output_final(&out, session.session_id, result, var_handoff)
	// Loop_Result 的内容都是 engine 给调用方的独立副本。
	delete(result.result_text)
	delete(result.handoff_content)
	exit_code := exit_code_for(result.error_kind)
	if result.cancelled {
		signal_code := signal_exit_code()
		exit_code = signal_code if signal_code != 0 else 130
	}
	// turn 结束后进程即退出；给出可直接复制的续聊命令。
	if len(normalized) > 0 {
		if value, ok := var_handoff.?; ok {
			fmt.eprintf("\n---\n\nhandoff created session %s\n", value.session_id)
		} else {
			fmt.eprintf("\n---\n\ncontinue with -s %s\n", session.session_id)
		}
	}
	return exit_code
}

// 一次交接创建出的新 session。close 在调用方跑完它的首个 turn 之后执行。
Handoff_Session :: struct {
	session:      apcore.Session,
	// session_open 产出的 stream-json 首行；必须在它的 session_end 之前写出。
	initial_line: string,
}

// stream-json 的消费者（例如 ap-web 的 runner）靠新 session 的 session_start
// 把标签页切到交接后的 session；text/json 不需要这一行。
write_handoff_start :: proc(out: ^Output_State, handoff: Handoff_Session) {
	if out.format != .Stream_Json || len(handoff.initial_line) == 0 {
		return
	}
	write_stdout(transmute([]byte)handoff.initial_line)
	write_stdout(transmute([]byte)string("\n"))
}

// 新 session 走正常的 new session 路径：重新组装 system prompt，用当前工具集、
// 当前模型、当前 AGENTS.md 与技能。不是 fork，不复制 transcript。
// 第一条事件是承载交接文档的 user_message，判定靠首行文本。
open_handoff_session :: proc(
	env: ^apcore.Env,
	new_opts: apcore.Session_Options,
	source_session_id, content: string,
) -> (Handoff_Session, apcore.Error) {
	out := Handoff_Session{}
	opts := new_opts
	opts.kind = .New
	opts.parent_session_id = nil
	opts.parent_tool_call_id = nil
	opts.agent_depth = 0

	session, info, oerr := apcore.session_open(env, opts)
	if !apcore.is_ok(oerr) {
		return out, oerr
	}
	for warning in info.warnings {
		apcore.log_warn("%s", warning)
	}
	seed := apcore.handoff_user_message(source_session_id, content)
	if _, err := apcore.session_seed_user_message(&session, seed); !apcore.is_ok(err) {
		apcore.session_close(&session, {reason = protocol.SESSION_END_ERROR, usage = {}})
		return out, err
	}
	out.session = session
	out.initial_line = info.initial_line
	return out, apcore.ok_error()
}

// manual handoff：先让源 session 产交接文档，再创建新 session。
// 有聚焦提示词时在新 session 里继续跑这个 turn；没有时只打印新 session id。
run_manual_handoff :: proc(
	env: ^apcore.Env,
	source: ^apcore.Session,
	new_opts: apcore.Session_Options,
	out: ^Output_State,
	emitter: apcore.Emitter,
	cancel: ^apcore.Cancel_Token,
	focus_prompt: string,
	normalized: []string,
) -> int {
	handoff, herr := apcore.session_handoff(
		source,
		apcore.HANDOFF_REASON_MANUAL,
		focus_prompt,
		cancel,
		emitter,
	)
	if !apcore.is_ok(herr) {
		apcore.log_error("%s", herr.message)
		// 交接没写成也要关掉源 session，否则 flush 与 session_end 都缺。
		_, close_err := apcore.session_close(source, {reason = protocol.SESSION_END_ERROR})
		if !apcore.is_ok(close_err) {
			apcore.log_warn("%s", close_err.message)
		}
		return exit_code_for(herr.kind)
	}
	defer apcore.session_handoff_destroy(&handoff)

	// session_close 会从 transcript 重算整份用量，已经包含交接这一次调用。
	source_end, _ := apcore.session_close(source, {reason = protocol.SESSION_END_EXIT})
	if out.format == .Stream_Json {
		write_stdout(transmute([]byte)source_end)
		write_stdout(transmute([]byte)string("\n"))
	}

	opened, oerr := open_handoff_session(env, new_opts, source.session_id, handoff.content)
	if !apcore.is_ok(oerr) {
		apcore.log_error("%s", oerr.message)
		return exit_code_for(oerr.kind)
	}
	write_handoff_start(out, opened)

	payload: Maybe(Final_Handoff) = Final_Handoff {
		reason     = apcore.HANDOFF_REASON_MANUAL,
		session_id = opened.session.session_id,
		content    = handoff.content,
		usage      = handoff.usage,
	}

	result: apcore.Turn_Result
	close_reason := protocol.SESSION_END_EXIT
	turn_error: apcore.Error
	if len(focus_prompt) > 0 {
		result, turn_error = apcore.turn_run(&opened.session, focus_prompt, cancel, emitter)
		if out.format == .Text {
			console_finish(&out.console)
		}
		if !apcore.is_ok(turn_error) {
			apcore.log_error("%s", turn_error.message)
			close_reason = protocol.SESSION_END_ERROR
		} else if result.error_kind != .None {
			close_reason = protocol.SESSION_END_ERROR
		}
	}
	end_line, end_err := apcore.session_close(
		&opened.session,
		{reason = close_reason, usage = result.session_usage},
	)
	if !apcore.is_ok(end_err) {
		apcore.log_error("%s", end_err.message)
		return int(Exit_Code.Internal)
	}
	if out.format == .Stream_Json {
		write_stdout(transmute([]byte)end_line)
		write_stdout(transmute([]byte)string("\n"))
	}

	if result.error_kind == .None && !result.cancelled && signal_exit_code() != 0 {
		result.cancelled = true
		result.stop_reason = protocol.STOP_REASON_CANCELLED
	}
	output_final(out, opened.session.session_id, result, payload)
	delete(result.result_text)
	delete(result.handoff_content)
	if len(normalized) > 0 {
		fmt.eprintf("\n---\n\nhandoff created session %s\n", opened.session.session_id)
	}
	// turn_run 自己的错误（例如 session 写失败）没有 error_kind，要单独映射。
	exit_code := exit_code_for(turn_error.kind if !apcore.is_ok(turn_error) else result.error_kind)
	if result.cancelled {
		signal_code := signal_exit_code()
		exit_code = signal_code if signal_code != 0 else 130
	}
	return exit_code
}

// 新 session 的组装：agent 定义、技能、记忆、工具白名单、system prompt 覆盖。
// 交接后新建的 session 也走这里，所以它是纯函数式的「从头组装」。
build_new_session_opts :: proc(
	opts: Options,
	sdk: apcore.Settings,
	config_dir, cwd, home_dir: string,
	tool_cfg: ^aptools.Tool_Config,
	registry: ^apcore.Registry,
) -> (apcore.Session_Options, Error) {
	out := apcore.Session_Options{}
	name := "general"
	if value, ok := opts.agent.?; ok {
		name = value
	}
	agent, aerr := load_agent(config_dir, name)
	if !is_ok(aerr) {
		return out, aerr
	}

	// 优先级：CLI > agent 定义 > settings。
	model := sdk.model
	if value, ok := agent.model.?; ok {
		model = value
	}
	if value, ok := opts.model.?; ok {
		model = value
	}
	max_steps := sdk.max_steps
	if value, ok := agent.max_steps.?; ok {
		max_steps = value
	}
	if value, ok := opts.max_steps.?; ok {
		max_steps = value
	}
	max_tokens := sdk.max_tokens
	if value, ok := opts.max_tokens.?; ok {
		max_tokens = value
	}

	base_prompt, bperr := read_system_prompt_override(config_dir)
	if !is_ok(bperr) {
		return out, bperr
	}
	skill_section := ""
	if !opts.no_skills {
		skill_section = skills_section_for(cwd)
	}

	agent_depth := 0
	if value, ok := opts.agent_depth.?; ok {
		agent_depth = value
	}
	selected, terr := resolve_agent_tools(agent, registry, agent_depth, tool_cfg.max_agent_depth)
	if !is_ok(terr) {
		return out, terr
	}

	tool_cfg.model = model
	tool_cfg.max_steps = max_steps
	out.agent_name = agent.name
	out.model = model
	out.max_steps = max_steps
	out.max_tokens = max_tokens
	out.agent_depth = agent_depth
	out.base_system_prompt = base_prompt
	out.prompt_sections = build_prompt_sections(
		{
			cwd = cwd,
			home_dir = home_dir,
			agent = agent,
			skill_section = skill_section,
			include_memory = !opts.no_agents_md,
		},
	)
	out.tools = selected
	out.auto_handoff = !opts.no_handoff
	return out, ok_error()
}

skills_section_for :: proc(cwd: string) -> string {
	return apskills.skills_prompt_block(apskills.discover_skills(cwd))
}

list_skills :: proc() -> int {
	skills := apskills.discover_skills(".")
	write_stdout(transmute([]byte)apskills.skills_brief(skills))
	return int(Exit_Code.OK)
}

// 打印 system prompt 后直接返回，不创建 session、不调用模型。
print_system_prompt_text :: proc(text: string) {
	write_stdout(transmute([]byte)text)
	if len(text) == 0 || text[len(text) - 1] != '\n' {
		write_stdout(transmute([]byte)string("\n"))
	}
}

exit_code_for :: proc(kind: apcore.Error_Kind) -> int {
	switch kind {
	case .None:
		return 0
	case .Usage:
		return int(Exit_Code.Usage)
	case .Internal:
		return int(Exit_Code.Internal)
	case .Provider:
		return int(Exit_Code.Provider)
	case .Tool:
		return int(Exit_Code.Tool)
	}
	return int(Exit_Code.Internal)
}
