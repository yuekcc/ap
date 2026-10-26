#+build !windows
package ap

import "platform"
import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:time"

g_cancel_token: ^platform.Cancel_Token
g_signal_code: i32
g_signal_tick: time.Tick

unix_signal_handler :: proc "c" (sig: posix.Signal) {
	code: i32 = 130
	if sig == .SIGTERM {
		code = 143
	}
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
}

install_signal_handlers :: proc(token: ^platform.Cancel_Token) {
	g_cancel_token = token
	act: posix.sigaction_t
	act.sa_handler = unix_signal_handler
	posix.sigemptyset(&act.sa_mask)
	act.sa_flags = {}
	posix.sigaction(.SIGINT, &act, nil)
	posix.sigaction(.SIGTERM, &act, nil)
}

signal_exit_code :: proc() -> int {
	code := sync.atomic_load(&g_signal_code)
	return int(code)
}
