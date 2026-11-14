#+build windows
package aptui

import client "../ap-core/client"

import "core:os"
import "core:sync"
import "core:time"
import win32 "core:sys/windows"

// 信号处理器只写取消标志和退出码；Ctrl+C 不再直接杀掉 ap-tui，
// 正在跑的 turn 会通过 Turn_Options.cancel 收到取消。

g_cancel_token: ^client.Cancel_Token
g_signal_code: i32
g_signal_tick: time.Tick

tui_ctrl_handler :: proc "system" (ctrl_type: win32.DWORD) -> win32.BOOL {
	if ctrl_type != win32.CTRL_C_EVENT && ctrl_type != win32.CTRL_BREAK_EVENT {
		return false
	}
	code: i32 = 130
	if sync.atomic_load(&g_signal_code) != 0 {
		// 1s 内第二次 Ctrl+C：直接退出，不再等 turn 收尾。
		if time.tick_since(g_signal_tick) < time.Second {
			os.exit(int(code))
		}
	}
	sync.atomic_store(&g_signal_code, code)
	g_signal_tick = time.tick_now()
	if token := g_cancel_token; token != nil {
		// 信号处理器没有 Odin context，不能调用普通 proc；直接写原子标志。
		sync.atomic_store(&token.value, 1)
	}
	return true
}

install_signal_handlers :: proc(token: ^client.Cancel_Token) {
	g_cancel_token = token
	win32.SetConsoleCtrlHandler(tui_ctrl_handler, true)
}
