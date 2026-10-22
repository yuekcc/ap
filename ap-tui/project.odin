package tui

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// TUI 侧的轻量错误类型：空 message 表示成功。
Error :: struct {
	message: string,
}

ok_error :: proc() -> Error {
	return {}
}

errorf :: proc(format: string, args: ..any) -> Error {
	return {message = fmt.tprintf(format, ..args)}
}

is_ok :: proc(err: Error) -> bool {
	return len(err.message) == 0
}

fnv32a_hex :: proc(data: []byte) -> string {
	hash: u32 = 2166136261
	for b in data {
		hash = (hash ~ u32(b)) * 16777619
	}
	return fmt.aprintf("%08x", hash)
}

normalize_slashes :: proc(path: string, allocator := context.allocator) -> string {
	if !strings.contains_rune(path, '\\') {
		return strings.clone(path, allocator)
	}
	buf := make([]byte, len(path), allocator)
	for i in 0 ..< len(path) {
		buf[i] = '/' if path[i] == '\\' else path[i]
	}
	return string(buf)
}

trim_trailing_slashes :: proc(path: string) -> string {
	n := len(path)
	for n > 1 && path[n - 1] == '/' {
		if n == 3 && path[1] == ':' {
			break
		}
		if n == 2 && path[0] == '/' {
			break
		}
		n -= 1
	}
	return path[:n]
}

// 与 ap 的 canonicalize_path 保持同一套规则，否则 project hash 对不上。
canonicalize_path :: proc(path: string, resolve_links := true) -> (string, Error) {
	abs, aerr := os.get_absolute_path(path, context.allocator)
	if aerr != nil {
		return "", errorf("cannot resolve path %q: %v", path, aerr)
	}
	clean, cerr := os.clean_path(abs, context.allocator)
	if cerr != nil {
		clean = abs
	}

	real := clean
	if resolve_links {
		resolved, rerr := real_path(clean)
		if is_ok(rerr) && len(resolved) > 0 {
			real = resolved
		}
	}

	norm := normalize_slashes(real, context.allocator)
	norm = trim_trailing_slashes(norm)
	when ODIN_OS == .Windows {
		lower, _ := strings.to_lower(norm, context.allocator)
		norm = lower
	}
	return norm, ok_error()
}

default_config_dir :: proc(cli_config_dir: Maybe(string)) -> (string, Error) {
	if dir, ok := cli_config_dir.?; ok {
		return canonicalize_path(dir, false)
	}
	if env := os.get_env("AP_CONFIG", context.allocator); len(env) > 0 {
		return canonicalize_path(env, false)
	}
	home, herr := os.user_home_dir(context.allocator)
	if herr != nil {
		return "", errorf("cannot determine home directory for $AP_CONFIG")
	}
	joined, _ := os.join_path([]string{home, ".ap"}, context.allocator)
	return canonicalize_path(joined, false)
}

Project :: struct {
	config_dir: string,
	root:       string,
	hash:       string,
	dir:        string,
	blobs_dir:  string,
}

// 只定位 project，不创建目录；第一次真正运行时由 ap 负责创建。
open_project :: proc(config_dir, cwd: string) -> (Project, Error) {
	root, rerr := canonicalize_path(cwd, true)
	if !is_ok(rerr) {
		return {}, rerr
	}
	hash := fnv32a_hex(transmute([]byte)root)
	project_dir := fmt.aprintf("%s/projects/%s", config_dir, hash)
	blobs_dir := fmt.aprintf("%s/blobs", project_dir)

	path_file := fmt.aprintf("%s/path.txt", project_dir)
	if data, derr := os.read_entire_file_from_path(path_file, context.allocator); derr == nil {
		stored := strings.trim_space(string(data))
		if stored != root {
			return {}, errorf(
				"project path conflict: %s contains %q but current path is %q",
				path_file,
				stored,
				root,
			)
		}
	}

	return {
		config_dir = config_dir,
		root = root,
		hash = hash,
		dir = project_dir,
		blobs_dir = blobs_dir,
	}, ok_error()
}

