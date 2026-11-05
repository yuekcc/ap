package apcli

import apcore "../ap-core"
import platform "../ap-core/platform"
import apskills "skills"
import aptools "tools"

import "core:fmt"
import "core:os"

// CLI 适配层：参数、settings、环境发现、输出、退出码、信号，以及组装根。
// agent loop / provider / transcript 在 apcore；具体工具在 ap-cli/tools；
// 技能发现与 system prompt 段落组装在这里。

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

	// settings.json 只由 CLI 读取；preview 不调用模型，因此不要求 API key。
	loaded, serr := load_settings(config_dir, !opts.print_system_prompt)
	if !apcore.is_ok(serr) {
		apcore.log_error("%s", serr.message)
		return exit_code_for(serr.kind)
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

	prompt := ""
	if !opts.print_system_prompt {
		value, prerr := read_prompt(opts, cwd)
		if !is_ok(prerr) {
			apcore.log_error("%s", prerr.message)
			return int(Exit_Code.Usage)
		}
		prompt = value
	}

	// 新 session 才需要 agent 定义、技能、记忆与工具白名单。
	base_prompt: Maybe(string)
	agent := agent_default_general()
	agent_name := ""
	model := ""
	max_steps := 0
	max_tokens := 0
	active_tools: []string
	prompt_sections: []string
	skill_section := ""
	if kind == .New {
		name := "general"
		if value, ok := opts.agent.?; ok {
			name = value
		}
		loaded_agent, aerr := load_agent(config_dir, name)
		if !is_ok(aerr) {
			apcore.log_error("%s", aerr.message)
			return int(aerr.code)
		}
		agent = loaded_agent
		agent_name = agent.name

		// 优先级：CLI > agent 定义 > settings。
		model = loaded.sdk.model
		if value, ok := agent.model.?; ok {
			model = value
		}
		if value, ok := opts.model.?; ok {
			model = value
		}
		max_steps = loaded.sdk.max_steps
		if value, ok := agent.max_steps.?; ok {
			max_steps = value
		}
		if value, ok := opts.max_steps.?; ok {
			max_steps = value
		}
		max_tokens = loaded.sdk.max_tokens
		if value, ok := opts.max_tokens.?; ok {
			max_tokens = value
		}

		value, bperr := read_system_prompt_override(config_dir)
		if !is_ok(bperr) {
			apcore.log_error("%s", bperr.message)
			return int(Exit_Code.Usage)
		}
		base_prompt = value

		if !opts.no_skills {
			skill_section = skills_section_for(cwd)
		}
	}

	// 工具注册表与宿主配置。session 期间 tool_cfg 必须存活。
	tool_cfg := loaded.tool
	tool_cfg.bash_path = bash_path
	tool_cfg.self_exe = platform.resolve_self_exe()
	if kind == .New {
		tool_cfg.model = model
		tool_cfg.max_steps = max_steps
		tool_cfg.no_agents_md = opts.no_agents_md
		tool_cfg.no_skills = opts.no_skills
	}
	tool_defs := aptools.builtin_tools(&tool_cfg)
	registry, rerr := apcore.registry_init(tool_defs)
	if !apcore.is_ok(rerr) {
		apcore.log_error("%s", rerr.message)
		return exit_code_for(rerr.kind)
	}

	if kind == .New {
		agent_depth := 0
		if value, ok := opts.agent_depth.?; ok {
			agent_depth = value
		}
		selected, terr := resolve_agent_tools(agent, &registry, agent_depth, tool_cfg.max_agent_depth)
		if !is_ok(terr) {
			apcore.log_error("%s", terr.message)
			return int(terr.code)
		}
		active_tools = selected
		prompt_sections = build_prompt_sections(
			{
				cwd = cwd,
				home_dir = home_dir,
				agent = agent,
				skill_section = skill_section,
				include_memory = !opts.no_agents_md,
			},
		)
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

	session_opts := apcore.Session_Options {
		kind                = kind,
		source_session_id   = source_id,
		base_system_prompt  = base_prompt,
		agent_depth         = 0,
		parent_session_id   = opts.parent_session_id,
		parent_tool_call_id = opts.parent_tool_call_id,
	}
	if kind == .New {
		session_opts.agent_name = agent_name
		session_opts.model = model
		session_opts.max_steps = max_steps
		session_opts.max_tokens = max_tokens
		session_opts.prompt_sections = prompt_sections
		session_opts.tools = active_tools
		if value, ok := opts.agent_depth.?; ok {
			session_opts.agent_depth = value
		}
	} else {
		// 恢复 / fork 使用冻结 prompt 与工具集；只把显式选项传下去以便 warning。
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
	if out.format == .Stream_Json && len(info.initial_line) > 0 {
		write_stdout(transmute([]byte)info.initial_line)
		write_stdout(transmute([]byte)string("\n"))
	}
	emitter := make_loop_emitter(&out)
	result, terr := apcore.turn_run(&session, prompt, &cancel, emitter)
	if !apcore.is_ok(terr) {
		apcore.log_error("%s", terr.message)
		err_end_line, _ := apcore.session_close(&session, {reason = "error", usage = {}})
		if out.format == .Stream_Json {
			write_stdout(transmute([]byte)err_end_line)
			write_stdout(transmute([]byte)string("\n"))
		}
		return exit_code_for(terr.kind)
	}

	if result.error_kind == .None && !result.cancelled && signal_exit_code() != 0 {
		result.cancelled = true
		result.stop_reason = "cancelled"
	}
	platform.cleanup_jobs()
	reason := "exit"
	if result.cancelled {
		reason = "signal"
	} else if result.error_kind != .None {
		reason = "error"
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

	output_final(&out, session.session_id, result)
	// Loop_Result.result_text 是 engine 给调用方的独立副本。
	delete(result.result_text)
	exit_code := exit_code_for(result.error_kind)
	if result.cancelled {
		signal_code := signal_exit_code()
		exit_code = signal_code if signal_code != 0 else 130
	}
	// turn 结束后进程即退出；给出可直接复制的续聊命令。
	if len(normalized) > 0 {
		fmt.eprintf("\n---\n\n继续对话，执行：%s -s %s\n", normalized[0], session.session_id)
	}
	return exit_code
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
