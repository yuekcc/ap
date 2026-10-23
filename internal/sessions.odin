package internal

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:time"

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

// session 发现只需要 session_start 的两个字段，不需要完整事件 schema。
Session_Start_Probe :: struct {
	type:              string         `json:"type"`,
	parent_session_id: Maybe(string) `json:"parent_session_id"`,
}

// 返回 project 目录下的 session id；目录不存在时返回空列表而不是错误。
// 返回的 id 由调用方负责释放。
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
		ev: Session_Start_Probe
		if json.unmarshal(transmute([]byte)line, &ev, json.DEFAULT_SPECIFICATION, context.temp_allocator) == nil {
			if ev.type == "session_start" {
				_, is_parent := ev.parent_session_id.?
				last_is_parent = is_parent
				found = true
			}
		}
		free_all(context.temp_allocator)
	}
	if !found {
		return false, 0, errorf("session %s has no session_start", session_id)
	}
	mtime := time.time_to_unix_nano(info.modification_time)
	return !last_is_parent, mtime, ok_error()
}

// 返回最近的根 session id（调用方拥有返回的字符串）。
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
