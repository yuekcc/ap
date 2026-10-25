#+build !windows
package main

import "core:testing"

// 直接调用信号处理器：它只能置标志，不能同步执行收尾（async-signal-safe）。
@(test)
test_unix_signal_handler_only_sets_flag :: proc(t: ^testing.T) {
	SHUTDOWN = {}
	state: Shutdown_Test_Handler
	shutdown_configure(shutdown_test_handler, &state)

	shutdown_signal_handler(.SIGINT)

	testing.expect_value(t, state.calls, 0)
	testing.expect(t, shutdown_pending())
	testing.expect(t, shutdown_dispatch())
	testing.expect_value(t, state.calls, 1)
}
