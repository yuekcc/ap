package platform

import "core:fmt"
import "core:sync"

// 诊断日志：stderr 给人看，$AP_CONFIG/logs/app-YYYY-MM-DD.log 给事后排查。
//
// 级别过滤只在这里做一次，决定输出的消息同时写两处；文件侧不重复判断级别。
// 日志实现放在 platform 而不是 engine，是因为 ap-cli/tools 这类不 import engine
// 的包也需要写同一条诊断日志；这样 stderr 与文件仍然只有一个输出点。
//
// 默认级别与文档一致是 warning：库使用者不设置级别时只看到警告和错误。
//
// 文件由宿主 adapter 用 log_file_init 打开；未初始化时只写 stderr。

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

logger: Logger = {level = .Warn}

// magi 的三个成员在不同线程里跑，日志行本身必须是原子的。
log_mu: sync.Mutex

log_set_level :: proc(level: Log_Level) {
	logger.level = level
}

// log_enabled 供调用方在拼装昂贵的诊断内容前判断级别，避免白白构造日志文本。
log_enabled :: proc(level: Log_Level) -> bool {
	return logger.level >= level
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
	log_file_write(log_level_name(level), message)
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
