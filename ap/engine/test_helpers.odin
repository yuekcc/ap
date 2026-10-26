package engine

import "../platform"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

test_json :: proc(format: string, args: ..any) -> string {
	b := strings.builder_make()
	for ch in format {
		if ch == '{' || ch == '}' {
			strings.write_rune(&b, ch)
		}
		strings.write_rune(&b, ch)
	}
	return fmt.tprintf(strings.to_string(b), ..args)
}

test_temp_dir :: proc(prefix: string) -> string {
	base := os.get_env("TEMP", context.allocator)
	if len(base) == 0 {
		base = os.get_env("TMPDIR", context.allocator)
	}
	if len(base) == 0 {
		base = "."
	}
	name := fmt.tprintf("%s/ap-test-%s-%d", base, prefix, time.time_to_unix_nano(time.now()))
	os.make_directory_all(name)
	return name
}

test_write_file :: proc(path, content: string) {
	dir, _ := os.split_path(path)
	if len(dir) > 0 {
		os.make_directory_all(dir)
	}
	data := transmute([]byte)content
	if err := os.write_entire_file_from_bytes(path, data); err != nil {
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

test_cleanup :: proc(dir: string) {
	os.remove_all(dir)
}

test_contains :: proc(haystack, needle: string) -> bool {
	return strings.contains(haystack, needle)
}

json_concat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}

json_expect :: proc(t: ^testing.T, actual, expected: json.Value, loc := #caller_location) {
	testing.expect_value(t, platform.json_canonical_string(actual), platform.json_canonical_string(expected), loc = loc)
}
