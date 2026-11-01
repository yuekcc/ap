package apcli

import apcore "../ap-core"
import platform "../ap-core/platform"
import "core:fmt"

// CLI 适配层：参数、输出格式、退出码、信号。
// 配置解析与 agent 编排在 apcore（SDK）；这里只做宿主侧的工作。

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
	if opts.list_tools {
		return list_tools(opts)
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
	// settings.json 只由 CLI 读取；SDK 只接收解析后的 Settings。
	settings, serr := load_settings(config_dir)
	if !apcore.is_ok(serr) {
		apcore.log_error("%s", serr.message)
		return exit_code_for(serr.kind)
	}
	bash_path, berr := platform.find_bash()
	if !platform.is_ok(berr) {
		apcore.log_error("%s", berr.message)
		return int(Exit_Code.Usage)
	}

	env, eerr := apcore.env_open({
		config_dir = config_dir,
		bash_path  = bash_path,
		settings   = settings,
	})
	if !apcore.is_ok(eerr) {
		apcore.log_error("%s", eerr.message)
		return exit_code_for(eerr.kind)
	}
	// 提示词文件与 --base-system-prompt-file 的相对路径按启动目录解析。
	cwd := env.cwd

	base_prompt, bperr := read_base_system_prompt(opts, cwd)
	if !is_ok(bperr) {
		apcore.log_error("%s", bperr.message)
		return int(Exit_Code.Usage)
	}
	append_prompt, aperr := read_append_system_prompt(opts)
	if !is_ok(aperr) {
		apcore.log_error("%s", aperr.message)
		return int(Exit_Code.Usage)
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

	kind := apcore.Session_Kind.New
	if opts.session_id != nil || opts.continue_session {
		kind = .Fork if opts.fork_session else .Resume
	}
	source_id := ""
	if value, ok := opts.session_id.?; ok {
		source_id = value
	}
	session_opts := apcore.Session_Options {
		kind                 = kind,
		source_session_id    = source_id,
		model                = opts.model,
		agent                = opts.agent,
		max_steps            = opts.max_steps,
		max_tokens           = opts.max_tokens,
		append_system_prompt = append_prompt,
		base_system_prompt   = base_prompt,
		no_agents_md         = opts.no_agents_md,
		no_skills            = opts.no_skills,
		tools_set            = opts.tools_set,
		tools                = opts.tools,
		agent_depth          = opts.agent_depth,
		parent_session_id    = opts.parent_session_id,
		parent_tool_call_id  = opts.parent_tool_call_id,
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

list_skills :: proc() -> int {
	text, err := apcore.list_skills_text(".")
	if !apcore.is_ok(err) {
		apcore.log_error("%s", err.message)
		return exit_code_for(err.kind)
	}
	write_stdout(transmute([]byte)text)
	return int(Exit_Code.OK)
}

// 只列出 agent 定义 + --tools 覆盖后的声明工具集；不读 settings.json、
// 不需要 API key、不创建 session。task 的深度移除是运行期行为，这里不体现。
list_tools :: proc(opts: Options) -> int {
	config_dir, cerr := platform.default_config_dir(opts.config_dir)
	if !platform.is_ok(cerr) {
		apcore.log_error("%s", cerr.message)
		return int(Exit_Code.Usage)
	}
	text, err := apcore.list_tools_text(
		config_dir,
		opts.agent,
		opts.tools_set,
		opts.tools,
	)
	if !apcore.is_ok(err) {
		apcore.log_error("%s", err.message)
		return exit_code_for(err.kind)
	}
	write_stdout(transmute([]byte)text)
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
