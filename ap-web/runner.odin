package main

import protocol "../ap/protocol"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// turn runner：按 session 分飞。同一个 session 同一时刻至多一个 ap 子进程，
// 不同 session 可以并发（多标签页各跑各的）。HTTP handler 只负责校验参数
// 与抢对应 session 的锁，真正的 spawn/泵事件在独立线程里跑，SSE 连接断开
// 不影响 turn。进程模型与 docs/web.md「Turn 生命周期」一致。

// 一轮 turn 的 API 入参。字符串由调用方持有，runner_start_turn 会克隆。
Turn_Request :: struct {
	prompt:      string,
	session_key: string, // 空 = 使用当前 session（没有则新建 slot）
	cwd:         string, // 该 session 所属 working directory（空 = 当前/默认 project）
	model:       Maybe(string),
	agent:       Maybe(string),
	max_steps:   Maybe(int),
	max_tokens:  Maybe(int),
}

Runner_Start :: enum {
	Started,
	Busy, // 该 session 已有 turn 在跑（API 映射 409 turn_running）
	Shutting_Down, // 服务正在退出，不再接受新 turn
	Failed, // 线程创建失败等内部错误
}

// 新会话在 ap 生成真实 session id 之前也需要一个稳定标识：客户端用这个
// slot key 订阅 SSE、发起取消；session_start 之后再把它别名到真实 id。
WEB_SLOT_PREFIX :: "web_new_"

// 一个 session 的运行态。字符串全部堆分配，因为会在多个连接线程与 turn
// 线程之间共享；只有 registry 锁内可以改写。
Session_Runtime :: struct {
	key:        string, // 客户端订阅/调用使用的稳定 key（新会话是 slot）
	session_id: string, // ap 的真实 session id；新会话首轮之前为空
	cwd:        string, // 该 session 所属 project 的根目录（工作目录）
	running:    bool,
	turn:       Maybe(int), // 最近一次 turn_start/turn_end 的 turn 号
	cancel:     Agent_Cancel_Token,
	// 已结束但还没回收的 turn 线程句柄。同一 session 下一轮开始前或关停时
	// join + destroy，否则每轮都会泄漏 Thread 结构体与平台线程句柄。
	thread:     ^thread.Thread,
}

// 所有 session 运行态的注册表。线性数组足够：同时打开的 session 是个位数。
Runner :: struct {
	mu:       sync.Mutex,
	sessions: [dynamic]^Session_Runtime,
	current:  string, // 最近活跃的 key，用于 /api/session/current 的默认值（拥有）
	exiting:  bool,
	slots:    u64,
}

// 一轮 turn 的私有上下文。所有字符串都由本结构拥有，线程退出时释放。
Turn_Job :: struct {
	app:          ^App,
	key:          string, // Session_Runtime.key（owner）
	session_id:   string, // 当前已知的真实 session id（owner，session_start 后更新）
	options:      Turn_Options,
	prompt:       string,
	stop_reason:  string, // 最后一条 turn_end.stop_reason
	session_end:  string, // 最后一条 session_end.reason（turn_end 缺失时兜底）
	usage:        protocol.Usage,
	have_usage:   bool,
}

Runner_State :: struct {
	key:        string,
	session_id: string,
	cwd:        string,
	running:    bool,
	turn:       Maybe(int),
}

runner_init :: proc(app: ^App) {
	app.runner.mu = {}
	app.runner.sessions = make([dynamic]^Session_Runtime, 0, 4, runtime.heap_allocator())
	app.runner.current = ""
	app.runner.exiting = false
	app.runner.slots = 0
}

// 回收某个 session 已结束的 turn 线程。调用方必须持有 registry.mu，且该
// session 的 running 已为 false（turn 线程在退出前会先把 running 置回 false，
// 随后只剩 free_job 与返回，不再获取 registry.mu，所以持锁 join 不会死锁）。
runner_reap_thread_locked :: proc(rt: ^Session_Runtime) {
	handle := rt.thread
	if handle == nil {
		return
	}
	rt.thread = nil
	thread.join(handle)
	thread.destroy(handle)
}

