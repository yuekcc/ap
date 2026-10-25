package main

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_stderr_cache_keeps_recent_lines :: proc(t: ^testing.T) {
	log: [dynamic]u8
	defer delete(log)

	append_stderr_line(&log, "first line")
	append_stderr_line(&log, "second line")
	testing.expect_value(t, string(log[:]), "first line\nsecond line\n")

	body := strings.repeat("x", 80, context.temp_allocator)
	for i in 0 ..< 1000 {
		append_stderr_line(&log, fmt.tprintf("line-%04d-%s", i, body))
	}

	testing.expect(t, len(log) <= MAX_STDERR_BYTES)
	text := string(log[:])
	testing.expect(t, strings.contains(text, "line-0999-"))
	testing.expect(t, !strings.contains(text, "line-0000-"))
	testing.expect(t, text[0] != '\n')
}
