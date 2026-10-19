package ap

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

BASH_TIMEOUT_MAX_MS :: 600000
BASH_COMMAND_MAX_CHARS :: 8000

find_bash :: proc() -> (string, Error) {
	if configured := os.get_env("AP_BASH", context.allocator); len(configured) > 0 {
		if os.exists(configured) {
			return configured, ok_error()
		}
		return "", make_error(.Usage, "AP_BASH points to a missing file: %s", configured)
	}

	path_env := os.get_env("PATH", context.allocator)
	when ODIN_OS == .Windows {
		separator := ";"
		exe_name := "bash.exe"
	} else {
		separator := ":"
		exe_name := "bash"
	}
	dirs, _ := strings.split(path_env, separator)
	for dir in dirs {
		if len(dir) == 0 {
			continue
		}
		candidate := fmt.tprintf("%s/%s", strings.trim_right(dir, `\/`), exe_name)
		when ODIN_OS == .Windows {
			lower, _ := strings.to_lower(candidate, context.temp_allocator)
			if strings.contains(lower, "windows\\system32") || strings.contains(lower, "windowsapps") {
				// WSL 的 bash.exe 不是 Git for Windows，跳过。
				continue
			}
		}
		if os.exists(candidate) {
			return candidate, ok_error()
		}
	}

	when ODIN_OS == .Windows {
		candidates := make([dynamic]string, 0, 4)
		append(&candidates, `C:\Program Files\Git\bin\bash.exe`)
		append(&candidates, `C:\Program Files (x86)\Git\bin\bash.exe`)
		if local := os.get_env("LOCALAPPDATA", context.allocator); len(local) > 0 {
			append(&candidates, fmt.tprintf("%s/Programs/Git/bin/bash.exe", local))
		}
		for candidate in candidates {
			if os.exists(candidate) {
				return candidate, ok_error()
			}
		}
	} else {
		for candidate in ([3]string{"/bin/bash", "/usr/bin/bash", "/usr/local/bin/bash"}) {
			if os.exists(candidate) {
				return candidate, ok_error()
			}
		}
	}
	return "", make_error(.Usage, "bash not found in PATH; install Git for Windows (or provide AP_BASH)")
}

resolve_self_exe :: proc() -> string {
	if path, err := os.get_executable_path(context.allocator); err == nil && len(path) > 0 {
		return path
	}
	if len(os.args) > 0 {
		if resolved, err := os.get_absolute_path(os.args[0], context.allocator); err == nil {
			return resolved
		}
	}
	return os.args[0]
}

bash_update :: proc(user: rawptr, chunk: string) {
	ctx := (^Tool_Context)(user)
	if ctx.on_update != nil {
		ctx.on_update(ctx.update_user, chunk)
	}
}

tool_bash :: proc(args: json.Object, ctx: ^Tool_Context) -> Tool_Result {
	command, cerr := tool_arg_string(args, "command")
	if !is_ok(cerr) {
		return arg_error(cerr)
	}
	if len(command) == 0 {
		return tool_fail("command must not be empty")
	}
	if utf8.rune_count(command) > BASH_COMMAND_MAX_CHARS {
		return tool_fail(fmt.tprintf("command exceeds %d characters", BASH_COMMAND_MAX_CHARS))
	}
	if len(command) > BASH_COMMAND_MAX_CHARS * 4 {
		return tool_fail("command is too long in bytes")
	}
	timeout_ms := min(ctx.settings.tool_timeout_ms, BASH_TIMEOUT_MAX_MS)
	if value, err := tool_arg_optional_int(args, "timeout_ms"); !is_ok(err) {
		return arg_error(err)
	} else if v, ok := value.?; ok {
		timeout_ms = v
	}
	if timeout_ms <= 0 {
		return tool_fail("timeout_ms must be positive")
	}
	if timeout_ms > BASH_TIMEOUT_MAX_MS {
		return tool_fail(fmt.tprintf("timeout_ms exceeds maximum (%d)", BASH_TIMEOUT_MAX_MS))
	}
	if len(ctx.bash_path) == 0 {
		return tool_fail("bash is not available")
	}

	env := filter_env_without("AP_API_KEY")
	result := run_child(
		{
			command = []string{ctx.bash_path, "-c", command},
			cwd = ctx.cwd,
			env = env,
			timeout_ms = timeout_ms,
			max_capture_bytes = ctx.settings.max_capture_bytes,
			cancel = ctx.cancel,
			on_stdout = bash_update,
			on_stderr = bash_update,
			user = ctx,
		},
	)
	defer free_run_result(&result)
	if !result.spawned {
		failed := tool_fail(result.error)
		failed.fatal = true
		return failed
	}
	if result.cancelled {
		return tool_fail("cancelled")
	}
	if result.timed_out {
		return tool_fail(fmt.tprintf("timeout after %dms", timeout_ms))
	}
	if result.overflow {
		return tool_fail(fmt.tprintf("output exceeded %d bytes", ctx.settings.max_capture_bytes))
	}
	if len(result.error) > 0 {
		failed := tool_fail(result.error)
		failed.fatal = true
		return failed
	}

	output := sanitize_utf8(result.combined)
	content := fmt.tprintf("[exit %d, %dms]\n%s", result.exit_code, result.duration_ms, output)
	res := tool_ok(content)
	res.exit_code = result.exit_code
	return res
}
