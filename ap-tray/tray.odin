package aptray

import "core:strings"

WEB_URL :: "http://127.0.0.1:8417"
WEB_EXE :: "ap-web.exe"
TRAY_TIP :: "ap"

web_exe_path :: proc(dir: string) -> string {
	return strings.concatenate({dir, "\\", WEB_EXE}, context.temp_allocator)
}

// CreateProcessW 按空格切分命令行；ap-tray 只传一个可执行文件路径，
// 加引号就能处理 Program Files 这类含空格的目录（路径里不会出现双引号）。
web_command_line :: proc(exe_path: string) -> string {
	return strings.concatenate({`"`, exe_path, `"`}, context.temp_allocator)
}
