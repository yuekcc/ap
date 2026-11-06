package platform

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

// 文件日志：$AP_CONFIG/logs/app-YYYY-MM-DD.log，一天一个文件，只追加。
//
// 宿主 adapter 解析出 $AP_CONFIG 后调用 log_file_init 记录目录；engine 的 log_*
// 把已经决定要输出的那条消息交给 log_file_write 落盘。级别判断仍由调用方完成，
// 这里不做二次过滤：stderr 打什么，文件里就有什么。
//
// 文件在第一条日志时才创建，运行顺利的进程不会留下空文件。日志失败（磁盘满、
// 目录不可写）一律吞掉：日志不能影响主流程，也不能污染退出码。
//
// 跨天切换按本地日期判断：每次写入前比较本地日期，过了零点就换到新文件。
// 子代理是独立进程，会和父进程写同一个文件；两边都用追加模式打开，靠 OS 的
// 追加语义拼接，不加锁。

Log_File :: struct {
	dir:  string, // 已解析的 $AP_CONFIG 副本；空表示未初始化
	path: string, // 当前日志文件路径
	file: ^os.File,
	day:  int, // yyyymmdd，0 表示当天文件尚未打开
}

@(private)
file_log_mu: sync.Mutex

@(private)
file_log: Log_File

// log_file_init 记录日志根目录；不创建目录和文件。重复调用会重置旧状态。
log_file_init :: proc(config_dir: string) {
	sync.mutex_lock(&file_log_mu)
	defer sync.mutex_unlock(&file_log_mu)
	log_file_close_locked()
	if len(config_dir) > 0 {
		file_log.dir = strings.clone(config_dir)
	}
}

// log_file_close 关闭句柄并清空状态；未初始化时是空操作。
log_file_close :: proc() {
	sync.mutex_lock(&file_log_mu)
	defer sync.mutex_unlock(&file_log_mu)
	log_file_close_locked()
}

// log_file_write 追加一条日志，时间戳取当前本地时间。
log_file_write :: proc(level, message: string) {
	year, month, day, hour, minute, second := local_now()
	log_file_write_at(level, message, year, month, day, hour, minute, second)
}

// log_file_write_at 用显式时间戳写入，供跨天切换的测试使用。
log_file_write_at :: proc(
	level, message: string,
	year, month, day, hour, minute, second: int,
) {
	sync.mutex_lock(&file_log_mu)
	defer sync.mutex_unlock(&file_log_mu)

	if len(file_log.dir) == 0 {
		return
	}
	key := day_key(year, month, day)
	if file_log.file == nil || file_log.day != key {
		if err := log_file_open_locked(year, month, day); !is_ok(err) {
			return
		}
	}
	write_entry_locked(level, message, year, month, day, hour, minute, second)
}

day_key :: proc "contextless" (year, month, day: int) -> int {
	return year * 10000 + month * 100 + day
}

log_file_path :: proc(config_dir: string, year, month, day: int) -> string {
	return fmt.aprintf("%s/logs/app-%04d-%02d-%02d.log", config_dir, year, month, day)
}

@(private)
log_file_close_locked :: proc() {
	if file_log.file != nil {
		os.close(file_log.file)
		file_log.file = nil
	}
	if len(file_log.dir) > 0 {
		delete(file_log.dir)
		file_log.dir = ""
	}
	if len(file_log.path) > 0 {
		delete(file_log.path)
		file_log.path = ""
	}
	file_log.day = 0
}

// 先打开新文件再替换旧状态；失败时保留目录设置，下一次写入可以重试。
@(private)
log_file_open_locked :: proc(year, month, day: int) -> Error {
	logs_dir := fmt.aprintf("%s/logs", file_log.dir)
	defer delete(logs_dir)
	if err := ensure_dir(logs_dir); !is_ok(err) {
		return err
	}

	path := log_file_path(file_log.dir, year, month, day)
	file, oerr := os.open(path, {.Write, .Create, .Append}, os.Permissions_Default_File)
	if oerr != nil {
		err := errorf("cannot open log file %s: %v", path, oerr)
		delete(path)
		return err
	}

	if file_log.file != nil {
		os.close(file_log.file)
		file_log.file = nil
	}
	if len(file_log.path) > 0 {
		delete(file_log.path)
	}
	file_log.path = path
	file_log.file = file
	file_log.day = day_key(year, month, day)
	return ok_error()
}

// 每条消息一行；消息自带换行时，后续行用同前缀缩进，方便按时间戳 grep。
@(private)
write_entry_locked :: proc(
	level, message: string,
	year, month, day, hour, minute, second: int,
) {
	remaining := strings.trim_right(message, "\r\n")
	first := true
	for {
		line := remaining
		if idx := strings.index_byte(remaining, '\n'); idx >= 0 {
			line = remaining[:idx]
			remaining = remaining[idx + 1:]
		} else {
			remaining = ""
		}
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		// 续行保留时间戳前缀，缩进两格，方便整段 grep 出来。
		indent := "  " if !first else ""
		text := fmt.aprintf(
			"%04d-%02d-%02d %02d:%02d:%02d [%s] %s%s\n",
			year,
			month,
			day,
			hour,
			minute,
			second,
			level,
			indent,
			line,
		)
		first = false
		ok := write_all(file_log.file, transmute([]byte)text)
		delete(text)
		if !ok {
			// 句柄已经不可用，关掉让下一次写入重开。
			os.close(file_log.file)
			file_log.file = nil
			return
		}
		if len(remaining) == 0 {
			return
		}
	}
}
