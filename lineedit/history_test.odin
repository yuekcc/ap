package lineedit

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
test_history_empty :: proc(t: ^testing.T) {
	h: History
	history_init(&h)
	defer history_destroy(&h)

	testing.expect_value(t, history_len(&h), 0)
	_, ok := history_prev(&h, "draft")
	testing.expect(t, !ok)
	_, ok = history_next(&h, "draft")
	testing.expect(t, !ok)
}

@(test)
test_history_navigate :: proc(t: ^testing.T) {
	h: History
	history_init(&h)
	defer history_destroy(&h)

	testing.expect(t, history_add(&h, "one"))
	testing.expect(t, history_add(&h, "two"))
	testing.expect_value(t, history_len(&h), 2)

	got, ok := history_prev(&h, "draft")
	testing.expect(t, ok)
	testing.expect_value(t, got, "two")
	got, ok = history_prev(&h, "draft")
	testing.expect(t, ok)
	testing.expect_value(t, got, "one")
	// 到顶后继续按上键，仍停在最旧的一条。
	got, ok = history_prev(&h, "draft")
	testing.expect(t, ok)
	testing.expect_value(t, got, "one")

	got, ok = history_next(&h, "draft")
	testing.expect(t, ok)
	testing.expect_value(t, got, "two")
	got, ok = history_next(&h, "draft")
	testing.expect(t, ok)
	testing.expect_value(t, got, "draft")
	_, ok = history_next(&h, "draft")
	testing.expect(t, !ok)
}

@(test)
test_history_add_rules :: proc(t: ^testing.T) {
	h: History
	history_init(&h)
	defer history_destroy(&h)

	testing.expect(t, !history_add(&h, ""))
	testing.expect_value(t, history_len(&h), 0)

	testing.expect(t, history_add(&h, "a"))
	testing.expect(t, !history_add(&h, "a")) // 连续重复不重复入栈
	testing.expect_value(t, history_len(&h), 1)

	testing.expect(t, history_add(&h, "b"))
	testing.expect(t, history_add(&h, "a"))
	testing.expect_value(t, history_len(&h), 3)
}

@(test)
test_history_max_len :: proc(t: ^testing.T) {
	h: History
	history_init(&h, 2)
	defer history_destroy(&h)

	history_add(&h, "a")
	history_add(&h, "b")
	history_add(&h, "c")
	testing.expect_value(t, history_len(&h), 2)

	got, _ := history_prev(&h, "")
	testing.expect_value(t, got, "c")
	got, _ = history_prev(&h, "")
	testing.expect_value(t, got, "b")
}

@(test)
test_history_multiline :: proc(t: ^testing.T) {
	h: History
	history_init(&h)
	defer history_destroy(&h)

	history_add(&h, "line1\nline2")
	got, ok := history_prev(&h, "")
	testing.expect(t, ok)
	testing.expect_value(t, got, "line1\nline2")
}

@(test)
test_history_save_load :: proc(t: ^testing.T) {
	dir := test_temp_dir("history")
	defer {
		os.remove_all(dir)
		delete(dir)
	}
	path := fmt.aprintf("%s/history", dir)
	defer delete(path)

	h: History
	history_init(&h)
	defer history_destroy(&h)
	history_add(&h, "one")
	history_add(&h, "two\nlines")
	history_add(&h, "中文")
	testing.expect(t, history_save(&h, path))

	h2: History
	history_init(&h2)
	defer history_destroy(&h2)
	testing.expect(t, history_load(&h2, path))
	testing.expect_value(t, history_len(&h2), 3)

	got, ok := history_prev(&h2, "")
	testing.expect(t, ok)
	testing.expect_value(t, got, "中文")
	got, ok = history_prev(&h2, "")
	testing.expect(t, ok)
	testing.expect_value(t, got, "two\nlines")
	got, ok = history_prev(&h2, "")
	testing.expect(t, ok)
	testing.expect_value(t, got, "one")
}

@(test)
test_history_load_missing_file :: proc(t: ^testing.T) {
	h: History
	history_init(&h)
	defer history_destroy(&h)
	testing.expect(t, !history_load(&h, "this-file-should-not-exist-history"))
	testing.expect_value(t, history_len(&h), 0)
}

@(test)
test_history_load_empty_and_append :: proc(t: ^testing.T) {
	dir := test_temp_dir("history-empty")
	defer {
		os.remove_all(dir)
		delete(dir)
	}
	path := fmt.aprintf("%s/history", dir)
	defer delete(path)

	testing.expect(t, os.write_entire_file_from_bytes(path, []u8{}) == nil)

	h: History
	history_init(&h)
	defer history_destroy(&h)
	testing.expect(t, history_load(&h, path))
	testing.expect_value(t, history_len(&h), 0)

	history_add(&h, "existing")
	content := "new\n"
	testing.expect(t, os.write_entire_file_from_bytes(path, transmute([]u8)content) == nil)
	testing.expect(t, history_load(&h, path))
	testing.expect_value(t, history_len(&h), 2)
}

@(test)
test_history_reset :: proc(t: ^testing.T) {
	h: History
	history_init(&h)
	defer history_destroy(&h)
	history_add(&h, "one")

	_, ok := history_prev(&h, "draft")
	testing.expect(t, ok)
	history_reset(&h)

	_, ok = history_next(&h, "draft")
	testing.expect(t, !ok)
	got, ok2 := history_prev(&h, "new draft")
	testing.expect(t, ok2)
	testing.expect_value(t, got, "one")
}
