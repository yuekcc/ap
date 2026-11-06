package platform

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// 文件日志是全局状态，每个用例结束都要清掉，避免影响同包其它测试。
logger_reset :: proc() {
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
