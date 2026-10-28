package platform

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

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
		// 保留 Windows 盘符根与 POSIX 根：Z:/ 、//
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

// 解析为绝对、清理过的路径；resolve_links 为 true 时解析符号链接/junction。
// project hash 依赖这套规则，ap 与 ap-tui 必须共用。
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

// 只定位 project，不创建目录、不写 path.txt。
// ap 需要写入时由调用方确保目录并补写；TUI 只读。
locate_project :: proc(config_dir, cwd: string) -> (Project, Error) {
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
			err := errorf(
				"project path conflict: %s contains %q but current path is %q",
				path_file,
				stored,
				root,
			)
			delete(data)
			return {}, err
		}
		delete(data)
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

blob_file :: proc(project: Project, sha256: string) -> string {
	return fmt.tprintf("%s/%s", project.blobs_dir, sha256)
}

// 可写初始化：定位 project、确保 blobs 目录、补写 path.txt。
// 只读的前端应使用 locate_project。
open_project :: proc(config_dir, cwd: string) -> (Project, Error) {
	project, perr := locate_project(config_dir, cwd)
	if !is_ok(perr) {
		return {}, perr
	}
	if err := ensure_dir(project.blobs_dir); !is_ok(err) {
		return {}, err
	}

	path_file := fmt.tprintf("%s/path.txt", project.dir)
	if !os.exists(path_file) {
		content := fmt.tprintf("%s\n", project.root)
		content_bytes: []byte = transmute([]byte)content
		if werr := os.write_entire_file_from_bytes(path_file, content_bytes); werr != nil {
			return {}, errorf("cannot write %s: %v", path_file, werr)
		}
	}
	return project, ok_error()
}

expand_home :: proc(path: string) -> (string, Error) {
	if path == "~" || strings.has_prefix(path, "~/") || strings.has_prefix(path, `~\`) {
		home, herr := os.user_home_dir(context.allocator)
		if herr != nil {
			return "", errorf("cannot determine home directory")
		}
		if path == "~" {
			return home, ok_error()
		}
		rest := normalize_slashes(path[2:], context.allocator)
		home_norm := trim_trailing_slashes(normalize_slashes(home, context.allocator))
		return fmt.tprintf("%s/%s", home_norm, rest), ok_error()
	}
	return path, ok_error()
}

join_and_clean :: proc(base, path: string) -> (string, Error) {
	expanded, eerr := expand_home(path)
	if !is_ok(eerr) {
		return "", eerr
	}
	combined := expanded
	if !os.is_absolute_path(expanded) {
		joined, jerr := os.join_path([]string{base, expanded}, context.allocator)
		if jerr != nil {
			return "", errorf("cannot join path %q: %v", path, jerr)
		}
		combined = joined
	}
	clean, cerr := os.clean_path(combined, context.allocator)
	if cerr != nil {
		clean = combined
	}
	return normalize_slashes(clean, context.allocator), ok_error()
}

// 工具用的路径解析：相对启动目录，支持 ~，不要求目标存在。
resolve_tool_path :: proc(cwd, path: string) -> (string, Error) {
	if len(path) == 0 {
		return "", errorf("path must not be empty")
	}
	when ODIN_OS == .Windows {
		if len(path) >= 3 && path[0] == '/' && path[2] == '/' {
			ch := path[1]
			if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') {
				return "", errorf("MSYS 路径不受支持，请使用 Win32 路径: %s", path)
			}
		}
	}
	return join_and_clean(cwd, path)
}

ensure_dir :: proc(dir: string) -> Error {
	if !os.is_dir(dir) {
		if err := os.make_directory_all(dir); err != nil {
			return errorf("cannot create directory %s: %v", dir, err)
		}
	}
	if !os.is_dir(dir) {
		return errorf("not a directory: %s", dir)
	}
	return ok_error()
}

ensure_writable_dir :: proc(dir: string) -> Error {
	if err := ensure_dir(dir); !is_ok(err) {
		return err
	}
	probe := fmt.tprintf("%s/.ap-write-test-%d-%d", dir, os.get_pid(), time.time_to_unix_nano(time.now()))
	probe_data: []byte = transmute([]byte)string("ok")
	if werr := os.write_entire_file_from_bytes(probe, probe_data); werr != nil {
		return errorf("$AP_CONFIG is not writable: %s", dir)
	}
	os.remove(probe)
	return ok_error()
}