// 调用方持有 registry.mu。key 可以是 slot key，也可以是真实 session id。
runner_find_locked :: proc(app: ^App, key: string) -> ^Session_Runtime {
	if len(key) == 0 {
		return nil
	}
	for rt in app.runner.sessions {
		if rt.key == key {
			return rt
		}
	}
	for rt in app.runner.sessions {
		if len(rt.session_id) > 0 && rt.session_id == key {
			return rt
		}
	}
	return nil
}

runner_set_current_locked :: proc(app: ^App, key: string) {
	if app.runner.current == key {
		return
	}
	if len(app.runner.current) > 0 {
		delete(app.runner.current, runtime.heap_allocator())
	}
	app.runner.current = strings.clone(key, runtime.heap_allocator())
}

// 调用方持有 registry.mu：分配一个新的 pending slot 并设为当前。
// cwd 决定这个 slot 属于哪个 project；ap-web 不再有全局「当前目录」。
runner_create_slot_locked :: proc(app: ^App, cwd: string) -> ^Session_Runtime {
	app.runner.slots += 1
	rt := new(Session_Runtime, runtime.heap_allocator())
	rt^ = {
		key = fmt.aprintf("%s%d", WEB_SLOT_PREFIX, app.runner.slots, allocator = runtime.heap_allocator()),
		cwd = strings.clone(cwd, runtime.heap_allocator()),
	}
	append(&app.runner.sessions, rt)
	runner_set_current_locked(app, rt.key)
	return rt
}

// 调用方持有 registry.mu。空 key 表示「当前 session」（没有就新建 slot）；
// 带 WEB_SLOT_PREFIX 但未知的 key（例如 ap-web 重启后的旧 slot）也按
// 「尚未落盘的新会话」处理，避免把内部 key 当成 session id 传给 ap。
// 其他 key 视为真实 session id。显式 cwd 会覆盖已有运行态的目录。
runner_ensure_locked :: proc(app: ^App, key, cwd: string) -> ^Session_Runtime {
	effective := key if len(key) > 0 else app.runner.current
	if rt := runner_find_locked(app, effective); rt != nil {
		// 运行中的 session 目录已由当前 job 固定，不能在 turn 中途改写。
		if !rt.running && len(cwd) > 0 && rt.cwd != cwd {
			if len(rt.cwd) > 0 {
				delete(rt.cwd, runtime.heap_allocator())
			}
			rt.cwd = strings.clone(cwd, runtime.heap_allocator())
		}
		runner_set_current_locked(app, rt.key)
		return rt
	}
	if len(key) == 0 {
		return runner_create_slot_locked(app, cwd)
	}
	rt := new(Session_Runtime, runtime.heap_allocator())
	rt^ = {
		key = strings.clone(key, runtime.heap_allocator()),
		cwd = strings.clone(cwd, runtime.heap_allocator()),
	}
	if !strings.has_prefix(key, WEB_SLOT_PREFIX) {
		rt.session_id = strings.clone(key, runtime.heap_allocator())
	}
	append(&app.runner.sessions, rt)
	runner_set_current_locked(app, rt.key)
	return rt
}

runner_initialized :: proc(app: ^App) -> bool {
	return app.runner.sessions != nil
}

// 新建一个尚未落盘的 session slot，返回客户端要用的 key（调用方 allocator）。
runner_session_new :: proc(app: ^App, cwd: string, allocator := context.allocator) -> string {
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)
	if !runner_initialized(app) {
		return ""
	}
	rt := runner_create_slot_locked(app, cwd)
	return strings.clone(rt.key, allocator)
}

// 恢复/切换 session 指针：只保证运行态条目存在，不校验 transcript 合法性。
runner_session_resume :: proc(
	app: ^App,
	session_id, cwd: string,
	allocator := context.allocator,
) -> string {
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)
	if !runner_initialized(app) {
		return ""
	}
	rt := runner_ensure_locked(app, session_id, cwd)
	return strings.clone(rt.key, allocator)
}

