package ap

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

sha256_hex :: proc(data: []byte) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	hash: [32]byte
	sha2.final(&ctx, hash[:])
	encoded, _ := hex.encode(hash[:], context.allocator)
	return string(encoded)
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

// canonicalize_path 解析为绝对、清理过的路径；resolve_links 为 true 时解析符号链接/junction。
canonicalize_path :: proc(path: string, resolve_links := true) -> (string, Error) {
	abs, aerr := os.get_absolute_path(path, context.allocator)
	if aerr != nil {
		return "", make_error(.Usage, "cannot resolve path %q: %v", path, aerr)
	}
	clean, cerr := os.clean_path(abs, context.allocator)
	if cerr != nil {
		clean = abs
	}

	real := clean
	if resolve_links {
		resolved, rerr := real_path(clean)
		if rerr.code == .OK && len(resolved) > 0 {
			real = resolved
		} else if rerr.code != .OK && os.exists(clean) {
			// 目录句柄可能因权限失败；存在时接受清理后的路径。
			log_debug("real path failed for %s: %s", clean, rerr.message)
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

expand_home :: proc(path: string) -> (string, Error) {
	if path == "~" || strings.has_prefix(path, "~/") || strings.has_prefix(path, `~\`) {
		home, herr := os.user_home_dir(context.allocator)
		if herr != nil {
			return "", make_error(.Usage, "cannot determine home directory")
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
			return "", make_error(.Usage, "cannot join path %q: %v", path, jerr)
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

default_config_dir :: proc(cli_config_dir: Maybe(string)) -> (string, Error) {
	if dir, ok := cli_config_dir.?; ok {
		return canonicalize_path(dir, false)
	}
	if env := os.get_env("AP_CONFIG", context.allocator); len(env) > 0 {
		return canonicalize_path(env, false)
	}
	home, herr := os.user_home_dir(context.allocator)
	if herr != nil {
		return "", make_error(.Usage, "cannot determine home directory for $AP_CONFIG")
	}
	joined, _ := os.join_path([]string{home, ".ap"}, context.allocator)
	return canonicalize_path(joined, false)
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

Project :: struct {
	config_dir: string,
	root:       string,
	hash:       string,
	dir:        string,
	blobs_dir:  string,
}

open_project :: proc(config_dir, cwd: string) -> (Project, Error) {
	root, rerr := canonicalize_path(cwd, true)
	if !is_ok(rerr) {
		return {}, rerr
	}
	hash := sha256_hex(transmute([]byte)root)
	project_dir := fmt.tprintf("%s/projects/%s", config_dir, hash)
	blobs_dir := fmt.tprintf("%s/blobs", project_dir)
	if err := ensure_dir(blobs_dir); !is_ok(err) {
		return {}, err
	}

	path_file := fmt.tprintf("%s/path.txt", project_dir)
	if data, derr := os.read_entire_file_from_path(path_file, context.allocator); derr == nil {
		stored := strings.trim_space(string(data))
		if stored != root {
			return {}, make_error(
				.Usage,
				"project path conflict: %s contains %q but current path is %q",
				path_file,
				stored,
				root,
			)
		}
	} else {
		content := fmt.tprintf("%s\n", root)
		content_bytes: []byte = transmute([]byte)content
		if werr := os.write_entire_file_from_bytes(path_file, content_bytes); werr != nil {
			return {}, make_error(.Usage, "cannot write %s: %v", path_file, werr)
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

session_file :: proc(p: Project, session_id: string) -> string {
	return fmt.tprintf("%s/%s.jsonl", p.dir, session_id)
}

blob_file :: proc(p: Project, sha: string) -> string {
	return fmt.tprintf("%s/blobs/%s", p.dir, sha)
}

valid_utf8 :: proc(data: []byte) -> bool {
	return utf8.valid_string(string(data))
}
