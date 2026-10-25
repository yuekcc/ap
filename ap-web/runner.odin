package main

import "../internal"
import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// turn runner：同一时刻至多一个 ap 子进程（单飞）。HTTP handler 只负责
// 校验参数与抢锁，真正的 spawn/泵事件在独立线程里跑，SSE 连接断开不影响 turn。
// 进程模型与 docs/web.md「Turn 生命周期」一致。

// 一轮 turn 的 API 入参。字符串由调用方持有，runner_start_turn 会克隆。
Turn_Request :: struct {
	prompt:     string,
	model:      Maybe(string),
	agent:      Maybe(string),
	max_steps:  Maybe(int),
	max_tokens: Maybe(int),
}

Runner_Start :: enum {
	Started,
	Busy, // 已有 turn 在跑（API 映射 409 turn_running）
	Shutting_Down, // 服务正在退出，不再接受新 turn
	Failed, // 线程创建失败等内部错误
}

// 运行中 turn 的取消信号。token 常驻 runner，每轮开始清零；
// DELETE /api/turn 在连接线程里置位，泵在轮询点检查。
Runner :: struct {
	mu:         sync.Mutex,
	running:    bool,
	exiting:    bool,
	session_id: string, // 当前 session 指针（拥有）
	turn:       Maybe(int), // 最近一次 turn_start/turn_end 的 turn 号
	cancel:     Agent_Cancel_Token,
	job:        ^Turn_Job,
}

// 一轮 turn 的私有上下文。所有字符串都由本结构拥有，线程退出时释放。
Turn_Job :: struct {
	app:          ^App,
	options:      Turn_Options,
	prompt:       string,
	stop_reason:  string, // 最后一条 turn_end.stop_reason
	session_end:  string, // 最后一条 session_end.reason（turn_end 缺失时兜底）
	usage:        internal.Usage,
	have_usage:   bool,
}

runner_init :: proc(app: ^App) {
	app.runner.mu = {}
	app.runner.running = false
	app.runner.exiting = false
	app.runner.session_id = ""
	app.runner.turn = nil
	app.runner.cancel = {}
	app.runner.job = nil
}

runner_running :: proc(app: ^App) -> bool {
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)
	return app.runner.running
}

// 当前 session 指针的副本；调用方负责 delete。空字符串表示「下一条提示新建」。
// 返回值走调用方 allocator，因为 runner 状态本身可能被另一线程改写。
runner_session :: proc(app: ^App, allocator := context.allocator) -> string {
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)
	if len(app.runner.session_id) == 0 {
		return ""
	}
	return strings.clone(app.runner.session_id, allocator)
}

// runner 状态会跨线程访问（HTTP 线程写、turn 线程读/写），所以内部字符串
// 一律用堆分配；测试里的 context.allocator 是按测试任务回收的 arena，
// 在另一个线程释放会崩。
runner_set_session :: proc(app: ^App, session_id: string) {
	cloned := strings.clone(session_id, runtime.heap_allocator())
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)
	if len(app.runner.session_id) > 0 {
		delete(app.runner.session_id, runtime.heap_allocator())
	}
	app.runner.session_id = cloned
}

runner_clear_session :: proc(app: ^App) {
	runner_set_session(app, "")
}

runner_turn :: proc(app: ^App) -> Maybe(int) {
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)
	return app.runner.turn
}

runner_set_turn :: proc(app: ^App, turn: int) {
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)
	app.runner.turn = turn
}

