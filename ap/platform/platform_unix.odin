#+build !windows
package platform

import "core:strings"
import "core:sys/posix"
import "core:time"

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

local_now :: proc() -> (year, month, day, hour, minute, second: int) {
	stamp := posix.time_t(time.time_to_unix(time.now()))
	tm: posix.tm
	if posix.localtime_r(&stamp, &tm) == nil {
		return 1970, 1, 1, 0, 0, 0
	}
	return int(tm.tm_year + 1900), int(tm.tm_mon + 1), int(tm.tm_mday), int(tm.tm_hour), int(tm.tm_min), int(tm.tm_sec)
}
