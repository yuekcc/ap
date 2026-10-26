package client

import "core:fmt"
import "core:os"
import "core:strings"

// 定位并拼装 ap 子进程。每轮 turn 都启动一个新的 ap 进程。

// 目录 ap/ 与 Unix 二进制 ap 同名；查找 agent 时必须排除目录。
is_regular_file :: proc(path: string) -> bool {
	info, err := os.stat(path, context.temp_allocator)
	return err == nil && info.type == .Regular
}

find_in_path :: proc(name: string) -> string {
	when ODIN_OS == .Windows {
		separator := ";"
		exts := []string{"", ".exe"}
	} else {
		separator := ":"
		exts := []string{""}
	}
	path_env := os.get_env("PATH", context.allocator)
	if len(path_env) == 0 {
		return ""
	}
	dirs, _ := strings.split(path_env, separator, context.temp_allocator)
	for dir in dirs {
		if len(dir) == 0 {
			continue
		}
		for ext in exts {
			candidate := fmt.tprintf("%s/%s%s", strings.trim_right(dir, `\/`), name, ext)
			if is_regular_file(candidate) {
				return strings.clone(candidate, context.allocator)
			}
		}
	}
	return ""
}

// 查找顺序：--agent-bin → AP_AGENT_BIN → AP_BIN → 自身同目录 ap → PATH。
resolve_agent_bin :: proc(configured: Maybe(string)) -> (string, Error) {
	if value, ok := configured.?; ok {
		if os.is_absolute_path(value) || strings.contains_rune(value, '/') || strings.contains_rune(value, '\\') {
			path, err := canonicalize_path(value, false)
			if is_ok(err) && is_regular_file(path) {
				return path, ok_error()
			}
			return "", errorf("agent binary not found: %s", value)
		}
		if found := find_in_path(value); len(found) > 0 {
			return found, ok_error()
		}
		return "", errorf("agent binary not found in PATH: %s", value)
	}

	for env_name in ([2]string{"AP_AGENT_BIN", "AP_BIN"}) {
		if value := os.get_env(env_name, context.allocator); len(value) > 0 {
			return resolve_agent_bin(value)
		}
	}

	exe := resolve_self_exe()
	dir, _ := os.split_path(exe)
	names := []string{"ap.exe"} when ODIN_OS == .Windows else []string{"ap"}
	for name in names {
		joined, _ := os.join_path([]string{dir, name}, context.allocator)
		if is_regular_file(joined) {
			return joined, ok_error()
		}
	}
	for name in names {
		if found := find_in_path(name); len(found) > 0 {
			return found, ok_error()
		}
	}
	return "", errorf("cannot find ap next to the current executable or in PATH; use --agent-bin")
}

// 提示词走 stdin，stdout 输出 stream-json。服务端白名单映射，不拼接 shell。
build_agent_command :: proc(options: ^Turn_Options, allocator := context.allocator) -> [dynamic]string {
	cmd := make([dynamic]string, 0, 16, allocator)
	append(&cmd, options.agent_bin)
	append(&cmd, "--print0")
	append(&cmd, "--output-format", "stream-json")
	if len(options.session_id) > 0 {
		append(&cmd, "-s", options.session_id)
	}
	if options.fork_session {
		append(&cmd, "--fork-session")
	}
	if value, ok := options.model.?; ok {
		append(&cmd, "--model", value)
	}
	if value, ok := options.agent.?; ok {
		append(&cmd, "--agent", value)
	}
	if value, ok := options.max_steps.?; ok {
		append(&cmd, "--max-steps", fmt.tprintf("%d", value))
	}
	if value, ok := options.max_tokens.?; ok {
		append(&cmd, "--max-tokens", fmt.tprintf("%d", value))
	}
	append(&cmd, "--config-dir", options.config_dir)
	if options.verbose {
		append(&cmd, "--verbose")
	}
	return cmd
}
