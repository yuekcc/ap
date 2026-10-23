package ap

import "../internal"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

sha256_hex :: proc(data: []byte) -> string {
	return internal.sha256_hex(data)
}

fnv32a_hex :: proc(data: []byte) -> string {
	return internal.fnv32a_hex(data)
}

normalize_slashes :: proc(path: string, allocator := context.allocator) -> string {
	return internal.normalize_slashes(path, allocator)
}

trim_trailing_slashes :: proc(path: string) -> string {
	return internal.trim_trailing_slashes(path)
}

// internal 只返回 message；ap 在边界处映射成自己的退出码。
internal_error_to_ap :: proc(err: internal.Error, code: Exit_Code = .Usage) -> Error {
	if internal.is_ok(err) {
		return ok_error()
	}
	return {code = code, message = err.message}
}

canonicalize_path :: proc(path: string, resolve_links := true) -> (string, Error) {
	value, err := internal.canonicalize_path(path, resolve_links)
	return value, internal_error_to_ap(err)
}

default_config_dir :: proc(cli_config_dir: Maybe(string)) -> (string, Error) {
	value, err := internal.default_config_dir(cli_config_dir)
	return value, internal_error_to_ap(err)
}

Project :: internal.Project

// ap 需要写入的 project 初始化：定位、确保 blobs 目录、补写 path.txt。
open_project :: proc(config_dir, cwd: string) -> (Project, Error) {
	project, perr := internal.locate_project(config_dir, cwd)
	if !internal.is_ok(perr) {
		return {}, internal_error_to_ap(perr)
	}
	if err := ensure_dir(project.blobs_dir); !is_ok(err) {
		return {}, err
	}

	path_file := fmt.tprintf("%s/path.txt", project.dir)
	if !os.exists(path_file) {
		content := fmt.tprintf("%s\n", project.root)
		content_bytes: []byte = transmute([]byte)content
		if werr := os.write_entire_file_from_bytes(path_file, content_bytes); werr != nil {
			return {}, make_error(.Usage, "cannot write %s: %v", path_file, werr)
		}
	}
	return project, ok_error()
}

session_file :: proc(p: Project, session_id: string) -> string {
	return internal.session_file(p, session_id)
}

blob_file :: proc(p: Project, sha: string) -> string {
	return internal.blob_file(p, sha)
}

expand_home :: proc(path: string) -> (string, Error) {
	if path == "~" || strings.has_prefix(path, "~/") || strings.has_prefix(path, `~\`) {
		home, herr := os.user_home_dir(context.allocator)
		if herr != nil {
			return "", make_error(.Usage, "cannot determine home directory")
		}
		if path == "~" {
			return home, ok_error()
		}
		rest := internal.normalize_slashes(path[2:], context.allocator)
		home_norm := internal.trim_trailing_slashes(internal.normalize_slashes(home, context.allocator))
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
			return "", make_error(.Usage, "cannot join path %q: %v", path, jerr)
		}
		combined = joined
	}
	clean, cerr := os.clean_path(combined, context.allocator)
	if cerr != nil {
		clean = combined
	}
	return internal.normalize_slashes(clean, context.allocator), ok_error()
}

// 工具用的路径解析：相对启动目录，支持 ~，不要求目标存在。
resolve_tool_path :: proc(cwd, path: string) -> (string, Error) {
	if len(path) == 0 {
		return "", make_error(.Usage, "path must not be empty")
	}
	when ODIN_OS == .Windows {
		if len(path) >= 3 && path[0] == '/' && path[2] == '/' {
			ch := path[1]
			if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') {
				return "", make_error(.Usage, "MSYS 路径不受支持，请使用 Win32 路径: %s", path)
			}
		}
	}
	return join_and_clean(cwd, path)
}

ensure_dir :: proc(dir: string) -> Error {
	if !os.is_dir(dir) {
		if err := os.make_directory_all(dir); err != nil {
			return make_error(.Usage, "cannot create directory %s: %v", dir, err)
		}
	}
	if !os.is_dir(dir) {
		return make_error(.Usage, "not a directory: %s", dir)
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
		return make_error(.Usage, "$AP_CONFIG is not writable: %s", dir)
	}
	os.remove(probe)
	return ok_error()
}

valid_utf8 :: proc(data: []byte) -> bool {
	return utf8.valid_string(string(data))
}
