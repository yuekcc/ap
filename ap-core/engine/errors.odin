package engine

import "../platform"
import "../protocol"
import "core:fmt"

// engine 的错误类型不依赖 CLI 退出码；ap 在边界处映射成 Exit_Code。
Project :: platform.Project
SCHEMA_VERSION :: protocol.SCHEMA_VERSION
PROVIDER_NAME :: protocol.PROVIDER_NAME
Error_Kind :: enum int {
	None     = 0,
	Usage    = 1,
	Internal = 2,
	Provider = 3,
	Tool     = 4,
}

Error :: struct {
	kind:    Error_Kind,
	message: string,
}

ok_error :: proc() -> Error {
	return {kind = .None, message = ""}
}

make_error :: proc(kind: Error_Kind, format: string, args: ..any) -> Error {
	return {kind = kind, message = fmt.tprintf(format, ..args)}
}

is_ok :: proc(err: Error) -> bool {
	return err.kind == .None
}

// 把 platform 的纯消息错误提升为 engine 错误；kind 由调用方按场景指定。
from_platform :: proc(err: platform.Error, kind := Error_Kind.Usage) -> Error {
	if platform.is_ok(err) {
		return ok_error()
	}
	return {kind = kind, message = err.message}
}

// ---- 日志 ----

Log_Level :: enum int {
	Error = 0,
	Warn  = 1,
	Info  = 2,
	Debug = 3,
}

Logger :: struct {
	level: Log_Level,
}

logger: Logger = {level = .Info}

log_set_level :: proc(level: Log_Level) {
	logger.level = level
}

log_error :: proc(format: string, args: ..any) {
	fmt.eprintf("ap: error: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
}

log_warn :: proc(format: string, args: ..any) {
	if logger.level >= .Warn {
		fmt.eprintf("ap: warning: ")
		fmt.eprintf(format, ..args)
		fmt.eprintln()
	}
}

log_debug :: proc(format: string, args: ..any) {
	if logger.level >= .Debug {
		fmt.eprintf("ap: debug: ")
		fmt.eprintf(format, ..args)
		fmt.eprintln()
	}
}