// 任意 session 在跑都算忙（cwd 切换等进程级操作需要全局静默）。
runner_any_running :: proc(app: ^App) -> bool {
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)
	for rt in app.runner.sessions {
		if rt.running {
			return true
		}
	}
	return false
}

// 当前 session 是否在跑；没有当前 session 时为 false。
runner_running :: proc(app: ^App) -> bool {
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)
	rt := runner_find_locked(app, app.runner.current)
	return rt != nil && rt.running
}

runner_session_running :: proc(app: ^App, key: string) -> bool {
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)
	rt := runner_find_locked(app, key)
	return rt != nil && rt.running
}

// 当前 session 指针的副本；调用方负责 delete。空字符串表示「下一条提示新建」。
runner_session :: proc(app: ^App, allocator := context.allocator) -> string {
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)
	rt := runner_find_locked(app, app.runner.current)
	if rt == nil || len(rt.session_id) == 0 {
		return ""
	}
	return strings.clone(rt.session_id, allocator)
}

runner_current_key :: proc(app: ^App, allocator := context.allocator) -> string {
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)
	if len(app.runner.current) == 0 {
		return ""
	}
	return strings.clone(app.runner.current, allocator)
}

// 某个 session 的运行态快照；key 为空时取当前 session。字符串归调用方。
runner_state :: proc(app: ^App, key: string, allocator := context.allocator) -> Runner_State {
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)
	rt := runner_find_locked(app, key if len(key) > 0 else app.runner.current)
	if rt == nil {
		return {}
	}
	return {
		key = strings.clone(rt.key, allocator),
		session_id = strings.clone(rt.session_id, allocator),
		cwd = strings.clone(rt.cwd, allocator),
		running = rt.running,
		turn = rt.turn,
	}
}

runner_turn :: proc(app: ^App) -> Maybe(int) {
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)
	rt := runner_find_locked(app, app.runner.current)
	if rt == nil {
		return nil
	}
	return rt.turn
}

runner_set_turn :: proc(app: ^App, key: string, turn: int) {
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)
	if rt := runner_find_locked(app, key); rt != nil {
		rt.turn = turn
	}
}

// session_start 之后把 slot 别名到真实 id。订阅了真实 id 的标签页/重连也
// 就能收到这个 session 的后续事件。
runner_set_session_id :: proc(app: ^App, key, session_id: string) {
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)
	rt := runner_find_locked(app, key)
	if rt == nil || rt.session_id == session_id {
		return
	}
	if len(rt.session_id) > 0 {
		delete(rt.session_id, runtime.heap_allocator())
	}
	rt.session_id = strings.clone(session_id, runtime.heap_allocator())
}

