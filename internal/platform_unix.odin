#+build !windows
package internal

import "core:strings"
import "core:sys/posix"

real_path :: proc(path: string) -> (string, Error) {
	cpath, cerr := strings.clone_to_cstring(path, context.temp_allocator)
	if cerr != nil {
		return "", errorf("path too long: %s", path)
	}
	buf: [4096]byte
	res := posix.realpath(cpath, &buf[0])
	if res == nil {
		return "", errorf("realpath failed: %s", path)
	}
	return strings.clone_from_cstring(res) or_else "", ok_error()
}

setup_console :: proc() {
}

normalize_args :: proc(args: []string) -> []string {
	return args
}
