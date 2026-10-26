package ap

// CLI/adapter 与 engine 迁移期的桥：本地包统一由 ap/platform 提供实现。
// 真正的实现在 ap/platform；这里只做退出码映射与少量转发。

import "platform"

sha256_hex :: platform.sha256_hex
fnv32a_hex :: platform.fnv32a_hex
normalize_slashes :: platform.normalize_slashes
trim_trailing_slashes :: platform.trim_trailing_slashes
valid_utf8 :: platform.valid_utf8
split_lines :: platform.split_lines
sanitize_utf8 :: platform.sanitize_utf8
utf8_prefix :: platform.utf8_prefix

json_marshal_utf8 :: platform.json_marshal_utf8
json_canonical_string :: platform.json_canonical_string
json_arguments_string :: platform.json_arguments_string
json_value_or_empty_object :: platform.json_value_or_empty_object
json_unescape_unicode :: platform.json_unescape_unicode

Cancel_Token :: platform.Cancel_Token
cancel_token_cancel :: platform.cancel_token_cancel
cancel_token_cancelled :: platform.cancel_token_cancelled

Job_Handle :: platform.Job_Handle
attach_process_job :: platform.attach_job
register_job :: platform.register_job
kill_process_tree :: platform.kill_process_tree
cleanup_jobs :: platform.cleanup_jobs

find_bash :: proc() -> (string, Error) {
	value, err := platform.find_bash()
	return value, platform_error_to_ap(err)
}
local_now :: platform.local_now
setup_console_utf8 :: platform.setup_console
normalize_cli_args :: platform.normalize_args

Project :: platform.Project
session_file :: platform.session_file
blob_file :: platform.blob_file

// platform 只返回 message；ap 在边界处映射成自己的退出码。
platform_error_to_ap :: proc(err: platform.Error, code: Exit_Code = .Usage) -> Error {
	if platform.is_ok(err) {
		return ok_error()
	}
	return {code = code, message = err.message}
}

canonicalize_path :: proc(path: string, resolve_links := true) -> (string, Error) {
	value, err := platform.canonicalize_path(path, resolve_links)
	return value, platform_error_to_ap(err)
}

default_config_dir :: proc(cli_config_dir: Maybe(string)) -> (string, Error) {
	value, err := platform.default_config_dir(cli_config_dir)
	return value, platform_error_to_ap(err)
}

locate_project :: proc(config_dir, cwd: string) -> (Project, Error) {
	value, err := platform.locate_project(config_dir, cwd)
	return value, platform_error_to_ap(err)
}

open_project :: proc(config_dir, cwd: string) -> (Project, Error) {
	value, err := platform.open_project(config_dir, cwd)
	return value, platform_error_to_ap(err)
}

expand_home :: proc(path: string) -> (string, Error) {
	value, err := platform.expand_home(path)
	return value, platform_error_to_ap(err)
}

join_and_clean :: proc(base, path: string) -> (string, Error) {
	value, err := platform.join_and_clean(base, path)
	return value, platform_error_to_ap(err)
}

resolve_tool_path :: proc(cwd, path: string) -> (string, Error) {
	value, err := platform.resolve_tool_path(cwd, path)
	return value, platform_error_to_ap(err)
}

ensure_dir :: proc(dir: string) -> Error {
	return platform_error_to_ap(platform.ensure_dir(dir))
}

ensure_writable_dir :: proc(dir: string) -> Error {
	return platform_error_to_ap(platform.ensure_writable_dir(dir))
}

blob_read :: proc(project: Project, sha: string, allocator := context.allocator) -> ([]byte, Error) {
	data, err := platform.blob_read(project, sha, allocator)
	return data, platform_error_to_ap(err)
}

blob_write :: proc(project: Project, data: []byte) -> (string, Error) {
	sha, err := platform.blob_write(project, data)
	return sha, platform_error_to_ap(err)
}

blob_write_text :: proc(project: Project, data: []byte) -> (string, Error) {
	path, err := platform.blob_write_text(project, data)
	return path, platform_error_to_ap(err)
}

// internal_error_to_ap 保留旧名字，供已有调用点使用。
internal_error_to_ap :: proc(err: platform.Error, code: Exit_Code = .Usage) -> Error {
	return platform_error_to_ap(err, code)
}