// 启动一轮 turn。状态切换、session 快照与线程句柄归位放在同一把锁里：
// 同一 session 的下一轮不会抢跑，其他 session 不受影响。
// 返回的 key 是本次 turn 所属 session 的稳定 key（调用方 allocator）。
runner_start_turn :: proc(
	app: ^App,
	request: Turn_Request,
	allocator := context.allocator,
) -> (status: Runner_Start, key: string, message: string) {
	// 没有显式 cwd 时用进程默认目录；每个 session 的目录都独立保存，
	// 因此不同 project 的 turn 可以同时运行。
	default_cwd := app_cwd(app)

	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)

	if app.runner.exiting || !runner_initialized(app) {
		return .Shutting_Down, "", "server is shutting down"
	}
	rt := runner_ensure_locked(
		app,
		request.session_key,
		request.cwd if len(request.cwd) > 0 else default_cwd,
	)
	if rt.running {
		return .Busy, "", "a turn is already running in this session"
	}
	runner_reap_thread_locked(rt)
	rt.running = true
	rt.turn = nil
	sync.atomic_store(&rt.cancel.value, 0)
	session_snapshot := ""
	if len(rt.session_id) > 0 {
		session_snapshot = strings.clone(rt.session_id, runtime.heap_allocator())
	}

	// 请求里的可选字段优先；没带就用 ap-web 启动参数里的默认值（与 ap-tui 一致）。
	model := request.model if request.model != nil else app.options.model
	agent := request.agent if request.agent != nil else app.options.agent
	max_steps := request.max_steps if request.max_steps != nil else app.options.max_steps
	max_tokens := request.max_tokens if request.max_tokens != nil else app.options.max_tokens

	job := new(Turn_Job, runtime.heap_allocator())
	job^ = Turn_Job {
		app = app,
		key = strings.clone(rt.key, runtime.heap_allocator()),
		session_id = strings.clone(rt.session_id, runtime.heap_allocator()),
		options = {
			agent_bin = app.agent_bin,
			session_id = session_snapshot,
			config_dir = app.config_dir,
			cwd = strings.clone(rt.cwd if len(rt.cwd) > 0 else default_cwd, runtime.heap_allocator()),
			model = clone_maybe_string(model),
			agent = clone_maybe_string(agent),
			max_steps = max_steps,
			max_tokens = max_tokens,
			cancel = &rt.cancel,
			// 结果在 turn 线程分配、在 runner 线程释放：所有权交给 heap，不依赖线程 context。
			allocator = runtime.heap_allocator(),
		},
		prompt = strings.clone(request.prompt, runtime.heap_allocator()),
	}

	handle := thread.create_and_start_with_data(rawptr(job), runner_thread, name = "turn-runner")
	if handle == nil {
		rt.running = false
		free_job(job)
		return .Failed, "", "cannot start turn thread"
	}
	rt.thread = handle
	runner_set_current_locked(app, rt.key)
	return .Started, strings.clone(rt.key, allocator), ""
}

// DELETE /api/turn：置位取消 token，泵会终止整棵进程树。
// key 为空时取当前 session；当前 session 没在跑且只有一个 session 在跑时，
// 退化为取消那一个（兼容不带 session 的旧客户端）。
runner_cancel :: proc(app: ^App, key := "") -> bool {
	sync.mutex_lock(&app.runner.mu)
	defer sync.mutex_unlock(&app.runner.mu)

	rt: ^Session_Runtime
	if len(key) > 0 {
		rt = runner_find_locked(app, key)
		if rt == nil || !rt.running {
			return false
		}
	} else {
		rt = runner_find_locked(app, app.runner.current)
		if rt == nil || !rt.running {
			rt = nil
			count := 0
			for candidate in app.runner.sessions {
				if candidate.running {
					rt = candidate
					count += 1
				}
			}
			if count != 1 {
				return false
			}
		}
	}
	if rt == nil || !rt.running {
		return false
	}
	agent_cancel_token_cancel(&rt.cancel)
	return true
}

