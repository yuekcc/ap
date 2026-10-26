package main

import "../internal"
import "core:fmt"
import "core:os"
import "core:strings"

// 直接复用 internal 的路径、project 与 session 发现逻辑。
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

// 只读：不创建 project 目录，也不写 path.txt。
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

// 列出 config_dir 下所有已知 project（由 ap 写下的 path.txt 发现）。
// 目录不存在时返回空列表：新装环境里还没有任何会话是正常状态。
// 返回的 Project 字段由调用方 allocator 拥有；path.txt 与目录名（hash）
// 对不上的条目直接忽略，避免把陈旧/手改的目录当成另一个 project。
list_projects :: proc(config_dir: string) -> ([]Project, Error) {
	projects_dir := fmt.aprintf("%s/projects", config_dir)
	entries, derr := os.read_directory_by_path(projects_dir, -1, context.allocator)
	if derr != nil {
		if !os.is_dir(projects_dir) {
			return nil, ok_error()
		}
		return nil, errorf("cannot list projects directory %s: %v", projects_dir, derr)
	}
	defer os.file_info_slice_delete(entries, context.allocator)

	out := make([dynamic]Project, 0, len(entries))
	for entry in entries {
		if entry.type != .Directory {
			continue
		}
		path_file := fmt.tprintf("%s/%s/path.txt", projects_dir, entry.name)
		data, rerr := os.read_entire_file_from_path(path_file, context.allocator)
		if rerr != nil {
			continue
		}
		stored := strings.trim_space(string(data))
		if len(stored) == 0 {
			delete(data)
			continue
		}
		// open_project 会读取并规范化 stored；必须先调用再释放 data，
		// 否则 stored 是悬空切片，可能让两个 project 指向同一份内存。
		project, perr := open_project(config_dir, stored)
		delete(data)
		if !is_ok(perr) || project.hash != entry.name || !os.is_dir(project.root) {
			continue
		}
		append(&out, project)
	}
	return out[:], ok_error()
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
