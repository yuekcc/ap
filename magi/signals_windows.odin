#+build windows
package magi

import platform "../ap-core/platform"
import "core:os"
import "core:sync"
import "core:time"
import win32 "core:sys/windows"

// 与 ap-cli 相同的取消语义：第一次 Ctrl+C 置取消标志，让三个成员及时结束；
// 1 秒内第二次 Ctrl+C 直接退出。

g_cancel_token: ^platform.Cancel_Token
g_signal_code: i32
g_signal_tick: time.Tick

ctrl_handler :: proc "system" (ctrl_type: win32.DWORD) -> win32.BOOL {
	if ctrl_type != win32.CTRL_C_EVENT && ctrl_type != win32.CTRL_BREAK_EVENT {
		return false
	}
	code: i32 = 130
	if sync.atomic_load(&g_signal_code) != 0 {
		if time.tick_since(g_signal_tick) < time.Second {
			os.exit(int(code))
		}
	}
	sync.atomic_store(&g_signal_code, code)
	g_signal_tick = time.tick_now()
	if token := g_cancel_token; token != nil {
		sync.atomic_store(&token.value, 1)
	}
	return true
}

install_signal_handlers :: proc(token: ^platform.Cancel_Token) {
	g_cancel_token = token
	win32.SetConsoleCtrlHandler(ctrl_handler, true)
}

signal_exit_code :: proc() -> int {
	return int(sync.atomic_load(&g_signal_code))
}
