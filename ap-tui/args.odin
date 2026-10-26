package tui

import "core:fmt"
import "core:strconv"
import "core:strings"

TUI_VERSION :: "0.1.0"

Tui_Options :: struct {
	continue_session: bool,
	session_id:       Maybe(string),
	config_dir:       Maybe(string),
	agent_bin:        Maybe(string),
	model:            Maybe(string),
	agent:            Maybe(string),
	max_steps:        Maybe(int),
	max_tokens:       Maybe(int),
	verbose:          bool,
	no_color:         bool,
	help:             bool,
	version:          bool,
}

option_value :: proc(
	args: []string,
	i: int,
	inline: string,
	has_inline: bool,
	name: string,
) -> (value: string, next: int, err: Error) {
	if has_inline {
		return inline, i + 1, ok_error()
	}
	if i + 1 >= len(args) {
		return "", i + 1, errorf("%s requires a value", name)
	}
	return args[i + 1], i + 2, ok_error()
}

parse_positive_int :: proc(value, name: string) -> (int, Error) {
	n, ok := strconv.parse_int(value, 10)
	if !ok || n <= 0 {
		return 0, errorf("%s requires a positive integer", name)
	}
	return n, ok_error()
}

parse_args :: proc(args: []string) -> (Tui_Options, Error) {
	opts := Tui_Options{}
	i := 1
	for i < len(args) {
		arg := args[i]
		name := arg
		inline := ""
		has_inline := false
		if eq := strings.index_byte(arg, '='); eq >= 0 && strings.has_prefix(arg, "--") {
			name = arg[:eq]
			inline = arg[eq + 1:]
			has_inline = true
		}

		switch name {
		case "-h", "--help":
			opts.help = true
			i += 1
		case "--version":
			opts.version = true
			i += 1
		case "-c", "--continue":
			if has_inline {
				return opts, errorf("%s does not take a value", name)
			}
			opts.continue_session = true
			i += 1
		case "-s", "--session":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			if len(value) == 0 {
				return opts, errorf("%s requires a session id", name)
			}
			opts.session_id = value
			i = next
		case "--config-dir":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			opts.config_dir = value
			i = next
		case "--agent-bin":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			opts.agent_bin = value
			i = next
		case "--model":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			opts.model = value
			i = next
		case "--agent":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			opts.agent = value
			i = next
		case "--max-steps":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			n, nerr := parse_positive_int(value, name)
			if !is_ok(nerr) {
				return opts, nerr
			}
			opts.max_steps = n
			i = next
		case "--max-tokens":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			n, nerr := parse_positive_int(value, name)
			if !is_ok(nerr) {
				return opts, nerr
			}
			opts.max_tokens = n
			i = next
		case "--verbose":
			opts.verbose = true
			i += 1
		case "--no-color":
			opts.no_color = true
			i += 1
		case:
			return opts, errorf("unknown argument: %s", arg)
		}
	}

	if opts.session_id != nil && opts.continue_session {
		return opts, errorf("-s/--session and -c/--continue are mutually exclusive")
	}
	return opts, ok_error()
}

print_usage :: proc() {
	fmt.print(
		`ap-tui — 交互式 ap 客户端

用法:
  ap-tui [options]

Session:
  -c, --continue            继续当前项目最近一次根 session
  -s, --session <id>        恢复指定 session
  （都不给则新建 session；一次只维护一个活动 session）

Agent:
  --agent-bin <path>        ap 可执行文件（默认找同目录 ap.exe）
  --config-dir <dir>        传给 ap 的 $AP_CONFIG，默认 ~/.ap
  --model <id>              传给 ap 的 --model
  --agent <name>            传给 ap 的 --agent
  --max-steps <n>           传给 ap 的 --max-steps
  --max-tokens <n>          传给 ap 的 --max-tokens
  --verbose                 实时显示 ap 的 stderr
                            （环境变量 AP_AGENT_BIN / AP_BIN 可指定 agent）

界面:
  --no-color                关闭 ANSI 颜色
  -h, --help                显示本帮助
  --version                 显示版本

交互命令:
  /new       丢弃当前 session，下一条提示词开始新 session
  /session   显示当前 session id
  /help      显示交互命令
  /quit      退出（/exit 同义）
`,
	)
}
