package engine

import "../platform"
import "../protocol"
import "../tool"
import "core:fmt"
import "core:sync"

// engine 的错误类型不依赖 CLI 退出码；ap 在边界处映射成 Exit_Code。
Project :: platform.Project
SCHEMA_VERSION :: protocol.SCHEMA_VERSION
PROVIDER_NAME :: protocol.PROVIDER_NAME
Tool_Def :: tool.Tool_Def
Function_Def :: tool.Function_Def
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
//
// 日志有两个去处：stderr 给人看，$AP_CONFIG/logs/app-YYYY-MM-DD.log 给事后排查。
// 级别过滤只在这里做一次，决定输出的消息同时写两处；文件侧不重复判断级别。
// 文件日志由宿主 adapter 用 platform.log_file_init 打开目录，未初始化时写文件是空操作。

Log_Level :: enum int {
	Error = 0,
	Warn  = 1,
	Info  = 2,
	Debug = 3,
}

log_level_name :: proc(level: Log_Level) -> string {
	switch level {
	case .Error:
		return "error"
	case .Warn:
		return "warn"
	case .Info:
		return "info"
	case .Debug:
		return "debug"
	}
	return "debug"
}

Logger :: struct {
	level: Log_Level,
}

logger: Logger = {level = .Info}

// magi 的三个成员在不同线程里跑，日志行本身必须是原子的。
log_mu: sync.Mutex

log_set_level :: proc(level: Log_Level) {
	logger.level = level
}

// log_message 是唯一的输出点：先写 stderr，再把同一段文本追加到当天的日志文件。
log_message :: proc(level: Log_Level, format: string, args: ..any) {
	message := fmt.aprintf(format, ..args)
	defer delete(message)

	sync.mutex_lock(&log_mu)
	defer sync.mutex_unlock(&log_mu)

	if level == .Error {
		fmt.eprintf("ap: error: %s\n", message)
	} else if level == .Warn {
		fmt.eprintf("ap: warning: %s\n", message)
	} else {
		fmt.eprintf("ap: %s: %s\n", log_level_name(level), message)
	}
	platform.log_file_write(log_level_name(level), message)
}

log_error :: proc(format: string, args: ..any) {
	log_message(.Error, format, ..args)
}

log_warn :: proc(format: string, args: ..any) {
	if logger.level >= .Warn {
		log_message(.Warn, format, ..args)
	}
}

log_info :: proc(format: string, args: ..any) {
	if logger.level >= .Info {
		log_message(.Info, format, ..args)
	}
}

log_debug :: proc(format: string, args: ..any) {
	if logger.level >= .Debug {
		log_message(.Debug, format, ..args)
	}
}
