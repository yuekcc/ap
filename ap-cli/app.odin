package apcli

import apcore "../ap-core"
import platform "../ap-core/platform"
import "core:fmt"
import "core:os"

VERSION :: apcore.VERSION

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

必须从以上三种方式中选择一种提供提示词；ap 不会隐式读取 stdin。

会话:
  -s, --session <id>          恢复当前项目内的指定 session
  -c, --continue              恢复当前项目内最近的根 session
      --fork-session          与 -s / -c 连用，复制历史到新 session

agent 与模型:
      --agent <name>          使用 $AP_CONFIG/agents/<name>.md 或内置 general
      --model <id>            覆盖配置中的 model（恢复 session 时只警告）
      --max-steps <n>         单个 turn 的最大 step 数
      --max-tokens <n>        单次响应的 max_tokens
      --config-dir <path>     设置 $AP_CONFIG，默认 ~/.ap

提示词与上下文:
  -p, --print <提示词>        直接指定提示词
      --input-file <path>     从文件读取提示词
      --print0                从 stdin 读取提示词直到 EOF
      --no-agents-md          不注入 AGENTS.md
      --no-skills             不注入技能清单
      --print-system-prompt   打印本次使用的 system prompt 后退出

  约定: $AP_CONFIG/SYSTEM.md 存在时替换内置固定指令段；
        追加提示词写入 ~/.agents/AGENTS.md 或项目 AGENTS.md。

其他:
      --list-skills           列出当前目录可见的技能后退出

输出:
      --output-format <fmt>   text | json | stream-json，默认 text
      --verbose               输出 info 日志到 stderr
      --debug                 输出 debug 日志到 stderr
      --help                  显示帮助
      --version               显示版本

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
