package main

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

@(test)
test_resolve_agent_bin_accepts_existing_file :: proc(t: ^testing.T) {
	base := os.get_env("TEMP", context.allocator)
	if len(base) == 0 {
		base = "."
	}
	dir := fmt.aprintf("%s/ap-web-test-agent-%d", base, time.time_to_unix_nano(time.now()))
	defer {
		os.remove_all(dir)
		delete(dir)
	}
	os.make_directory_all(dir)

	path := fmt.aprintf("%s/fake-ap.exe", dir)
	defer delete(path)
	testing.expect_value(t, os.write_entire_file_from_bytes(path, transmute([]byte)string("")), nil)

	resolved, err := resolve_agent_bin(path)
	defer delete(resolved)
	testing.expect_value(t, err.message, "")
	testing.expect(t, is_regular_file(resolved))
}

@(test)
test_resolve_agent_bin_reports_missing :: proc(t: ^testing.T) {
	_, err := resolve_agent_bin("ap-web-definitely-not-a-real-agent-binary")
	testing.expect(t, !is_ok(err))
	testing.expect(t, len(err.message) > 0)
}
