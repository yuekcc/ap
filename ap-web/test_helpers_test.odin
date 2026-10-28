package apweb

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
	dir := fmt.aprintf("%s/ap-web-test-%s-%d", base, prefix, time.time_to_unix_nano(time.now()))
	os.make_directory_all(dir)
	return dir
}

test_write_file :: proc(path, content: string) {
	dir, _ := os.split_path(path)
	if len(dir) > 0 {
		os.make_directory_all(dir)
	}
	if err := os.write_entire_file_from_bytes(path, transmute([]byte)content); err != nil {
		panic("failed to write test file")
	}
}

test_read_file :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		panic("failed to read test file")
	}
	return string(data)
}
