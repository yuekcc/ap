package magicli

import apcore "../ap-core"
import platform "../ap-core/platform"

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

// magi-cli 的组装根：解析请求 → 打开 SDK Env → 三名成员各自跑一个隔离 session →
// 纯函数聚合 → 输出决议。SDK 不读 argv/settings，这些都在这里完成。

VERSION :: "0.1.0"

Exit_Code :: enum int {
	OK       = 0,
	Internal = 1,
	Usage    = 2,
	Member   = 3,
}

log_mu: sync.Mutex

magi_log :: proc(format: string, args: ..any) {
	sync.mutex_lock(&log_mu)
	defer sync.mutex_unlock(&log_mu)
	fmt.eprintf("magi: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
}

write_stdout :: proc(data: []byte) -> bool {
	return platform.write_all(os.stdout, data)
}

run :: proc(args: []string) -> int {
	platform.setup_console()
	normalized := platform.normalize_args(args)
	opts, perr := parse_args(normalized)
	if !apcore.is_ok(perr) {
		magi_log("%s", perr.message)
		magi_log("hint: run magi-cli --help for usage")
		return int(Exit_Code.Usage)
	}
	if opts.help {
		print_usage()
		return int(Exit_Code.OK)
	}
	if opts.version {
		fmt.printfln("magi-cli %s", VERSION)
		return int(Exit_Code.OK)
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
		magi_log("%s", cerr.message)
		return int(Exit_Code.Usage)
	}
	cwd, cwderr := platform.canonicalize_path(".", true)
	if !platform.is_ok(cwderr) {
		magi_log("%s", cwderr.message)
		return int(Exit_Code.Usage)
	}

	request, rerr := read_request(opts, cwd)
	if !apcore.is_ok(rerr) {
		magi_log("%s", rerr.message)
		return int(Exit_Code.Usage)
	}

	loaded, serr := load_settings(config_dir)
	if !apcore.is_ok(serr) {
		magi_log("%s", serr.message)
		return exit_code_for(serr.kind)
	}
	settings := loaded.sdk
	if opts.model != nil {
		value, _ := opts.model.?
		if len(value) == 0 {
			magi_log("--model must not be empty")
			return int(Exit_Code.Usage)
		}
		settings.model = value
	}
	if opts.max_tokens != nil {
		value, _ := opts.max_tokens.?
		settings.max_tokens = value
	}

	// 三个成员都不需要工具：输入只有问题和材料，避免投票过程产生副作用。
	env, eerr := apcore.env_open({
		config_dir = config_dir,
		cwd        = cwd,
		settings   = settings,
		tools      = nil,
	})
	if !apcore.is_ok(eerr) {
		magi_log("%s", eerr.message)
		return exit_code_for(eerr.kind)
	}

	cancel: apcore.Cancel_Token
	install_signal_handlers(&cancel)

	if opts.verbose {
		magi_log("进入 MAGI 投票：%d 名成员，model=%s", len(MEMBER_ROLES), env.settings.model)
	}
	votes := run_members(&env, request, &cancel, opts.verbose)

	if code := signal_exit_code(); code != 0 {
		magi_log("投票被中断")
		return code
	}

	decision := decide(votes)
	if opts.output_format == .Text {
		text := format_text_decision(decision)
		write_stdout(transmute([]byte)text)
		if !strings.has_suffix(text, "\n") {
			write_stdout(transmute([]byte)string("\n"))
		}
	} else {
		data, ok := marshal_decision(decision)
		if !ok {
			magi_log("cannot serialize decision")
			return int(Exit_Code.Internal)
		}
		write_stdout(data)
		write_stdout(transmute([]byte)string("\n"))
	}

	for vote in votes {
		if vote.status != "ok" {
			return int(Exit_Code.Member)
		}
	}
	return int(Exit_Code.OK)
}

Member_Job :: struct {
	env:     ^apcore.Env,
	role:    Member_Role,
	request: Magi_Request,
	cancel:  ^apcore.Cancel_Token,
	verbose: bool,
	vote:    ^Member_Vote,
}

member_thread_main :: proc(data: rawptr) {
	job := (^Member_Job)(data)
	vote := run_member(job.env, job.role, job.request, job.cancel, job.verbose)
	// 成员线程退出后 temp allocator 可能失效；把会带出线程的字符串复制到堆上。
	job.vote^ = Member_Vote {
		agent       = strings.clone(vote.agent, context.allocator),
		veto        = vote.veto,
		reason      = strings.clone(vote.reason, context.allocator),
		status      = strings.clone(vote.status, context.allocator),
		session_id  = strings.clone(vote.session_id, context.allocator),
		stop_reason = strings.clone(vote.stop_reason, context.allocator),
	}
}

// 三名成员并行。每个成员只写自己的 vote 槽位；Env 在投票期间只读。
// libcurl 的全局初始化在 provider 内串行化，见 engine/provider.odin。
run_members :: proc(
	env: ^apcore.Env,
	request: Magi_Request,
	cancel: ^apcore.Cancel_Token,
	verbose: bool,
) -> []Member_Vote {
	votes := make([]Member_Vote, len(MEMBER_ROLES))
	jobs := make([]Member_Job, len(MEMBER_ROLES))
	handles := make([]^thread.Thread, len(MEMBER_ROLES))

	for role, i in MEMBER_ROLES {
		votes[i] = Member_Vote {
			agent  = role.id,
			status = "error",
			reason = "not started",
		}
		jobs[i] = Member_Job {
			env     = env,
			role    = role,
			request = request,
			cancel  = cancel,
			verbose = verbose,
			vote    = &votes[i],
		}
		handles[i] = thread.create_and_start_with_data(&jobs[i], member_thread_main)
	}

	for handle, i in handles {
		if handle != nil {
			thread.join(handle)
			thread.destroy(handle)
		} else {
			// 线程创建失败时退化为同步执行，至少不丢投票。
			member_thread_main(&jobs[i])
		}
	}
	return votes
}

run_member :: proc(
	env: ^apcore.Env,
	role: Member_Role,
	request: Magi_Request,
	cancel: ^apcore.Cancel_Token,
	verbose: bool,
) -> Member_Vote {
	vote := Member_Vote {
		agent  = role.id,
		status = "error",
		veto   = true,
	}
	base_prompt := build_base_prompt(role)
	session, info, oerr := apcore.session_open(
		env,
		{
			kind = .New,
			agent_name = role.agent_name,
			model = env.settings.model,
			max_steps = 1,
			max_tokens = env.settings.max_tokens,
			base_system_prompt = base_prompt,
			tools = make([]string, 0),
		},
	)
	if !apcore.is_ok(oerr) {
		vote.reason = oerr.message
		vote.stop_reason = "session_open"
		magi_log("%s 无法启动 session：%s", role.id, oerr.message)
		return vote
	}
	vote.session_id = session.session_id
	for warning in info.warnings {
		magi_log("%s: %s", role.id, warning)
	}
	if verbose {
		magi_log("%s 开始投票（session %s）", role.id, session.session_id)
	}

	result: apcore.Turn_Result
	close_reason := "exit"
	defer {
		_, close_err := apcore.session_close(
			&session,
			{reason = close_reason, usage = result.session_usage},
		)
		if !apcore.is_ok(close_err) {
			magi_log("%s 关闭 session 失败：%s", role.id, close_err.message)
		}
	}

	turn_result, terr := apcore.turn_run(
		&session,
		build_member_prompt(role.id, request.question, request.material),
		cancel,
		{},
	)
	result = turn_result
	if !apcore.is_ok(terr) {
		close_reason = "error"
		vote.reason = terr.message
		vote.stop_reason = "turn_run"
		magi_log("%s 投票失败：%s", role.id, terr.message)
		return vote
	}
	if result.cancelled {
		close_reason = "signal"
		vote.reason = "投票被取消"
		vote.stop_reason = "cancelled"
		return vote
	}
	if result.error_kind != .None {
		close_reason = "error"
		vote.reason = result.fatal_error
		vote.stop_reason = result.stop_reason
		magi_log("%s 投票失败：%s", role.id, vote.reason)
		return vote
	}

	parsed, ok := parse_vote_response(result.result_text)
	if !ok && verbose {
		magi_log("%s 输出不是合法投票 JSON，发起一次修复轮", role.id)
	}
	if !ok {
		repair_result, rerr := apcore.turn_run(&session, REPAIR_PROMPT, cancel, {})
		result = repair_result
		if !apcore.is_ok(rerr) {
			close_reason = "error"
			vote.reason = rerr.message
			vote.stop_reason = "repair_turn"
			magi_log("%s 修复轮失败：%s", role.id, rerr.message)
			return vote
		}
		if result.cancelled {
			close_reason = "signal"
			vote.reason = "投票被取消"
			vote.stop_reason = "cancelled"
			return vote
		}
		if result.error_kind != .None {
			close_reason = "error"
			vote.reason = result.fatal_error
			vote.stop_reason = result.stop_reason
			magi_log("%s 修复轮失败：%s", role.id, vote.reason)
			return vote
		}
		parsed, ok = parse_vote_response(result.result_text)
	}

	if !ok {
		vote.reason = fmt.aprintf(
			"无法解析投票 JSON（stop_reason=%s）：%s",
			result.stop_reason,
			excerpt(result.result_text, 200),
		)
		vote.stop_reason = result.stop_reason
		magi_log("%s 投票无效：%s", role.id, vote.reason)
		return vote
	}

	vote.status = "ok"
	vote.veto = parsed.veto
	vote.reason = parsed.reason
	vote.stop_reason = result.stop_reason
	if verbose {
		verdict := "否决" if parsed.veto else "通过"
		magi_log("%s 完成：%s", role.id, verdict)
	}
	return vote
}

excerpt :: proc(text: string, rune_limit: int) -> string {
	if rune_limit <= 0 {
		return ""
	}
	b := strings.builder_make()
	count := 0
	for ch in text {
		if count >= rune_limit {
			strings.write_string(&b, "…")
			break
		}
		strings.write_rune(&b, ch)
		count += 1
	}
	return strings.trim_space(strings.to_string(b))
}

exit_code_for :: proc(kind: apcore.Error_Kind) -> int {
	switch kind {
	case .None:
		return int(Exit_Code.OK)
	case .Usage:
		return int(Exit_Code.Usage)
	case .Provider:
		return int(Exit_Code.Member)
	case .Tool:
		return int(Exit_Code.Member)
	case .Internal:
		return int(Exit_Code.Internal)
	}
	return int(Exit_Code.Internal)
}
