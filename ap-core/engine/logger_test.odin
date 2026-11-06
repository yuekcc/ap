package engine

import "../platform"

import "core:os"
import "core:strings"
import "core:testing"

// 文件日志是全局状态：用例结束恢复级别并关闭文件，避免影响同包其它测试。
log_file_test_reset :: proc() {
	log_set_level(.Info)
	platform.log_file_close()
}

// 日志按本地日期命名，测试不去猜日期，直接问平台层同一个路径。
today_log_path :: proc(dir: string) -> string {
	year, month, day, _, _, _ := platform.local_now()
	return platform.log_file_path(dir, year, month, day)
}

log_file_content :: proc(t: ^testing.T, path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		testing.expectf(t, false, "cannot read %s", path)
		return ""
	}
	return string(data)
}

@(test)
test_log_warn_and_error_reach_log_file :: proc(t: ^testing.T) {
	dir := test_temp_dir("engine-logger")
	defer test_cleanup(dir)
	defer log_file_test_reset()

	platform.log_file_init(dir)
	log_set_level(.Warn)
	log_warn("agent %s: weird field", "reviewer")
	log_error("provider failed: %s", "timeout")

	content := log_file_content(t, today_log_path(dir))
	testing.expect(t, strings.contains(content, "[warn] agent reviewer: weird field\n"))
	testing.expect(t, strings.contains(content, "[error] provider failed: timeout\n"))
}

@(test)
test_log_info_and_debug_are_below_default_level :: proc(t: ^testing.T) {
	dir := test_temp_dir("engine-logger-level")
	defer test_cleanup(dir)
	defer log_file_test_reset()

	platform.log_file_init(dir)
	log_set_level(.Warn)
	log_info("info is filtered out")
	log_debug("debug is filtered out")

	// 级别过滤发生在写文件之前：没有可写日志时不留下任何文件。
	testing.expect(t, !os.exists(today_log_path(dir)))
}

@(test)
test_log_message_keeps_multiline_body_together :: proc(t: ^testing.T) {
	dir := test_temp_dir("engine-logger-multiline")
	defer test_cleanup(dir)
	defer log_file_test_reset()

	platform.log_file_init(dir)
	log_set_level(.Debug)
	log_debug("line one\nline two")

	content := log_file_content(t, today_log_path(dir))
	testing.expect(t, strings.contains(content, "[debug] line one\n"))
	testing.expect(t, strings.contains(content, "[debug]   line two\n"))
}
