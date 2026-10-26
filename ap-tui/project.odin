package tui

import "../ap/platform"

// TUI 直接复用 internal 的路径、project 与 session 发现逻辑。
// 这些规则必须与 ap 完全一致，否则 -c/-s 会找不到 transcript。

Error :: platform.Error

ok_error :: proc() -> Error {
	return platform.ok_error()
}

errorf :: proc(format: string, args: ..any) -> Error {
	return platform.errorf(format, ..args)
}

is_ok :: proc(err: Error) -> bool {
	return platform.is_ok(err)
}

fnv32a_hex :: proc(data: []byte) -> string {
	return platform.fnv32a_hex(data)
}

canonicalize_path :: proc(path: string, resolve_links := true) -> (string, Error) {
	return platform.canonicalize_path(path, resolve_links)
}

default_config_dir :: proc(cli_config_dir: Maybe(string)) -> (string, Error) {
	return platform.default_config_dir(cli_config_dir)
}

Project :: platform.Project

// TUI 只读：不创建 project 目录，也不写 path.txt。
open_project :: proc(config_dir, cwd: string) -> (Project, Error) {
	return platform.locate_project(config_dir, cwd)
}

session_file :: proc(project: Project, session_id: string) -> string {
	return platform.session_file(project, session_id)
}

blob_read :: proc(project: Project, sha256: string, allocator := context.allocator) -> ([]byte, Error) {
	return platform.blob_read(project, sha256, allocator)
}

session_ids :: proc(project: Project) -> ([]string, Error) {
	return platform.session_ids(project)
}

session_is_root :: proc(project: Project, session_id: string) -> (bool, i64, Error) {
	return platform.session_is_root(project, session_id)
}

find_latest_root_session :: proc(project: Project) -> (string, Error) {
	return platform.find_latest_root_session(project)
}

read_transcript :: proc(project: Project, session_id: string) -> ([]byte, Error) {
	return platform.read_transcript(project, session_id)
}

Line_Iterator :: platform.Line_Iterator

next_line :: proc(it: ^Line_Iterator) -> (line: string, ok: bool) {
	return platform.next_line(it)
}
