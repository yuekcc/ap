package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import sync_chan "core:sync/chan"

FAKE_AGENT_SOURCE :: #load("testdata/fake_agent/main.odin", string)

// 测试进程内只编译一次假 agent（每个测试文件都会用到）。
FAKE_AGENT_EXE: string

fake_agent_path :: proc(t: ^testing.T) -> string {
	if len(FAKE_AGENT_EXE) > 0 {
		return FAKE_AGENT_EXE
	}
	dir := test_temp_dir("fake-agent")
	src_dir := fmt.aprintf("%s/pkg", dir)
	test_write_file(fmt.aprintf("%s/main.odin", src_dir), FAKE_AGENT_SOURCE)
	exe := fmt.aprintf("%s/fake-agent", dir)
	when ODIN_OS == .Windows {
		exe = strings.concatenate({exe, ".exe"})
	}
	state, out, errout, err := os.process_exec(
		{command = []string{"odin", "build", src_dir, fmt.aprintf("-out:%s", exe)}},
		context.allocator,
	)
	defer {
		delete(out)
		delete(errout)
	}
	if err != nil || !state.exited || state.exit_code != 0 {
		fmt.eprintfln("cannot build fake agent: %v\nstdout:\n%s\nstderr:\n%s", err, out, errout)
		testing.fail(t)
		return ""
	}
	// 这个路径要活过整个测试进程；测试的 context.allocator 是每个测试任务
	// 结束后回滚的 arena，不能直接存。
	FAKE_AGENT_EXE = strings.clone(exe, runtime.heap_allocator())
	return FAKE_AGENT_EXE
}

// 测试用 app：不接真项目，只把 runner 依赖的字段填好。
runner_test_setup :: proc(t: ^testing.T, app: ^App, dir: string) {
	agent_bin := fake_agent_path(t)
	if len(agent_bin) == 0 {
		return
	}
	config_dir, config_err := canonicalize_path(dir, false)
	testing.expect_value(t, config_err.message, "")
	project, project_err := open_project(config_dir, dir)
	testing.expect_value(t, project_err.message, "")

	app.agent_bin = agent_bin
	app.config_dir = config_dir
	app.project = project
	app.cwd = project.root
	sse_hub_init(&app.hub)
	runner_init(app)
}

test_wait_runner_idle :: proc(app: ^App, timeout: time.Duration) -> bool {
	start := time.tick_now()
	for runner_running(app) {
		if time.tick_since(start) > timeout {
			return false
		}
		time.sleep(5 * time.Millisecond)
	}
	return true
}

test_wait_session :: proc(app: ^App, expected: string, timeout: time.Duration) -> bool {
	start := time.tick_now()
	for {
		session := runner_session(app)
		matched := session == expected
		delete(session)
		if matched {
			return true
		}
		if time.tick_since(start) > timeout {
			return false
		}
		time.sleep(5 * time.Millisecond)
	}
}

// 把订阅者当前缓冲里的帧全部取出拼成一串，测试只做 contains 断言。
test_drain_frames :: proc(sub: ^Sse_Subscriber) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for {
		frame, ok := sync_chan.try_recv(sub.frames)
		if !ok {
			break
		}
		strings.write_string(&b, frame)
		delete(frame)
	}
	return strings.clone(strings.to_string(b))
}

@(test)
test_runner_full_turn_forwards_raw_and_ends :: proc(t: ^testing.T) {
	dir := test_temp_dir("runner-full")
	defer os.remove_all(dir)

	app: App
	runner_test_setup(t, &app, dir)
	if len(app.agent_bin) == 0 {
		return
	}
	defer sse_hub_destroy(&app.hub)
	sub: Sse_Subscriber
	testing.expect(t, sse_hub_subscribe(&app.hub, &sub, 512))
	defer sse_hub_unsubscribe(&app.hub, &sub)
	defer runner_shutdown(&app)

	status, start_err := runner_start_turn(&app, {prompt = "hello"})
	testing.expect_value(t, start_err, "")
	testing.expect_value(t, status, Runner_Start.Started)
	testing.expect_value(t, runner_running(&app), true)

	// 单飞：running 期间再起一轮直接拒绝（API 层映射成 409）。
	busy, _ := runner_start_turn(&app, {prompt = "second"})
	testing.expect_value(t, busy, Runner_Start.Busy)

	testing.expect(t, test_wait_runner_idle(&app, 10 * time.Second), "turn did not finish")
	testing.expect_value(t, runner_running(&app), false)

	frames := test_drain_frames(&sub)
	defer delete(frames)

	// 原始行直转发：结构体里没有的 future_field 必须还在。
	testing.expect(
		t,
		strings.contains(
			frames,
			`data: {"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_fake","parent_session_id":null,"future_field":{"nested":true}}`,
		),
	)
	testing.expect(t, strings.contains(frames, "event: turn_done"))
	testing.expect(t, strings.contains(frames, `"exit_code":0`))
	testing.expect(t, strings.contains(frames, `"stop_reason":"stop"`))
	testing.expect(t, strings.contains(frames, `"total_tokens":12`))
	testing.expect(t, !strings.contains(frames, `"stderr_preview":"`))

	session := runner_session(&app)
	defer delete(session)
	testing.expect_value(t, session, "ses_fake")

	turn := runner_turn(&app)
	testing.expect(t, turn != nil)
	if value, ok := turn.?; ok {
		testing.expect_value(t, value, 1)
	}
}