// 启动一轮 turn。锁只覆盖状态切换与 session 快照，spawn 在锁外进行。
runner_start_turn :: proc(app: ^App, request: Turn_Request) -> (status: Runner_Start, message: string) {
	sync.mutex_lock(&app.runner.mu)
	if app.runner.exiting {
		sync.mutex_unlock(&app.runner.mu)
		return .Shutting_Down, "server is shutting down"
	}
	if app.runner.running {
		sync.mutex_unlock(&app.runner.mu)
		return .Busy, "a turn is already running"
	}
	app.runner.running = true
	app.runner.turn = nil
	sync.atomic_store(&app.runner.cancel.value, 0)
	session_snapshot := ""
	if len(app.runner.session_id) > 0 {
		session_snapshot = strings.clone(app.runner.session_id, runtime.heap_allocator())
	}
	sync.mutex_unlock(&app.runner.mu)

	job := new(Turn_Job, runtime.heap_allocator())
	job^ = Turn_Job {
		app = app,
		options = {
			agent_bin = app.agent_bin,
			session_id = session_snapshot,
			config_dir = app.config_dir,
			cwd = app.project.root,
			model = clone_maybe_string(request.model),
			agent = clone_maybe_string(request.agent),
			max_steps = request.max_steps,
			max_tokens = request.max_tokens,
			cancel = &app.runner.cancel,
		},
		prompt = strings.clone(request.prompt, runtime.heap_allocator()),
	}

	handle := thread.create_and_start_with_data(rawptr(job), runner_thread, name = "turn-runner")
	if handle == nil {
		free_job(job)
		sync.mutex_lock(&app.runner.mu)
		app.runner.running = false
		app.runner.job = nil
		sync.mutex_unlock(&app.runner.mu)
		return .Failed, "cannot start turn thread"
	}

	sync.mutex_lock(&app.runner.mu)
	app.runner.job = job
	sync.mutex_unlock(&app.runner.mu)
	return .Started, ""
}

// DELETE /api/turn：置位取消 token，泵会终止整棵进程树。
runner_cancel :: proc(app: ^App) -> bool {
	sync.mutex_lock(&app.runner.mu)
	running := app.runner.running
	sync.mutex_unlock(&app.runner.mu)
	if !running {
		return false
	}
	agent_cancel_token_cancel(&app.runner.cancel)
	return true
}

// 进程退出时收尾：拒绝新 turn、终止运行中的 turn，并最多等 5s。
runner_shutdown :: proc(app: ^App) {
	sync.mutex_lock(&app.runner.mu)
	app.runner.exiting = true
	running := app.runner.running
	sync.mutex_unlock(&app.runner.mu)
	if !running {
		return
	}
	agent_cancel_token_cancel(&app.runner.cancel)
	start := time.tick_now()
	for runner_running(app) && time.tick_since(start) < 5 * time.Second {
		time.sleep(10 * time.Millisecond)
	}
}

clone_maybe_string :: proc(value: Maybe(string)) -> Maybe(string) {
	if text, ok := value.?; ok {
		return strings.clone(text, runtime.heap_allocator())
	}
	return nil
}

free_maybe_string :: proc(value: Maybe(string)) {
	if text, ok := value.?; ok {
		delete(text, runtime.heap_allocator())
	}
}

free_job :: proc(job: ^Turn_Job) {
	if len(job.options.session_id) > 0 {
		delete(job.options.session_id, runtime.heap_allocator())
	}
	free_maybe_string(job.options.model)
	free_maybe_string(job.options.agent)
	if len(job.prompt) > 0 {
		delete(job.prompt, runtime.heap_allocator())
	}
	if len(job.stop_reason) > 0 {
		delete(job.stop_reason, runtime.heap_allocator())
	}
	if len(job.session_end) > 0 {
		delete(job.session_end, runtime.heap_allocator())
	}
	free(job, runtime.heap_allocator())
}

// 每个 stdout 事件：原始行广播 + 记录 session 指针与 turn_done 需要的信息。
runner_on_event_line :: proc(user: rawptr, ev: Event, line: string) {
	job := (^Turn_Job)(user)
	app := job.app

	forwarded := line
	if strings.has_suffix(forwarded, "\r") {
		forwarded = forwarded[:len(forwarded) - 1]
	}
	if len(forwarded) > 0 {
		_ = sse_hub_broadcast(&app.hub, "ap", forwarded)
	}

	switch ev.type {
	case "session_start":
		if len(ev.session_id) > 0 {
			runner_set_session(app, ev.session_id)
		}
	case "turn_start", "turn_end":
		if ev.turn > 0 {
			runner_set_turn(app, ev.turn)
		}
	case "session_end":
		if len(ev.reason) > 0 {
			if len(job.session_end) > 0 {
				delete(job.session_end, runtime.heap_allocator())
			}
			job.session_end = strings.clone(ev.reason, runtime.heap_allocator())
		}
	}

	if ev.type == "turn_end" {
		if len(ev.stop_reason) > 0 {
			if len(job.stop_reason) > 0 {
				delete(job.stop_reason, runtime.heap_allocator())
			}
			job.stop_reason = strings.clone(ev.stop_reason, runtime.heap_allocator())
		}
		if usage_has_values(ev.usage) {
			job.usage = ev.usage
			job.have_usage = true
		}
	} else if ev.type == "session_end" && !job.have_usage && usage_has_values(ev.usage) {
		job.usage = ev.usage
		job.have_usage = true
	}
}

