package internal

import "core:os"

// ap 与 ap-tui 启动子进程时都需要定位自身可执行文件。
resolve_self_exe :: proc() -> string {
	if path, err := os.get_executable_path(context.allocator); err == nil && len(path) > 0 {
		return path
	}
	if len(os.args) > 0 {
		if resolved, err := os.get_absolute_path(os.args[0], context.allocator); err == nil {
			return resolved
		}
	}
	return os.args[0]
}
