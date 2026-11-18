package platform

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// 文件日志是全局状态，每个用例结束都要清掉，避免影响同包其它测试。
logger_reset :: proc() {
	log_set_level(.Info)
	log_file_close()
}

logs_dir_of :: proc(config_dir: string) -> string {
	return fmt.aprintf("%s/logs", config_dir)
}

@(test)
test_log_file_writes_dated_file :: proc(t: ^testing.T) {
	dir := test_temp_dir("logger")
	defer test_cleanup(dir)
	defer logger_reset()

	log_file_init(dir)
	log_file_write_at("warn", "disk is filling up", 2024, 3, 7, 9, 5, 1)

	path := log_file_path(dir, 2024, 3, 7)
	testing.expect(t, os.exists(path))
	content := test_read_file(path)
	testing.expect_value(t, content, "2024-03-07 09:05:01 [warn] disk is filling up\n")
}

@(test)
test_log_file_splits_by_day :: proc(t: ^testing.T) {
	dir := test_temp_dir("logger-split")
	defer test_cleanup(dir)
	defer logger_reset()

	log_file_init(dir)
	log_file_write_at("error", "before midnight", 2024, 3, 7, 23, 59, 59)
	log_file_write_at("error", "after midnight", 2024, 3, 8, 0, 0, 1)
	log_file_write_at("warn", "same day again", 2024, 3, 8, 0, 0, 2)

	first := test_read_file(log_file_path(dir, 2024, 3, 7))
	second := test_read_file(log_file_path(dir, 2024, 3, 8))
	testing.expect_value(t, first, "2024-03-07 23:59:59 [error] before midnight\n")
	testing.expect_value(
		t,
		second,
		"2024-03-08 00:00:01 [error] after midnight\n2024-03-08 00:00:02 [warn] same day again\n",
	)
}

@(test)
test_log_file_keeps_every_line_of_multiline_message :: proc(t: ^testing.T) {
	dir := test_temp_dir("logger-multiline")
	defer test_cleanup(dir)
	defer logger_reset()

	log_file_init(dir)
	log_file_write_at("warn", "first line\nsecond line\r\nthird line\n", 2024, 3, 7, 1, 2, 3)

	content := test_read_file(log_file_path(dir, 2024, 3, 7))
	testing.expect_value(
		t,
		content,
		"2024-03-07 01:02:03 [warn] first line\n" +
		"2024-03-07 01:02:03 [warn]   second line\n" +
		"2024-03-07 01:02:03 [warn]   third line\n",
	)
}

@(test)
test_log_file_creates_nothing_until_first_write :: proc(t: ^testing.T) {
	dir := test_temp_dir("logger-lazy")
	defer test_cleanup(dir)
	defer logger_reset()

	log_file_init(dir)
	testing.expect(t, !os.exists(logs_dir_of(dir)))

	log_file_write_at("error", "boom", 2024, 3, 7, 0, 0, 0)
	testing.expect(t, os.is_dir(logs_dir_of(dir)))
}

@(test)
test_log_file_write_without_init_is_noop :: proc(t: ^testing.T) {
	defer logger_reset()
	// 未初始化时不能 panic，也不能在进程当前目录落下文件。
	log_file_write_at("error", "nowhere", 2024, 3, 7, 0, 0, 0)
	log_file_write("warn", "still nowhere")
}

@(test)
test_log_file_appends_across_reopen :: proc(t: ^testing.T) {
	dir := test_temp_dir("logger-append")
	defer test_cleanup(dir)
	defer logger_reset()

	log_file_init(dir)
	log_file_write_at("warn", "one", 2024, 3, 7, 1, 1, 1)
	log_file_close()
	log_file_init(dir)
	log_file_write_at("warn", "two", 2024, 3, 7, 1, 1, 2)

	content := test_read_file(log_file_path(dir, 2024, 3, 7))
	testing.expect(t, strings.contains(content, "[warn] one\n"))
	testing.expect(t, strings.contains(content, "[warn] two\n"))
}

@(test)
test_log_info_and_debug_are_below_warn_level :: proc(t: ^testing.T) {
	dir := test_temp_dir("logger-level-warn")
	defer test_cleanup(dir)
	defer logger_reset()

	year, month, day, _, _, _ := local_now()
	log_file_init(dir)
	log_set_level(.Warn)
	log_info("info is filtered out")
	log_debug("debug is filtered out")
	// 级别过滤发生在写文件之前：只有 info/debug 时不创建日志文件。
	testing.expect(t, !os.exists(logs_dir_of(dir)))

	log_warn("warn is kept")
	log_error("error is kept")
	content := test_read_file(log_file_path(dir, year, month, day))
	testing.expect(t, strings.contains(content, "[warn] warn is kept\n"))
	testing.expect(t, strings.contains(content, "[error] error is kept\n"))
}

@(test)
test_log_debug_writes_info_and_debug_lines :: proc(t: ^testing.T) {
	dir := test_temp_dir("logger-level-debug")
	defer test_cleanup(dir)
	defer logger_reset()

	year, month, day, _, _, _ := local_now()
	log_file_init(dir)
	log_set_level(.Debug)
	log_info("request %d messages", 3)
	log_debug("line one\nline two")

	content := test_read_file(log_file_path(dir, year, month, day))
	testing.expect(t, strings.contains(content, "[info] request 3 messages\n"))
	testing.expect(t, strings.contains(content, "[debug] line one\n"))
	testing.expect(t, strings.contains(content, "[debug]   line two\n"))
}

@(test)
test_log_error_is_not_filtered_by_level :: proc(t: ^testing.T) {
	dir := test_temp_dir("logger-level-error")
	defer test_cleanup(dir)
	defer logger_reset()

	year, month, day, _, _, _ := local_now()
	log_file_init(dir)
	log_set_level(.Error)
	log_warn("warn is filtered out")
	log_error("error always wins")

	content := test_read_file(log_file_path(dir, year, month, day))
	testing.expect(t, !strings.contains(content, "warn is filtered out"))
	testing.expect(t, strings.contains(content, "[error] error always wins\n"))
}
