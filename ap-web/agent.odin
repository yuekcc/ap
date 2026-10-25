package main

import "../internal"
import "core:fmt"
import "core:strings"

// 把管道里的字节流切成完整行；一行 stdout 就是一个 stream-json 事件。
// 每次 feed 后压实缓冲，避免长 turn 的无界增长。
Line_Reader :: struct {
	buf:      [dynamic]u8,
	start:    int,
	callback: proc(user: rawptr, line: string),
	user:     rawptr,
}

line_reader_feed :: proc(lr: ^Line_Reader, chunk: []byte) {
	if len(chunk) > 0 {
		append(&lr.buf, ..chunk)
	}
	for {
		view := transmute(string)lr.buf[lr.start:]
		idx := strings.index_byte(view, '\n')
		if idx < 0 {
			break
		}
		line := view[:idx]
		lr.callback(lr.user, line)
		lr.start += idx + 1
	}
	if lr.start > 0 {
		remaining := len(lr.buf) - lr.start
		if remaining > 0 {
			copy(lr.buf[:], lr.buf[lr.start:])
		}
		resize(&lr.buf, remaining)
		lr.start = 0
	}
}

// 进程退出时把最后一截没有换行结尾的内容也交出去。
line_reader_flush :: proc(lr: ^Line_Reader) {
	if lr.start < len(lr.buf) {
		lr.callback(lr.user, transmute(string)lr.buf[lr.start:])
	}
	resize(&lr.buf, 0)
	lr.start = 0
}

// 一个 turn 的启动参数。runner（工单 04）用当前 project 与 session 指针填充，
// 每次 turn 都新建一个 ap 子进程。
Turn_Options :: struct {
	agent_bin:  string,
	session_id: string, // 为空时本轮让 ap 新建 session，之后从 session_start 捕获
	config_dir: string, // ap --config-dir
	cwd:        string, // ap 的工作目录，通常是 project.root
	model:      Maybe(string),
	agent:      Maybe(string),
	max_steps:  Maybe(int),
	max_tokens: Maybe(int),
	verbose:    bool,
}

// 与 ap-tui 完全一致：提示词走 stdin，stdout 输出 stream-json。
// 服务端白名单映射，不拼接 shell。
build_agent_command :: proc(options: ^Turn_Options) -> [dynamic]string {
	cmd := make([dynamic]string, 0, 16, context.allocator)
	append(&cmd, options.agent_bin)
	append(&cmd, "--print0")
	append(&cmd, "--output-format", "stream-json")
	if len(options.session_id) > 0 {
		append(&cmd, "-s", options.session_id)
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
