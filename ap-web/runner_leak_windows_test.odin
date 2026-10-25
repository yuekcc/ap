#+build windows
package main

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import win32 "core:sys/windows"

// odin 的 core:sys/windows 没有暴露 GetProcessHandleCount；句柄泄漏测试直接绑定。
foreign import leak_k32 "system:Kernel32.lib"

@(default_calling_convention="system")
foreign leak_k32 {
	GetProcessHandleCount :: proc(process: win32.HANDLE, count: ^u32) -> win32.BOOL ---
}

win32_process_handle_count :: proc(t: ^testing.T) -> u32 {
	count: u32
	ok := GetProcessHandleCount(win32.GetCurrentProcess(), &count)
	testing.expectf(t, ok != false, "GetProcessHandleCount failed")
	return count
}

// 每轮 turn 的线程句柄必须被 join + destroy：只把 running 置回 false 会泄漏
// Thread 结构体和它的 Win32 线程句柄，长时间运行会持续增长。
//
// 用不存在的 agent 二进制让 pump 在 spawn 阶段失败：这样每轮只创建线程，
// 不引入 core:os 子进程句柄的噪声，句柄数增长就等价于 turn 线程泄漏。
@(test)
test_runner_does_not_leak_thread_handles_across_turns :: proc(t: ^testing.T) {
	dir := test_temp_dir("runner-thread-leak")
	defer os.remove_all(dir)

	app: App
	runner_test_setup(t, &app, dir)
	if len(app.agent_bin) == 0 {
		return
	}
	app.agent_bin = fmt.aprintf("%s/does-not-exist", dir)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	baseline := win32_process_handle_count(t)
	for _ in 0 ..< 5 {
		status, _ := runner_start_turn(&app, {prompt = "hello"})
		testing.expect_value(t, status, Runner_Start.Started)
		testing.expect(t, test_wait_runner_idle(&app, 10 * time.Second), "turn did not finish")
	}

	after := win32_process_handle_count(t)
	testing.expectf(
		t,
		after <= baseline + 1,
		"turn threads leaked handles: %d -> %d",
		baseline,
		after,
	)
}
