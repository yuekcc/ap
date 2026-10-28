package apcore

import "engine"
import "platform"
import "core:fmt"

// CLI adapter：参数、配置入口、输出格式、退出码、信号。
// agent 实现全部在 ap-core/engine；这里只做编排。

run :: proc(args: []string) -> int {
	platform.setup_console()
	normalized := platform.normalize_args(args)
	opts, perr := parse_args(normalized)
	if !is_ok(perr) {
		log_error(perr.message)
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
		engine.log_set_level(.Debug)
	} else if opts.verbose {
		engine.log_set_level(.Info)
	} else {
		engine.log_set_level(.Warn)
	}

	config_dir, cerr := platform.default_config_dir(opts.config_dir)
	if !platform.is_ok(cerr) {
		log_error(cerr.message)
		return int(Exit_Code.Usage)
	}
	if err := platform.ensure_writable_dir(config_dir); !platform.is_ok(err) {
		log_error(err.message)
		return int(Exit_Code.Usage)
	}
	settings, serr := engine.load_settings(config_dir)
	if !engine.is_ok(serr) {
		engine.log_error(serr.message)
		return exit_code_for(serr.kind)
	}

	cwd, cwderr := platform.canonicalize_path(".", true)
	if !platform.is_ok(cwderr) {
		log_error(cwderr.message)
		return int(Exit_Code.Usage)
	}
	project, jerr := platform.open_project(config_dir, cwd)
	if !platform.is_ok(jerr) {
		log_error(jerr.message)
		return int(Exit_Code.Usage)
	}
	bash_path, berr := platform.find_bash()
	if !platform.is_ok(berr) {
		log_error(berr.message)
		return int(Exit_Code.Usage)
	}
	self_exe := platform.resolve_self_exe()

	prompt := ""
	if !opts.print_system_prompt {
		value, prerr := read_prompt(opts, cwd)
		if !is_ok(prerr) {
			log_error(prerr.message)
			return int(Exit_Code.Usage)
		}
		prompt = value
	}

	kind := engine.Session_Kind.New
	if opts.session_id != nil || opts.continue_session {
		kind = .Fork if opts.fork_session else .Resume
	}
	source_id := ""
	if value, ok := opts.session_id.?; ok {
		source_id = value
	}
	req := engine.Session_Request {
		kind                 = kind,
		project              = project,
		settings             = &settings,
		config_dir           = config_dir,
		cwd                  = cwd,
		self_exe             = self_exe,
		bash_path            = bash_path,
		source_session_id    = source_id,
		model                = opts.model,
		agent                = opts.agent,
		max_steps            = opts.max_steps,
		max_tokens           = opts.max_tokens,
		append_system_prompt = opts.append_system_prompt,
		agent_depth          = opts.agent_depth,
		parent_session_id    = opts.parent_session_id,
		parent_tool_call_id  = opts.parent_tool_call_id,
	}

	if opts.print_system_prompt {
		info, ierr := engine.preview_prompt(req)
		if !engine.is_ok(ierr) {
			engine.log_error(ierr.message)
			return exit_code_for(ierr.kind)
		}
		print_system_prompt_text(info.system_prompt)
		return int(Exit_Code.OK)
	}

	session, info, oerr := engine.session_open(req)
	if !engine.is_ok(oerr) {
		engine.log_error(oerr.message)
		return exit_code_for(oerr.kind)
	}
	for warning in info.warnings {
		engine.log_warn("%s", warning)
	}

	cancel: platform.Cancel_Token
	install_signal_handlers(&cancel)
	out := Output_State{format = opts.output_format}
	if out.format == .Stream_Json && len(info.initial_line) > 0 {
		write_stdout(transmute([]byte)info.initial_line)
		write_stdout(transmute([]byte)string("\n"))
	}
	emitter := make_loop_emitter(&out)
	result, terr := engine.turn_run(&session, prompt, &cancel, emitter)
	if !engine.is_ok(terr) {
		engine.log_error(terr.message)
		err_end_line, _ := engine.session_close(&session, {reason = "error", usage = {}})
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
	end_line, end_err := engine.session_close(
		&session,
		{
			cancelled = result.cancelled,
			reason = reason,
			usage = result.session_usage,
		},
	)
	if !engine.is_ok(end_err) {
		engine.log_error(end_err.message)
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
		fmt.eprintf("继续对话，请执行：%s -s %s\n", normalized[0], session.session_id)
	}
	return exit_code
}

list_skills :: proc() -> int {
	cwd, cerr := platform.canonicalize_path(".", true)
	if !platform.is_ok(cerr) {
		log_error(cerr.message)
		return int(Exit_Code.Usage)
	}
	text := engine.skills_brief(engine.discover_skills(cwd))
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

exit_code_for :: proc(kind: engine.Error_Kind) -> int {
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
