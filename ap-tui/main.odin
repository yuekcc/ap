package tui

import client "../ap/client"

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:terminal"

App :: struct {
	options:    Tui_Options,
	project:    client.Project,
	renderer:   Renderer,
	agent_bin:  string,
	session_id: string,
}

renderer_note :: proc(app: ^App, text: string) {
	note(&app.renderer, text)
}

print_commands :: proc() {
	fmt.print(
		`交互命令:
  /new       丢弃当前 session，下一条提示词开始新 session
  /session   显示当前 session id
  /help      显示本帮助
  /quit      退出（/exit 同义）
`,
	)
}

print_banner :: proc(app: ^App) {
	fmt.printfln("ap-tui %s · %s", TUI_VERSION, app.project.root)
	renderer_note(app, fmt.tprintf("agent: %s", app.agent_bin))
	if len(app.session_id) > 0 {
		renderer_note(app, fmt.tprintf("session: %s", app.session_id))
	} else {
		renderer_note(app, "session: new")
	}
	renderer_note(app, "commands: /help · /new · /session · /quit")
}

write_prompt :: proc(app: ^App) {
	ensure_line_start(&app.renderer)
	paint(&app.renderer, BOLD + CYAN, "> ")
}

read_line :: proc(reader: ^bufio.Reader) -> (line: string, eof: bool) {
	text, err := bufio.reader_read_string(reader, '\n', context.temp_allocator)
	if err != nil && err != io.Error.EOF {
		return "", true
	}
	line = strings.trim_right(text, "\r\n")
	if err == io.Error.EOF && len(line) == 0 {
		return "", true
	}
	return line, false
}

Command_Result :: enum {
	Not_Command,
	Handled,
	Quit,
}

handle_command :: proc(app: ^App, line: string) -> Command_Result {
	switch line {
	case "/quit", "/exit":
		return .Quit
	case "/help":
		print_commands()
		return .Handled
	case "/new":
		if len(app.session_id) > 0 {
			delete(app.session_id, context.allocator)
			app.session_id = ""
		}
		renderer_note(app, "new session: 下一条提示词会新建 session")
		return .Handled
	case "/session":
		if len(app.session_id) > 0 {
			renderer_note(app, fmt.tprintf("session: %s", app.session_id))
		} else {
			renderer_note(app, "session: new（尚未发送提示词）")
		}
		return .Handled
	}
	return .Not_Command
}

run_input_loop :: proc(app: ^App) {
	reader: bufio.Reader
	bufio.reader_init(&reader, io.to_reader(os.to_reader(os.stdin)), 8192, context.allocator)
	defer bufio.reader_destroy(&reader)
	stdin_tty := terminal.is_terminal(os.stdin)

	for {
		write_prompt(app)
		line, eof := read_line(&reader)
		// TTY 下回车已经由终端换行；管道输入没有回显，需要自己补一个换行。
		if stdin_tty {
			app.renderer.at_line_start = true
		} else {
			ensure_line_start(&app.renderer)
		}
		if eof {
			return
		}
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 {
			continue
		}
		switch handle_command(app, trimmed) {
		case .Quit:
			return
		case .Handled:
			free_all(context.temp_allocator)
			continue
		case .Not_Command:
		}
		run_agent_turn(app, line)
		free_all(context.temp_allocator)
	}
}

main :: proc() {
	client.setup_console()
	args := client.normalize_args(os.args)
	opts, oerr := parse_args(args)
	if !client.is_ok(oerr) {
		fmt.eprintln("ap-tui: ", oerr.message)
		fmt.eprintln("hint: run ap-tui --help for usage")
		os.exit(2)
	}
	if opts.help {
		print_usage()
		return
	}
	if opts.version {
		fmt.printfln("ap-tui %s", TUI_VERSION)
		return
	}

	config_dir, cerr := client.default_config_dir(opts.config_dir)
	if !client.is_ok(cerr) {
		fmt.eprintln("ap-tui: ", cerr.message)
		os.exit(2)
	}
	cwd, cwderr := client.canonicalize_path(".", true)
	if !client.is_ok(cwderr) {
		fmt.eprintln("ap-tui: ", cwderr.message)
		os.exit(2)
	}
	project, perr := client.locate_project(config_dir, cwd)
	if !client.is_ok(perr) {
		fmt.eprintln("ap-tui: ", perr.message)
		os.exit(2)
	}
	agent_bin, aerr := client.resolve_agent_bin(opts.agent_bin)
	if !client.is_ok(aerr) {
		fmt.eprintln("ap-tui: ", aerr.message)
		os.exit(2)
	}

	color := !opts.no_color &&
		terminal.is_terminal(os.stdout) &&
		terminal.color_enabled

	app := App {
		options = opts,
		project = project,
		agent_bin = agent_bin,
		renderer = {
			out = os.stdout,
			color = color,
			project = &project,
			at_line_start = true,
		},
	}

	if id, ok := opts.session_id.?; ok {
		if !os.exists(client.session_file(project, id)) {
			fmt.eprintfln(
				"ap-tui: session %q not found in project %s (expected %s)",
				id,
				project.hash,
				client.session_file(project, id),
			)
			os.exit(2)
		}
		remember_session(&app, id)
	} else if opts.continue_session {
		found, ferr := client.find_latest_root_session(project)
		if client.is_ok(ferr) {
			remember_session(&app, found)
			delete(found, context.allocator)
		} else {
			renderer_note(&app, ferr.message)
			renderer_note(&app, "starting a new session")
		}
	}

	print_banner(&app)
	if len(app.session_id) > 0 {
		if err := replay_session(&app, app.session_id); !client.is_ok(err) {
			renderer_note(&app, err.message)
		}
	}

	run_input_loop(&app)
}
