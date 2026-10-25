package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"

WEB_VERSION :: "0.1.0"
DEFAULT_PORT :: 8417
DEFAULT_HOST :: "127.0.0.1"

// CLI 解析错误用独立类型，避免与后续工单 project.odin 里的 internal.Error 别名冲突。
Cli_Error :: struct {
	message: string,
}

cli_ok :: proc() -> Cli_Error {
	return {}
}

cli_errorf :: proc(format: string, args: ..any) -> Cli_Error {
	return {message = fmt.tprintf(format, ..args)}
}

cli_is_ok :: proc(err: Cli_Error) -> bool {
	return len(err.message) == 0
}

Web_Options :: struct {
	port:             int,
	host:             string,
	host_explicit:    bool,
	web_root:         Maybe(string),
	agent_bin:        Maybe(string),
	session_id:       Maybe(string),
	continue_session: bool,
	model:            Maybe(string),
	max_steps:        Maybe(int),
	max_tokens:       Maybe(int),
	config_dir:       Maybe(string),
	cwd:              Maybe(string),
	help:             bool,
	version:          bool,
}

option_value :: proc(
	args: []string,
	i: int,
	inline: string,
	has_inline: bool,
	name: string,
) -> (value: string, next: int, err: Cli_Error) {
	if has_inline {
		return inline, i + 1, cli_ok()
	}
	if i + 1 >= len(args) {
		return "", i + 1, cli_errorf("%s requires a value", name)
	}
	return args[i + 1], i + 2, cli_ok()
}

parse_positive_int :: proc(value, name: string) -> (int, Cli_Error) {
	n, ok := strconv.parse_int(value, 10)
	if !ok || n <= 0 {
		return 0, cli_errorf("%s requires a positive integer", name)
	}
	return n, cli_ok()
}

parse_port :: proc(value: string) -> (int, Cli_Error) {
	n, ok := strconv.parse_int(value, 10)
	if !ok || n <= 0 || n > 65535 {
		return 0, cli_errorf("--port requires an integer in 1..65535")
	}
	return n, cli_ok()
}

// 与 ap-tui/args.odin 保持同一套解析风格：--opt=value 与 --opt value 都支持，
// 布尔开关拒绝内联值。
parse_args :: proc(args: []string) -> (Web_Options, Cli_Error) {
	opts := Web_Options {
		port = DEFAULT_PORT,
		host = DEFAULT_HOST,
	}
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
			if has_inline {
				return opts, cli_errorf("%s does not take a value", name)
			}
			opts.help = true
			i += 1
		case "--version":
			if has_inline {
				return opts, cli_errorf("%s does not take a value", name)
			}
			opts.version = true
			i += 1
		case "-c", "--continue":
			if has_inline {
				return opts, cli_errorf("%s does not take a value", name)
			}
			opts.continue_session = true
			i += 1
		case "-s", "--session":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !cli_is_ok(err) {
				return opts, err
			}
			if len(value) == 0 {
				return opts, cli_errorf("%s requires a session id", name)
			}
			opts.session_id = value
			i = next
		case "--port":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !cli_is_ok(err) {
				return opts, err
			}
			port, perr := parse_port(value)
			if !cli_is_ok(perr) {
				return opts, perr
			}
			opts.port = port
			i = next
		case "--host":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !cli_is_ok(err) {
				return opts, err
			}
			if len(value) == 0 {
				return opts, cli_errorf("%s requires a host", name)
			}
			opts.host = value
			opts.host_explicit = true
			i = next
		case "--web-root":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !cli_is_ok(err) {
				return opts, err
			}
			opts.web_root = value
			i = next
		case "--agent-bin":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !cli_is_ok(err) {
				return opts, err
			}
			opts.agent_bin = value
			i = next
		case "--model":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !cli_is_ok(err) {
				return opts, err
			}
			opts.model = value
			i = next
		case "--max-steps":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !cli_is_ok(err) {
				return opts, err
			}
			n, nerr := parse_positive_int(value, name)
			if !cli_is_ok(nerr) {
				return opts, nerr
			}
			opts.max_steps = n
			i = next
		case "--max-tokens":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !cli_is_ok(err) {
				return opts, err
			}
			n, nerr := parse_positive_int(value, name)
			if !cli_is_ok(nerr) {
				return opts, nerr
			}
			opts.max_tokens = n
			i = next
		case "--config-dir":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !cli_is_ok(err) {
				return opts, err
			}
			opts.config_dir = value
			i = next
		case "--cwd":
			value, next, err := option_value(args, i, inline, has_inline, name)
			if !cli_is_ok(err) {
				return opts, err
			}
			opts.cwd = value
			i = next
		case:
			return opts, cli_errorf("unknown argument: %s", arg)
		}
	}

	if opts.session_id != nil && opts.continue_session {
		return opts, cli_errorf("-s/--session and -c/--continue are mutually exclusive")
	}
	return opts, cli_ok()
}