session_file :: proc(project: Project, session_id: string) -> string {
	return fmt.tprintf("%s/%s.jsonl", project.dir, session_id)
}

Line_Iterator :: struct {
	data: string,
	pos:  int,
}

next_line :: proc(it: ^Line_Iterator) -> (line: string, ok: bool) {
	if it.pos >= len(it.data) {
		return "", false
	}
	rest := it.data[it.pos:]
	idx := strings.index_byte(rest, '\n')
	if idx < 0 {
		it.pos = len(it.data)
		return rest, true
	}
	it.pos += idx + 1
	return rest[:idx], true
}

blob_read :: proc(project: Project, sha256: string, allocator := context.allocator) -> ([]byte, Error) {
	path := fmt.tprintf("%s/%s", project.blobs_dir, sha256)
	data, err := os.read_entire_file_from_path(path, allocator)
	if err != nil {
		return nil, errorf("cannot read blob %s: %v", sha256, err)
	}
	return data, ok_error()
}

// 返回 project 目录下的 session id；目录不存在时返回空列表而不是错误。
session_ids :: proc(project: Project) -> ([]string, Error) {
	entries, derr := os.read_directory_by_path(project.dir, -1, context.allocator)
	if derr != nil {
		if !os.is_dir(project.dir) {
			return nil, ok_error()
		}
		return nil, errorf("cannot list project directory %s: %v", project.dir, derr)
	}
	defer os.file_info_slice_delete(entries, context.allocator)

	ids := make([dynamic]string, 0, 8)
	for entry in entries {
		if entry.type != .Regular {
			continue
		}
		if strings.has_suffix(entry.name, ".jsonl") {
			append(&ids, strings.clone(entry.name[:len(entry.name) - 6], context.allocator))
		}
	}
	return ids[:], ok_error()
}

session_is_root :: proc(project: Project, session_id: string) -> (bool, i64, Error) {
	path := session_file(project, session_id)
	info, serr := os.stat(path, context.allocator)
	if serr != nil {
		return false, 0, errorf("cannot stat %s: %v", path, serr)
	}

	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		return false, 0, errorf("cannot read %s: %v", path, rerr)
	}
	defer delete(data)

	last_is_parent := false
	found := false
	it := Line_Iterator{data = string(data)}
	for {
		line, more := next_line(&it)
		if !more {
			break
		}
		ev, parsed := parse_event_line(line)
		if !parsed {
			free_all(context.temp_allocator)
			continue
		}
		if ev.type == "session_start" {
			_, is_parent := ev.parent_session_id.?
			last_is_parent = is_parent
			found = true
		}
		free_all(context.temp_allocator)
	}
	if !found {
		return false, 0, errorf("session %s has no session_start", session_id)
	}
	mtime := time.time_to_unix_nano(info.modification_time)
	return !last_is_parent, mtime, ok_error()
}

find_latest_root_session :: proc(project: Project) -> (string, Error) {
	ids, ierr := session_ids(project)
	if !is_ok(ierr) {
		return "", ierr
	}
	defer {
		for id in ids {
			delete(id, context.allocator)
		}
		delete(ids)
	}

	best := ""
	best_time: i64 = -1
	for id in ids {
		is_root, mtime, rerr := session_is_root(project, id)
		if !is_ok(rerr) {
			continue
		}
		if is_root && mtime > best_time {
			best = id
			best_time = mtime
		}
	}
	if len(best) == 0 {
		return "", errorf("no root session found in project %s", project.hash)
	}
	return strings.clone(best, context.allocator), ok_error()
}

read_transcript :: proc(project: Project, session_id: string) -> ([]byte, Error) {
	path := session_file(project, session_id)
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return nil, errorf("cannot read session %s: %v", session_id, err)
	}
	return data, ok_error()
}
