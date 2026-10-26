package client

import "../platform"
import "core:fmt"
import "core:os"
import "core:strings"

// 只读的 project / session / blob 访问。前端历史、侧栏、续聊都走这里；
// 这些规则必须与 ap 完全一致，否则 -c/-s 会找不到 transcript。

fnv32a_hex :: platform.fnv32a_hex
sha256_hex :: platform.sha256_hex
normalize_slashes :: platform.normalize_slashes
canonicalize_path :: platform.canonicalize_path
default_config_dir :: platform.default_config_dir
locate_project :: platform.locate_project
session_file :: platform.session_file
blob_file :: platform.blob_file
blob_read :: platform.blob_read
session_ids :: platform.session_ids
session_is_root :: platform.session_is_root
find_latest_root_session :: platform.find_latest_root_session
read_transcript :: platform.read_transcript

setup_console :: platform.setup_console
normalize_args :: platform.normalize_args
resolve_self_exe :: platform.resolve_self_exe
write_all :: platform.write_all

Line_Iterator :: platform.Line_Iterator
next_line :: platform.next_line

// 列出 config_dir 下所有已知 project（由 ap 写下的 path.txt 发现）。
// 目录不存在时返回空列表：新装环境里还没有任何会话是正常状态。
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
		// locate_project 会读取并规范化 stored；必须先调用再释放 data，
		// 否则 stored 是悬空切片，可能让两个 project 指向同一份内存。
		project, perr := locate_project(config_dir, stored)
		delete(data)
		if !is_ok(perr) || project.hash != entry.name || !os.is_dir(project.root) {
			continue
		}
		append(&out, project)
	}
	return out[:], ok_error()
}