App :: struct {
	options:     Web_Options,
	assets:      Assets,
	hub:         Sse_Hub,
	runner:      Runner,
	config_dir:  string,
	agent_bin:   string,
	project:     Project,
	cwd:         string,
	picker_busy: bool,
}

// 所有请求的统一入口：先查 api 路由表，/api/* 本工单占位 404，其余走静态资源。
app_handle_request :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	app := (^App)(user)
	if router_dispatch(&ROUTES, user, request, response) {
		return
	}
	if request.path == "/api" || strings.has_prefix(request.path, "/api/") {
		response_set_header(response, "Content-Type", "text/plain; charset=utf-8")
		response_text(response, 404, status_text(404))
		return
	}
	serve_static(&app.assets, request, response)
}

print_usage :: proc() {	fmt.print(
		`ap-web — ap 的浏览器客户端

用法:
  ap-web [options]

服务:
  --port <n>                监听端口（默认 8417）
  --host <addr>             监听地址（默认 127.0.0.1；显式非回环地址会打印安全警告）
  --web-root <dir>          开发模式：静态资源从磁盘读取，默认用编译进 exe 的 dist/

Agent:
  --agent-bin <path>        ap/ag 可执行文件（后续 turn 使用）
  --config-dir <dir>        传给 ap 的 $AP_CONFIG，默认 ~/.ap
  --model <id>              传给 ap 的 --model
  --max-steps <n>           传给 ap 的 --max-steps
  --max-tokens <n>          传给 ap 的 --max-tokens
  --cwd <dir>               初始工作目录，默认进程启动目录

Session:
  -c, --continue            继续当前项目最近一次根 session
  -s, --session <id>        恢复指定 session

其他:
  -h, --help                显示本帮助
  --version                 显示版本
`,
	)
}

is_loopback_host :: proc(host: string) -> bool {
	if strings.equal_fold(host, "localhost") || host == "::1" || host == "[::1]" {
		return true
	}
	if addr4, ok := net.parse_ip4_address(host); ok {
		return addr4[0] == 127
	}
	if addr6, ok := net.parse_ip6_address(host); ok {
		return addr6 == net.IP6_Address{0, 0, 0, 0, 0, 0, 0, 1}
	}
	return false
}

print_security_warning :: proc(host: string) {
	fmt.eprintln("================================================================")
	fmt.eprintfln("警告: ap-web 正在监听非回环地址 %s", host)
	fmt.eprintln("任何能连上该端口的人都可以通过 agent 执行 shell 命令。")
	fmt.eprintln("仅在可信网络中这样做，或改用 --host 127.0.0.1。")
	fmt.eprintln("================================================================")
}

main :: proc() {
	setup_console()
	args := normalize_args(os.args)
	opts, oerr := parse_args(args)
	if !cli_is_ok(oerr) {
		fmt.eprintln("ap-web: ", oerr.message)
		fmt.eprintln("hint: run ap-web --help for usage")
		os.exit(2)
	}
	if opts.help {
		print_usage()
		return
	}
	if opts.version {
		fmt.printfln("ap-web %s", WEB_VERSION)
		return
	}

	web_root := ""
	if value, ok := opts.web_root.?; ok {
		web_root = value
	}
	assets, asset_err := make_assets(web_root)
	if len(asset_err) > 0 {
		fmt.eprintln("ap-web: ", asset_err)
		os.exit(2)
	}
	app := App {
		options = opts,
		assets = assets,
	}

	if opts.host_explicit && !is_loopback_host(opts.host) {
		print_security_warning(opts.host)
	}

	endpoint, resolve_err := resolve_endpoint(opts.host, opts.port)
	if len(resolve_err) > 0 {
		fmt.eprintln("ap-web: ", resolve_err)
		os.exit(1)
	}
	listener, listen_err := open_listener(endpoint)
	if len(listen_err) > 0 {
		fmt.eprintln("ap-web: ", listen_err)
		os.exit(1)
	}
	defer close_listener(&listener)

	display_host := opts.host
	if strings.contains_rune(display_host, ':') {
		display_host = fmt.tprintf("[%s]", display_host)
	}
	fmt.printfln("ap-web %s listening on http://%s:%d", WEB_VERSION, display_host, opts.port)
	if len(assets.web_root) > 0 {
		fmt.printfln("static: %s (disk)", assets.web_root)
	} else {
		fmt.printfln("static: embedded dist/ (%d files)", len(assets.embedded))
	}

	for {
		client, _, accepted := accept_client(&listener)
		if !accepted {
			fmt.eprintln("ap-web: accept failed, stopping")
			break
		}
		ctx := new(Client_Context)
		ctx^ = {
			app    = &app,
			socket = client,
		}
		if thread.create_and_start_with_data(ctx, serve_client, self_cleanup = true) == nil {
			close_client(client)
			free(ctx)
		}
	}
}
