package main

import "core:testing"

@(test)
test_is_loopback_host :: proc(t: ^testing.T) {
	testing.expect(t, is_loopback_host("127.0.0.1"))
	testing.expect(t, is_loopback_host("127.9.8.7"))
	testing.expect(t, is_loopback_host("localhost"))
	testing.expect(t, is_loopback_host("LOCALHOST"))
	testing.expect(t, is_loopback_host("::1"))
	testing.expect(t, !is_loopback_host("0.0.0.0"))
	testing.expect(t, !is_loopback_host("192.168.1.10"))
	testing.expect(t, !is_loopback_host("example.com"))
}

Shutdown_Test_Handler :: struct {
	calls: int,
}

shutdown_test_handler :: proc(user: rawptr) {
	state := (^Shutdown_Test_Handler)(user)
	state.calls += 1
}

// 信号路径（shutdown_request）只能置原子标志：真正的收尾留给专用 watcher 线程，
// 处理器里不能拿锁、轮询或做任何重活（Unix 信号处理器必须 async-signal-safe）。
@(test)
test_shutdown_signal_path_only_sets_flag :: proc(t: ^testing.T) {
	SHUTDOWN = {}
	testing.expect(t, !shutdown_pending())

	state: Shutdown_Test_Handler
	shutdown_configure(shutdown_test_handler, &state)

	shutdown_request()
	testing.expect(t, shutdown_pending())
	testing.expect_value(t, state.calls, 0)

	testing.expect(t, shutdown_dispatch())
	testing.expect_value(t, state.calls, 1)
	testing.expect(t, !shutdown_pending())

	// 标志已消费：不会重复清理。
	testing.expect(t, !shutdown_dispatch())
	testing.expect_value(t, state.calls, 1)
}
