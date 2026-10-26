package client

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
test_resolve_agent_bin_accepts_existing_file :: proc(t: ^testing.T) {
	dir := test_temp_dir("agent-bin")
	defer os.remove_all(dir)

	suffix := ""
	when ODIN_OS == .Windows {
		suffix = ".exe"
	}
	path := fmt.tprintf("%s/fake-ap%s", dir, suffix)
	testing.expect_value(t, os.write_entire_file_from_bytes(path, transmute([]byte)string("")), nil)

	resolved, err := resolve_agent_bin(path)
	defer delete(resolved)
	testing.expect_value(t, err.message, "")
	testing.expect(t, is_regular_file(resolved))
}

@(test)
test_resolve_agent_bin_reports_missing :: proc(t: ^testing.T) {
	_, err := resolve_agent_bin("ap-definitely-not-a-real-agent-binary")
	testing.expect(t, !is_ok(err))
	testing.expect(t, len(err.message) > 0)
}
