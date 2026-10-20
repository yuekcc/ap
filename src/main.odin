package ap

import "core:encoding/uuid"
import "core:fmt"
import "core:os"

main :: proc() {
	setup_console_utf8()
	opts, perr := parse_args(os.args)
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
		log_set_level(.Debug)
	} else if opts.verbose {
		log_set_level(.Info)
	} else {
		log_set_level(.Warn)
	}

	config_dir, cerr := default_config_dir(opts.config_dir)
	if !is_ok(cerr) {
		log_error(cerr.message)
		os.exit(int(Exit_Code.Usage))
	}
	if err := ensure_writable_dir(config_dir); !is_ok(err) {
		log_error(err.message)
		os.exit(int(Exit_Code.Usage))
	}
	settings, serr := load_settings(config_dir)
	if !is_ok(serr) {
		log_error(serr.message)
		os.exit(int(Exit_Code.Usage))
	}

	agent_name := "general"
	if value, ok := opts.agent.?; ok {
		agent_name = value
	}
	agent, aerr := load_agent(config_dir, agent_name)
	if !is_ok(aerr) {
		log_error(aerr.message)
		os.exit(int(Exit_Code.Usage))
	}

	model := settings.model
	if value, ok := opts.model.?; ok {
		model = value
	}
	max_steps := settings.max_steps
	if value, ok := opts.max_steps.?; ok {
		max_steps = value
	}
	max_tokens := settings.max_tokens
	if value, ok := opts.max_tokens.?; ok {
		max_tokens = value
	}
	agent_model_applies := opts.model == nil || opts.parent_session_id != nil
	agent_steps_applies := opts.max_steps == nil || opts.parent_session_id != nil
	if agent_model_applies {
		if value, ok := agent.model.?; ok {
			model = value
		}
	}
	if agent_steps_applies {
		if agent_steps_applies {
			if value, ok := agent.max_steps.?; ok {
				max_steps = value
			}
		}
	}
	effective_depth := 0
	if value, ok := opts.agent_depth.?; ok {
		effective_depth = value
	}

	cwd, cwderr := canonicalize_path(".", true)
	if !is_ok(cwderr) {
		log_error(cwderr.message)
		os.exit(int(Exit_Code.Usage))
	}
	project, jerr := open_project(config_dir, cwd)
	if !is_ok(jerr) {
		log_error(jerr.message)
		os.exit(int(Exit_Code.Usage))
	}
	bash_path, berr := find_bash()
	if !is_ok(berr) {
		log_error(berr.message)
		os.exit(int(Exit_Code.Usage))
	}
	self_exe := resolve_self_exe()

	prompt, prerr := read_prompt(opts, cwd)
	if !is_ok(prerr) {
		log_error(prerr.message)
		os.exit(int(Exit_Code.Usage))
	}

	store: Transcript_Store
	session_id := ""
	initial_session_line := ""
	var_events: []Event
	restoring := opts.session_id != nil || opts.continue_session

	if restoring {
		source_id := ""
		if value, ok := opts.session_id.?; ok {
			source_id = value
		} else {
			found, ferr := find_latest_root_session(project)
			if !is_ok(ferr) {
				log_error(ferr.message)
				os.exit(int(Exit_Code.Usage))
			}
			source_id = found
		}
		expected_path := session_file(project, source_id)
		if !os.exists(expected_path) {
			log_error(
				"session %q not found in project %s (expected %s)\nhint: run ap from the directory where the session was created",
				source_id,
				project.hash,
				expected_path,
			)
			os.exit(int(Exit_Code.Usage))
		}
		source_events, rerr := transcript_read_all(project, source_id)
		if !is_ok(rerr) {
			log_error(rerr.message)
			os.exit(int(Exit_Code.Usage))
		}
		if len(source_events) > 0 && source_events[len(source_events) - 1].type != "session_end" {
			log_warn("previous run of session %s did not write session_end; recovering after abnormal exit", source_id)
		}
		start, _, crerr := session_system_prompt(project, source_events)
		if !is_ok(crerr) {
			log_error(crerr.message)
			os.exit(int(Exit_Code.Usage))
		}

		model = start.model
		agent_name = start.agent_name
		effective_depth = start.agent_depth
		agent, aerr = load_agent(config_dir, agent_name)
		if !is_ok(aerr) {
			log_error(aerr.message)
			os.exit(int(Exit_Code.Usage))
		}
		if agent_steps_applies {
			if value, ok := agent.max_steps.?; ok {
				max_steps = value
			}
		}
		if opts.model != nil {
			if value, ok := opts.model.?; ok && value != start.model {
				log_warn("--model ignored on restore: session is frozen to %q", start.model)
			}
		}
		if opts.agent != nil {
			if value, ok := opts.agent.?; ok && value != start.agent_name {
				log_warn("--agent ignored on restore: session is frozen to %q", start.agent_name)
			}
		}
		if value, ok := opts.append_system_prompt.?; ok && len(value) > 0 {
			log_warn("--append-system-prompt ignored on restore")
		}
		if opts.parent_session_id != nil || opts.parent_tool_call_id != nil || opts.agent_depth != nil {
			log_warn("parent/agent-depth arguments ignored on restore")
		}

		if opts.fork_session {
			session_id = new_session_id()
			forked, ferr := fork_transcript(project, source_id, session_id, &settings)
			if !is_ok(ferr) {
				log_error(ferr.message)
				os.exit(int(Exit_Code.Usage))
			}
			store = forked
			effective_depth = 0
			h := make_header(&store, "session_start")
			ev := Session_Start_Event {
				header = h,
				session_id = session_id,
				content = start.content,
				role = "system",
				cwd = start.cwd,
				model = start.model,
				provider = start.provider,
				agent_name = start.agent_name,
				agent_depth = 0,
				parent_session_id = nil,
				parent_tool_call_id = nil,
				resumed_from = source_id,
				content_ref = start.content_ref,
				content_bytes = start.content_bytes,
			}
			line, err := transcript_append_line(&store, ev)
			if !is_ok(err) {
				log_error(err.message)
				os.exit(int(Exit_Code.Internal))
			}
			initial_session_line = line
			refreshed, reerr := transcript_read_all(project, session_id)
			if !is_ok(reerr) {
				log_error(reerr.message)
				os.exit(int(Exit_Code.Internal))
			}
			var_events = refreshed
		} else {
			resumed, rerr2 := resume_transcript_store(project, source_id, &settings)
			if !is_ok(rerr2) {
				log_error(rerr2.message)
				os.exit(int(Exit_Code.Usage))
			}
			store = resumed
			session_id = source_id
			h := make_header(&store, "session_start")
			ev := Session_Start_Event {
				header = h,
				session_id = source_id,
				content = start.content,
				role = "system",
				cwd = start.cwd,
				model = start.model,
				provider = start.provider,
				agent_name = start.agent_name,
				agent_depth = start.agent_depth,
				parent_session_id = start.parent_session_id,
				parent_tool_call_id = start.parent_tool_call_id,
				resumed_from = source_id,
				content_ref = start.content_ref,
				content_bytes = start.content_bytes,
			}
			line, err := transcript_append_line(&store, ev)
			if !is_ok(err) {
				log_error(err.message)
				os.exit(int(Exit_Code.Internal))
			}
			initial_session_line = line
			refreshed, reerr := transcript_read_all(project, source_id)
			if !is_ok(reerr) {
				log_error(reerr.message)
				os.exit(int(Exit_Code.Internal))
			}
			var_events = refreshed
		}
	} else {
		if opts.parent_session_id != nil {
			parent_id, _ := opts.parent_session_id.?
			parent_path := session_file(project, parent_id)
			if !os.exists(parent_path) {
				log_error("parent session %q not found (expected %s)", parent_id, parent_path)
				os.exit(int(Exit_Code.Usage))
			}
		}
		tool_section := tool_prompt_section(agent, effective_depth, settings.max_agent_depth)
		skill_section := skills_prompt_block(discover_skills(cwd))
		append_prompt := ""
		if value, ok := opts.append_system_prompt.?; ok {
			append_prompt = value
		}
		system_prompt := build_system_prompt(
			{
				cwd = cwd,
				config_dir = config_dir,
				agent = agent,
				append_prompt = append_prompt,
				tool_section = tool_section,
				skill_section = skill_section,
			},
		)
		session_id = new_session_id()
		created, cerr2 := new_transcript_store(project, session_id, &settings)
		if !is_ok(cerr2) {
			log_error(cerr2.message)
			os.exit(int(Exit_Code.Usage))
		}
		store = created

		stored_content := system_prompt
		var_ref: Maybe(string)
		var_bytes: Maybe(int)
		if len(system_prompt) > settings.blob_threshold_bytes {
			sha, blerr := blob_write(project, transmute([]byte)system_prompt)
			if !is_ok(blerr) {
				log_error(blerr.message)
				transcript_close(&store)
				os.exit(int(Exit_Code.Tool))
			}
			stored_content = ""
			var_ref = sha
			var_bytes = len(system_prompt)
		}
		h := make_header(&store, "session_start")
		ev := Session_Start_Event {
			header = h,
			session_id = session_id,
			content = stored_content,
			role = "system",
			cwd = project.root,
			model = model,
			provider = PROVIDER_NAME,
			agent_name = agent.name,
			agent_depth = effective_depth,
			parent_session_id = opts.parent_session_id,
			parent_tool_call_id = opts.parent_tool_call_id,
			resumed_from = nil,
			content_ref = var_ref,
			content_bytes = var_bytes,
		}
		line, err := transcript_append_line(&store, ev)
		if !is_ok(err) {
			log_error(err.message)
			transcript_close(&store)
			os.exit(int(Exit_Code.Internal))
		}
		initial_session_line = line
		refreshed, reerr := transcript_read_all(project, session_id)
		if !is_ok(reerr) {
			log_error(reerr.message)
			transcript_close(&store)
			os.exit(int(Exit_Code.Internal))
		}
		var_events = refreshed
	}

	cancel: Cancel_Token
	install_signal_handlers(&cancel)
	out := Output_State{format = opts.output_format}
	if out.format == .Stream_Json && len(initial_session_line) > 0 {
		write_stdout(transmute([]byte)initial_session_line)
		write_stdout(transmute([]byte)string("\n"))
	}
	emitter := make_loop_emitter(&out)
	loop := loop_init(
		project,
		&settings,
		&store,
		agent,
		model,
		config_dir,
		self_exe,
		bash_path,
		session_id,
		effective_depth,
		settings.max_agent_depth,
		max_steps,
		max_tokens,
		&cancel,
		var_events,
		emitter,
	)
	result := loop_run_turn(&loop, prompt)

	if result.exit_code == .OK && !result.cancelled && signal_exit_code() != 0 {
		result.cancelled = true
		result.stop_reason = "cancelled"
	}
	cleanup_jobs()
	reason := "exit"
	if result.cancelled {
		reason = "signal"
	} else if result.exit_code != .OK {
		reason = "error"
	}
	session_usage := result.session_usage
	if events_now, eerr := transcript_read_all(project, session_id); is_ok(eerr) {
		summed := historical_usage_from_events(events_now)
		if usage_has_any(summed) || !usage_has_any(result.session_usage) {
			session_usage = summed
		}
	}
	h_end := make_header(&store, "session_end")
	end_ev := Session_End_Event {
		header = h_end,
		reason = reason,
		usage = session_usage,
	}
	end_line, end_err := transcript_append_line(&store, end_ev)
	if !is_ok(end_err) {
		log_error(end_err.message)
		transcript_close(&store)
		os.exit(int(Exit_Code.Internal))
	}
	if out.format == .Stream_Json {
		write_stdout(transmute([]byte)end_line)
		write_stdout(transmute([]byte)string("\n"))
	}

	output_final(&out, session_id, result)
	exit_code := int(result.exit_code)
	if result.cancelled {
		signal_code := signal_exit_code()
		exit_code = signal_code if signal_code != 0 else 130
	}
	transcript_close(&store)
	loop_destroy(&loop)
	os.exit(exit_code)
}

list_skills :: proc() -> int {
	cwd, cerr := canonicalize_path(".", true)
	if !is_ok(cerr) {
		log_error(cerr.message)
		return int(Exit_Code.Usage)
	}
	text := skills_brief(discover_skills(cwd))
	write_stdout(transmute([]byte)text)
	return int(Exit_Code.OK)
}

new_session_id :: proc() -> string {
	id := uuid.generate_v4()
	return uuid.to_string(id, context.allocator)
}
