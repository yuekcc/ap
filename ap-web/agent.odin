package main

import "../internal"
import "core:fmt"

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