// 进程退出时收尾：拒绝新 turn、终止所有运行中的 turn，并最多等 5s。
runner_shutdown :: proc(app: ^App) {
	sync.mutex_lock(&app.runner.mu)
	app.runner.exiting = true
	for rt in app.runner.sessions {
		if rt.running {
			agent_cancel_token_cancel(&rt.cancel)
		}
	}
	sync.mutex_unlock(&app.runner.mu)

	start := time.tick_now()
	for runner_any_running(app) && time.tick_since(start) < 5 * time.Second {
		time.sleep(10 * time.Millisecond)
	}

	// 还有 turn 没停下时不拆注册表：turn 线程收尾还要回写 running 状态。
	if runner_any_running(app) {
		return
	}

	sync.mutex_lock(&app.runner.mu)
	for rt in app.runner.sessions {
		runner_reap_thread_locked(rt)
		delete(rt.key, runtime.heap_allocator())
		if len(rt.session_id) > 0 {
			delete(rt.session_id, runtime.heap_allocator())
		}
		if len(rt.cwd) > 0 {
			delete(rt.cwd, runtime.heap_allocator())
		}
		free(rt, runtime.heap_allocator())
	}
	delete(app.runner.sessions)
	app.runner.sessions = nil
	if len(app.runner.current) > 0 {
		delete(app.runner.current, runtime.heap_allocator())
	}
	app.runner.current = ""
	sync.mutex_unlock(&app.runner.mu)
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
	if len(job.key) > 0 {
		delete(job.key, runtime.heap_allocator())
	}
	if len(job.session_id) > 0 {
		delete(job.session_id, runtime.heap_allocator())
	}
	if len(job.options.session_id) > 0 {
		delete(job.options.session_id, runtime.heap_allocator())
	}
	if len(job.options.cwd) > 0 {
		delete(job.options.cwd, runtime.heap_allocator())
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

// 每个 stdout 事件：原始行按 session 广播 + 记录 session 指针与 turn_done
// 需要的信息。
runner_on_event_line :: proc(user: rawptr, ev: Event, line: string) {
	job := (^Turn_Job)(user)
	app := job.app

	switch ev.type {
	case "session_start":
		if len(ev.session_id) > 0 && ev.session_id != job.session_id {
			if len(job.session_id) > 0 {
				delete(job.session_id, runtime.heap_allocator())
			}
			job.session_id = strings.clone(ev.session_id, runtime.heap_allocator())
			runner_set_session_id(app, job.key, ev.session_id)
		}
	case "turn_start", "turn_end":
		if ev.turn > 0 {
			runner_set_turn(app, job.key, ev.turn)
		}
	case "session_end":
		if len(ev.reason) > 0 {
			if len(job.session_end) > 0 {
				delete(job.session_end, runtime.heap_allocator())
			}
			job.session_end = strings.clone(ev.reason, runtime.heap_allocator())
		}
	}

	forwarded := line
	if strings.has_suffix(forwarded, "\r") {
		forwarded = forwarded[:len(forwarded) - 1]
	}
	if len(forwarded) > 0 {
		_ = sse_hub_broadcast(&app.hub, "ap", forwarded, job.key, job.session_id)
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

usage_has_values :: protocol.usage_has_any

runner_stop_reason :: proc(job: ^Turn_Job) -> Maybe(string) {
	if len(job.stop_reason) > 0 {
		return job.stop_reason
	}
	if len(job.session_end) > 0 {
		return job.session_end
	}
	return nil
}

// turn 线程：spawn ap → 泵事件（回调里按 session 广播）→ 广播 turn_done →
// 交还该 session 的分飞锁。
runner_thread :: proc(user: rawptr) {
	job := (^Turn_Job)(user)
	app := job.app

	callbacks := Turn_Callbacks {
		user          = rawptr(job),
		on_event_line = runner_on_event_line,
	}
	result := pump_agent(&job.options, job.prompt, callbacks)

	// session 指针已在每条 session_start 回调里更新；这里不再覆盖，
	// 否则用户 turn 中调 /api/session/new 清掉的指针会被重新写回。
	stop_reason := runner_stop_reason(job)
	// Windows 的 Job Object 终止会让 ap 来不及写 turn_end/session_end；
	// 用户主动取消时必须让前端能把「取消」和「失败」区分开。
	if stop_reason == nil && result.cancelled {
		stop_reason = "cancelled"
	}
	done := Sse_Turn_Done {
		exit_code = result.exit_code,
		stop_reason = stop_reason,
		usage = job.usage,
	}
	if len(result.stderr_preview) > 0 {
		done.stderr_preview = result.stderr_preview
	}
	data := sse_turn_done_json(done, runtime.heap_allocator())
	_ = sse_hub_broadcast(&app.hub, "turn_done", data, job.key, job.session_id)
	delete(data)

	if len(result.session_id) > 0 {
		delete(result.session_id, runtime.heap_allocator())
	}
	if len(result.stderr_preview) > 0 {
		delete(result.stderr_preview, runtime.heap_allocator())
	}

	sync.mutex_lock(&app.runner.mu)
	if rt := runner_find_locked(app, job.key); rt != nil {
		rt.running = false
		// 这一轮的取消信号到此为止；不清零会让「取消后立刻开新 turn」继承旧状态。
		sync.atomic_store(&rt.cancel.value, 0)
	}
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