@(test)
test_runner_cancel_terminates_turn :: proc(t: ^testing.T) {
	dir := test_temp_dir("runner-cancel")
	defer os.remove_all(dir)

	app: App
	runner_test_setup(t, &app, dir)
	if len(app.agent_bin) == 0 {
		return
	}
	defer sse_hub_destroy(&app.hub)
	sub: Sse_Subscriber
	testing.expect(t, sse_hub_subscribe(&app.hub, &sub, 512))
	defer sse_hub_unsubscribe(&app.hub, &sub)
	defer runner_shutdown(&app)

	status, _ := runner_start_turn(&app, {prompt = "[scenario:cancel]"})
	testing.expect_value(t, status, Runner_Start.Started)
	testing.expect(t, test_wait_session(&app, "ses_cancel", 10 * time.Second), "agent did not start")

	testing.expect(t, runner_cancel(&app))
	testing.expect(t, test_wait_runner_idle(&app, 10 * time.Second), "cancel did not stop turn")

	frames := test_drain_frames(&sub)
	defer delete(frames)
	testing.expect(t, strings.contains(frames, "event: turn_done"))
	testing.expect(t, !strings.contains(frames, `"exit_code":0`))
	// ap 被强制终止时（Windows Job Object）来不及写 turn_end/session_end，
	// 信封仍应明确标出这是用户取消，而不是一次普通失败。
	testing.expect(t, strings.contains(frames, `"stop_reason":"cancelled"`))
}

@(test)
test_runner_reports_stderr_on_failure :: proc(t: ^testing.T) {
	dir := test_temp_dir("runner-stderr")
	defer os.remove_all(dir)

	app: App
	runner_test_setup(t, &app, dir)
	if len(app.agent_bin) == 0 {
		return
	}
	defer sse_hub_destroy(&app.hub)
	sub: Sse_Subscriber
	testing.expect(t, sse_hub_subscribe(&app.hub, &sub, 512))
	defer sse_hub_unsubscribe(&app.hub, &sub)
	defer runner_shutdown(&app)

	status, _ := runner_start_turn(&app, {prompt = "[scenario:stderr]"})
	testing.expect_value(t, status, Runner_Start.Started)
	testing.expect(t, test_wait_runner_idle(&app, 10 * time.Second), "turn did not finish")

	frames := test_drain_frames(&sub)
	defer delete(frames)
	testing.expect(t, strings.contains(frames, `"exit_code":3`))
	testing.expect(t, strings.contains(frames, `"stop_reason":null`))
	testing.expect(t, strings.contains(frames, `fake: boom`))
	testing.expect(t, strings.contains(frames, `fake: second line`))
}

// turn_end 缺失 stop_reason 时取 turn_end 的；退出码非 0 也要如实上报。
@(test)
test_runner_turn_done_keeps_stop_reason_and_exit_code :: proc(t: ^testing.T) {
	dir := test_temp_dir("runner-exit7")
	defer os.remove_all(dir)

	app: App
	runner_test_setup(t, &app, dir)
	if len(app.agent_bin) == 0 {
		return
	}
	defer sse_hub_destroy(&app.hub)
	sub: Sse_Subscriber
	testing.expect(t, sse_hub_subscribe(&app.hub, &sub, 512))
	defer sse_hub_unsubscribe(&app.hub, &sub)
	defer runner_shutdown(&app)

	status, _ := runner_start_turn(&app, {prompt = "[scenario:exit7]"})
	testing.expect_value(t, status, Runner_Start.Started)
	testing.expect(t, test_wait_runner_idle(&app, 10 * time.Second), "turn did not finish")

	frames := test_drain_frames(&sub)
	defer delete(frames)
	testing.expect(t, strings.contains(frames, `"exit_code":7`))
	testing.expect(t, strings.contains(frames, `"stop_reason":"max_steps"`))
}

// 服务退出：终止运行中的 turn，最多等 5s。
@(test)
test_runner_shutdown_stops_running_turn :: proc(t: ^testing.T) {
	dir := test_temp_dir("runner-shutdown")
	defer os.remove_all(dir)

	app: App
	runner_test_setup(t, &app, dir)
	if len(app.agent_bin) == 0 {
		return
	}
	defer sse_hub_destroy(&app.hub)
	sub: Sse_Subscriber
	testing.expect(t, sse_hub_subscribe(&app.hub, &sub, 64))
	defer sse_hub_unsubscribe(&app.hub, &sub)

	status, _ := runner_start_turn(&app, {prompt = "[scenario:cancel]"})
	testing.expect_value(t, status, Runner_Start.Started)
	testing.expect(t, test_wait_session(&app, "ses_cancel", 10 * time.Second), "agent did not start")

	start := time.tick_now()
	runner_shutdown(&app)
	elapsed := time.tick_since(start)
	testing.expect_value(t, runner_running(&app), false)
	testing.expect(t, elapsed < 7 * time.Second, "shutdown waited too long")
}
