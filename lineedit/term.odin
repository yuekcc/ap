package lineedit

// Transport 把终端 I/O 抽象出来。真实实现基于 os.File + termios/console，
// 测试用脚本化输入和 VT100 Screen 的 fake 实现。
Transport :: struct {
	ctx:       rawptr,
	read:      proc(ctx: rawptr, buf: []u8, timeout_ms: int) -> (n: int, timed_out: bool, eof: bool),
	write:     proc(ctx: rawptr, data: []u8) -> bool,
	size:      proc(ctx: rawptr) -> (cols, rows: int),
	enter_raw: proc(ctx: rawptr) -> bool,
	leave_raw: proc(ctx: rawptr),
	destroy:   proc(ctx: rawptr),
}
