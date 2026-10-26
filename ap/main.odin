package ap

import "engine"
import "platform"
import "core:fmt"
import "core:os"

main :: proc() {
	setup_console_utf8()
	args := normalize_cli_args(os.args)
	opts, perr := parse_args(args)
	if !is_ok(perr) {
		log_error(perr.message)
		fmt.eprintln("hint: run ap --help for usage")
		os.exit(int(Exit_Code.Usage))
	}
	if opts.help {
		print_usage()
		os.exit(0)
	}
	if opts.version {
		fmt.printfln("ap %s", VERSION)
		os.exit(0)
	}
	if opts.list_skills {
		os.exit(list_skills())
	}
	if opts.debug {
		engine.log_set_level(.Debug)
	} else if opts.verbose {
		engine.log_set_level(.Info)
	} else {
		engine.log_set_level(.Warn)
	}

	config_dir, cerr := default_config_dir(opts.config_dir)
	exit_on_error(cerr, .Usage)
	exit_on_error(ensure_writable_dir(config_dir), .Usage)
	settings, serr := engine.load_settings(config_dir)
	exit_on_engine_error(serr)

	cwd, cwderr := canonicalize_path(".", true)
	exit_on_error(cwderr, .Usage)
	project, jerr := open_project(config_dir, cwd)
	exit_on_error(jerr, .Usage)
	bash_path, berr := find_bash()
	exit_on_error(berr, .Usage)
	self_exe := platform.resolve_self_exe()

	prompt := ""
	if !opts.print_system_prompt {
		value, prerr := read_prompt(opts, cwd)
		exit_on_error(prerr, .Usage)
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
		kind = kind,
		project = project,
		settings = &settings,
		config_dir = config_dir,
		cwd = cwd,
		self_exe = self_exe,
		bash_path = bash_path,
		source_session_id = source_id,
		model = opts.model,
		agent = opts.agent,
		max_steps = opts.max_steps,
		max_tokens = opts.max_tokens,
		append_system_prompt = opts.append_system_prompt,
		agent_depth = opts.agent_depth,
		parent_session_id = opts.parent_session_id,
		parent_tool_call_id = opts.parent_tool_call_id,
	}

	if opts.print_system_prompt {
		info, ierr := engine.preview_prompt(req)
		exit_on_engine_error(ierr)
		print_system_prompt(info.system_prompt)
	}

	session, info, oerr := engine.session_open(req)
	if !engine.is_ok(oerr) {
		exit_on_engine_error(oerr)
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
		_, _ = engine.session_close(&session, {reason = "error", usage = {}})
		os.exit(int(Exit_Code.Internal))
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
		os.exit(int(Exit_Code.Internal))
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
	if len(args) > 0 {
		fmt.eprintf("继续对话，请执行：%s -s %s\n", args[0], session.session_id)
	}
	os.exit(exit_code)
}

list_skills :: proc() -> int {
	cwd, cerr := canonicalize_path(".", true)
	if !is_ok(cerr) {
		log_error(cerr.message)
		return int(Exit_Code.Usage)
	}
	text := engine.skills_brief(engine.discover_skills(cwd))
	write_stdout(transmute([]byte)text)
	return int(Exit_Code.OK)
}

// 打印 system prompt 后直接退出，不创建 session、不调用模型。
print_system_prompt :: proc(text: string) {
	write_stdout(transmute([]byte)text)
	if len(text) == 0 || text[len(text) - 1] != '\n' {
		write_stdout(transmute([]byte)string("\n"))
	}
	os.exit(int(Exit_Code.OK))
}

exit_on_error :: proc(err: Error, code: Exit_Code) {
	if !is_ok(err) {
		log_error(err.message)
		os.exit(int(code))
	}
}

exit_on_engine_error :: proc(err: engine.Error) {
	if !engine.is_ok(err) {
		log_error(err.message)
		os.exit(exit_code_for(err.kind))
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
