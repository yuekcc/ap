package apcore

import "platform"
import "protocol"
import "core:fmt"
import "core:os"

VERSION :: protocol.VERSION

Exit_Code :: enum int {
	OK       = 0,
	Internal = 1,
	Usage    = 2,
	Provider = 3,
	Tool     = 4,
	Sigint   = 130,
	Sigterm  = 143,
}

Error :: struct {
	code:    Exit_Code,
	message: string,
}

ok_error :: proc() -> Error {
	return {code = .OK, message = ""}
}

make_error :: proc(code: Exit_Code, format: string, args: ..any) -> Error {
	return {code = code, message = fmt.tprintf(format, ..args)}
}

is_ok :: proc(err: Error) -> bool {
	return err.code == .OK
}

log_error :: proc(format: string, args: ..any) {
	fmt.eprintf("ap: error: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
}

write_all_to :: proc(handle: ^os.File, data: []byte) -> bool {
	return platform.write_all(handle, data)
}

write_stdout :: proc(data: []byte) -> bool {
	return write_all_to(os.stdout, data)
}

write_stderr :: proc(data: []byte) -> bool {
	return write_all_to(os.stderr, data)
}

USAGE_TEXT :: `ap - 一次性命令行 coding agent

用法:
  ap --print <提示词> [选项]   # -p 为 --print 的别名
  ap --input-file <文件> [选项]
  ap --print0 [选项]          # 0 = stdin，读取到 EOF
  ap [选项]                    # stdin 不是 TTY 时读取 stdin

会话:
  -s, --session <id>          恢复当前项目内的指定 session
  -c, --continue              恢复当前项目内最近的根 session
      --fork-session          与 -s / -c 连用，复制历史到新 session

agent 与模型:
      --agent <name>          使用 $AP_CONFIG/agents/<name>.md 或内置 general
      --model <id>            覆盖配置中的 model（恢复 session 时只警告）
      --max-steps <n>         单个 turn 的最大 step 数
      --max-tokens <n>        单次响应的 max_tokens
      --append-system-prompt <text>
                              追加到 system prompt（恢复 session 时只警告）
      --config-dir <path>     设置 $AP_CONFIG，默认 ~/.ap（--workspace 为别名）

输出:
      --output-format <fmt>   text | json | stream-json，默认 text
      --verbose               输出 info 日志到 stderr
      --debug                 输出 debug 日志到 stderr
      --print-system-prompt   打印本次使用的 system prompt 后退出
      --help                  显示帮助
      --version               显示版本

技能:
      --list-skills           列出当前目录可见的 skill 后退出（不读配置、不需要 API key）

子代理内部参数:
      --parent-session-id <id>
      --parent-tool-call-id <id>
      --agent-depth <n>

退出码: 0 正常, 1 内部错误, 2 用法/配置, 3 provider, 4 工具基础设施,
        130 SIGINT, 143 SIGTERM
`

print_usage :: proc() {
	text := USAGE_TEXT
	write_stdout(transmute([]byte)text)
}

// 统一把内部文本写到 stderr；用于进度与工具输出。
stderr_write_string :: proc(s: string) {
	if len(s) > 0 {
		write_stderr(transmute([]byte)s)
	}
}
