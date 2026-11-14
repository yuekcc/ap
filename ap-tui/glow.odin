package aptui

import client "../ap-core/client"

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// glow 渲染 assistant 的 Markdown。render 可注入，测试用它替代真实进程。
Glow_Render_Proc :: proc(text: string, width: int, color: bool) -> (string, client.Error)

Glow_Config :: struct {
	enabled: bool,
	// 传给 glow -w 的宽度；0 表示不指定，使用 glow 自己的默认值。
	width:   int,
	render:  Glow_Render_Proc,
}

// glow 从 stdin 读，输出走 stdout。调用方捕获后按原样写终端。
run_glow :: proc(text: string, width: int, color: bool) -> (string, client.Error) {
	temp_dir := os.get_env("TEMP", context.temp_allocator)
	if len(temp_dir) == 0 {
		temp_dir = os.get_env("TMPDIR", context.temp_allocator)
	}
	if len(temp_dir) == 0 {
		temp_dir = "."
	}
	path := fmt.tprintf(
		"%s/.ap-glow-%d-%d.md",
		temp_dir,
		os.get_pid(),
		time.time_to_unix_nano(time.now()),
	)
	file, ferr := os.open(path, {.Read, .Write, .Create, .Excl})
	if ferr != nil {
		return "", client.errorf("cannot create temporary markdown file %s: %v", path, ferr)
	}
	written := client.write_all(file, transmute([]byte)text)
	os.close(file)
	defer os.remove(path)
	if !written {
		return "", client.errorf("cannot write temporary markdown file %s", path)
	}

	input, ierr := os.open(path, {.Read, .Inheritable})
	if ierr != nil {
		return "", client.errorf("cannot open temporary markdown file %s: %v", path, ierr)
	}
	defer os.close(input)

	command := make([dynamic]string, 0, 6, context.temp_allocator)
	append(&command, "glow")
	if width > 0 {
		append(&command, "-w", fmt.tprintf("%d", width))
	}
	// stdout 是管道，glow 的 auto 风格会退化成无色；这里按 TUI 的颜色开关
	// 显式选择 dark / notty。
	append(&command, "-s", "dark" if color else "notty")
	append(&command, "-")

	state, out, errout, perr := os.process_exec(
		{command = command[:], stdin = input},
		context.temp_allocator,
	)
	if perr != nil {
		return "", client.errorf("cannot run glow: %v", perr)
	}
	if state.exit_code != 0 {
		message, _ := client.truncate_utf8(strings.trim_space(string(errout)), 200)
		return "", client.errorf("glow exited with code %d: %s", state.exit_code, message)
	}
	return string(out), client.ok_error()
}
