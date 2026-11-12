package lineedit

import "core:fmt"
import "core:os"
import "core:time"

test_temp_dir :: proc(prefix: string) -> string {
	base := os.get_env("TEMP", context.allocator)
	if len(base) == 0 {
		base = os.get_env("TMPDIR", context.allocator)
	}
	if len(base) == 0 {
		base = "."
	}
	dir := fmt.aprintf("%s/lineedit-test-%s-%d", base, prefix, time.time_to_unix_nano(time.now()))
	os.make_directory_all(dir)
	return dir
}
