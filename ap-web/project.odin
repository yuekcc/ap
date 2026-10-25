package main

import "../internal"

// TUI 直接复用 internal 的路径、project 与 session 发现逻辑。
// 这些规则必须与 ap 完全一致，否则 -c/-s 会找不到 transcript。

Error :: internal.Error

ok_error :: proc() -> Error {
	return internal.ok_error()
}

errorf :: proc(format: string, args: ..any) -> Error {
	return internal.errorf(format, ..args)
}

is_ok :: proc(err: Error) -> bool {
	return internal.is_ok(err)
}

fnv32a_hex :: proc(data: []byte) -> string {
	return internal.fnv32a_hex(data)
}

canonicalize_path :: proc(path: string, resolve_links := true) -> (string, Error) {
	return internal.canonicalize_path(path, resolve_links)
}

default_config_dir :: proc(cli_config_dir: Maybe(string)) -> (string, Error) {
	return internal.default_config_dir(cli_config_dir)
}

Project :: internal.Project

// TUI 只读：不创建 project 目录，也不写 path.txt。
open_project :: proc(config_dir, cwd: string) -> (Project, Error) {
	return internal.locate_project(config_dir, cwd)
}

session_file :: proc(project: Project, session_id: string) -> string {
	return internal.session_file(project, session_id)
}

blob_file :: proc(project: Project, sha256: string) -> string {
	return internal.blob_file(project, sha256)
}

blob_read :: proc(project: Project, sha256: string, allocator := context.allocator) -> ([]byte, Error) {
	return internal.blob_read(project, sha256, allocator)
}

session_ids :: proc(project: Project) -> ([]string, Error) {
	return internal.session_ids(project)
}

session_is_root :: proc(project: Project, session_id: string) -> (bool, i64, Error) {
	return internal.session_is_root(project, session_id)
}

find_latest_root_session :: proc(project: Project) -> (string, Error) {
	return internal.find_latest_root_session(project)
}

read_transcript :: proc(project: Project, session_id: string) -> ([]byte, Error) {
	return internal.read_transcript(project, session_id)
}

Line_Iterator :: internal.Line_Iterator

next_line :: proc(it: ^Line_Iterator) -> (line: string, ok: bool) {
	return internal.next_line(it)
}
