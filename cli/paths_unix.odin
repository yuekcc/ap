#+build !windows
package ap

import "core:strings"
import "core:sys/posix"

real_path :: proc(path: string) -> (string, Error) {
	cpath, cerr := strings.clone_to_cstring(path, context.temp_allocator)
	if cerr != nil {
		return "", make_error(.Usage, "path too long: %s", path)
	}
	buf: [4096]byte
	res := posix.realpath(cpath, &buf[0])
	if res == nil {
		return "", make_error(.Usage, "realpath failed: %s", path)
	}
	return strings.clone_from_cstring(res) or_else "", ok_error()
}