usage_has_values :: proc(usage: internal.Usage) -> bool {
	return usage.input_tokens != nil ||
	       usage.output_tokens != nil ||
	       usage.cached_tokens != nil ||
	       usage.reasoning_tokens != nil ||
	       usage.total_tokens != nil
}

runner_stop_reason :: proc(job: ^Turn_Job) -> Maybe(string) {
	if len(job.stop_reason) > 0 {
		return job.stop_reason
	}
	if len(job.session_end) > 0 {
		return job.session_end
	}
	return nil
}

// turn 线程：spawn ap → 泵事件（回调里广播）→ 广播 turn_done → 交还单飞锁。
runner_thread :: proc(user: rawptr) {
	job := (^Turn_Job)(user)
	app := job.app

	callbacks := Turn_Callbacks {
		user          = rawptr(job),
		on_event_line = runner_on_event_line,
	}
	result := run_agent_turn(job.options, job.prompt, callbacks)

	// 泵内部也从最后一条 session_start 捕获；这里兜底并保证指针是最新的。
	if len(result.session_id) > 0 {
		runner_set_session(app, result.session_id)
	}

	done := Sse_Turn_Done {
		exit_code = result.exit_code,
		stop_reason = runner_stop_reason(job),
		usage = job.usage,
	}
	if len(result.stderr_preview) > 0 {
		done.stderr_preview = result.stderr_preview
	}
	data := sse_turn_done_json(done, runtime.heap_allocator())
	_ = sse_hub_broadcast(&app.hub, "turn_done", data)
	delete(data)

	if len(result.session_id) > 0 {
		delete(result.session_id, runtime.heap_allocator())
	}
	if len(result.stderr_preview) > 0 {
		delete(result.stderr_preview, runtime.heap_allocator())
	}

	sync.mutex_lock(&app.runner.mu)
	app.runner.running = false
	app.runner.job = nil
	sync.mutex_unlock(&app.runner.mu)
	free_job(job)
}

// ---------------------------------------------------------------------------
// SSE 心跳
// ---------------------------------------------------------------------------

// 后台线程按 SSE_HEARTBEAT_INTERVAL 发 `: ping` + ping 事件。hub 自己没有
// 线程，节拍由这里驱动；分片睡眠，停止时最多等一小段。
HEARTBEAT_POLL_INTERVAL :: SSE_HEARTBEAT_INTERVAL / 15

Heartbeat_State :: struct {
	hub:   ^Sse_Hub,
	stop:  i32,
	timer: time.Tick,
}

heartbeat_start :: proc(state: ^Heartbeat_State, hub: ^Sse_Hub) {
	state^ = {
		hub   = hub,
		stop  = 0,
		timer = time.tick_now(),
	}
	_ = thread.create_and_start_with_data(rawptr(state), heartbeat_thread, self_cleanup = true, name = "sse-heartbeat")
}

heartbeat_stop :: proc(state: ^Heartbeat_State) {
	if state.hub == nil {
		return
	}
	sync.atomic_store(&state.stop, 1)
}

heartbeat_thread :: proc(user: rawptr) {
	state := (^Heartbeat_State)(user)
	for sync.atomic_load(&state.stop) == 0 {
		time.sleep(HEARTBEAT_POLL_INTERVAL)
		if sync.atomic_load(&state.stop) != 0 {
			break
		}
		if time.tick_since(state.timer) >= SSE_HEARTBEAT_INTERVAL {
			state.timer = time.tick_now()
			_ = sse_hub_heartbeat(state.hub, time.time_to_unix(time.now()))
		}
	}
}
