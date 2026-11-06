package platform

import "core:os"
import "core:terminal"

// 写满整个切片；stdout、子进程 stdin 等都可能出现短写。
write_all :: proc(file: ^os.File, data: []byte) -> bool {
	remaining := data
	for len(remaining) > 0 {
		n, err := os.write(file, remaining)
		if err != nil || n <= 0 {
			return false
		}
		remaining = remaining[n:]
	}
	return true
}

// stderr 是否连着终端：决定人类可读输出能不能带 ANSI 颜色。
// 管道、重定向、被前端捕获时都返回 false。
is_terminal_stderr :: proc() -> bool {
	return terminal.is_terminal(os.stderr)
}
