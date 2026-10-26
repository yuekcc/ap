package engine

import "../platform"

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

BASH_TIMEOUT_MAX_MS :: 600000
BASH_COMMAND_MAX_CHARS :: 8000
BASH_OUTPUT_MAX_LINES :: 2000

// 返回前 max_lines 行（保留行尾换行）以及输出总行数。
bash_output_prefix :: proc(text: string, max_lines: int) -> (string, int) {
	total := count_text_lines(text)
	if total <= max_lines {
		return text, total
	}
	line := 1
	for i in 0 ..< len(text) {
		if text[i] == '\n' {
			line += 1
			if line == max_lines + 1 {
				return text[:i + 1], total
			}
		}
	}
	return text, total
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

	output := platform.sanitize_utf8(result.combined)
	preview, total_lines := bash_output_prefix(output, BASH_OUTPUT_MAX_LINES)
	b := strings.builder_make()
	fmt.sbprintf(&b, "[exit %d, %dms]\n", result.exit_code, result.duration_ms)
	strings.write_string(&b, preview)
	if total_lines > BASH_OUTPUT_MAX_LINES {
		if len(preview) == 0 || preview[len(preview) - 1] != '\n' {
			strings.write_byte(&b, '\n')
		}
		path, werr := blob_write_text(ctx.project, transmute([]byte)output)
		if is_ok(werr) {
			fmt.sbprintf(
				&b,
				"[共 %d 行，已返回 1-%d；完整输出已保存到 %s；继续请用 read_file(file_path=%q, start_line=%d)]",
				total_lines,
				BASH_OUTPUT_MAX_LINES,
				path,
				path,
				BASH_OUTPUT_MAX_LINES + 1,
			)
		} else {
			fmt.sbprintf(
				&b,
				"[共 %d 行，已返回 1-%d；完整输出保存失败: %s]",
				total_lines,
				BASH_OUTPUT_MAX_LINES,
				werr.message,
			)
		}
	}
	res := tool_ok(strings.to_string(b))
	res.exit_code = result.exit_code
	return res
}
