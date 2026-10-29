package aptui

import client "../ap-core/client"

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

// 仅用于非 TTY / raw mode 不可用的回退路径；TTY 下由 editor_view 画 `› `。
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

run_input_loop :: proc(app: ^App, term: ^Term) {
	input := Input {
		term      = term,
		stdin_tty = terminal.is_terminal(os.stdin),
	}
	bufio.reader_init(&input.reader, io.to_reader(os.to_reader(os.stdin)), 8192, context.allocator)
	defer bufio.reader_destroy(&input.reader)

	for {
		if input.term != nil {
			if !term_enter(input.term) {
				// raw mode 进不去（非常规 console）：退回 bufio 行输入。
				input.term = nil
			} else if input.term.probed && !input.term.kitty && !input.term.warned {
				input.term.warned = true
				// raw 下换行不再是 CRLF，先把终端交还内核再打印提示。
				term_leave(input.term)
				renderer_note(
					app,
					"terminal does not report kitty keyboard protocol: Ctrl+Enter unavailable",
				)
				if !term_enter(input.term) {
					input.term = nil
				}
			}
		}

		text, eof := read_prompt(app, &input)

		// 每轮 turn 前后离开 raw，让 Ctrl+C 在 turn 期间仍然是内核 SIGINT，
		// 也让 turn 期间的按键留在终端缓冲里。
		if input.term != nil {
			term_leave(input.term)
		}

		if eof {
			return
		}
		trimmed := strings.trim_space(text)
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
		run_agent_turn(app, text)
		free_all(context.temp_allocator)
	}
}

run :: proc(args: []string) -> int {
	client.setup_console()
	argv := client.normalize_args(args)
	opts, oerr := parse_args(argv)
	if !client.is_ok(oerr) {
		fmt.eprintln("ap-tui: ", oerr.message)
		fmt.eprintln("hint: run ap-tui --help for usage")
		return 2
	}
	if opts.help {
		print_usage()
		return 0
	}
	if opts.version {
		fmt.printfln("ap-tui %s", TUI_VERSION)
		return 0
	}

	config_dir, cerr := client.default_config_dir(opts.config_dir)
	if !client.is_ok(cerr) {
		fmt.eprintln("ap-tui: ", cerr.message)
		return 2
	}
	cwd, cwderr := client.canonicalize_path(".", true)
	if !client.is_ok(cwderr) {
		fmt.eprintln("ap-tui: ", cwderr.message)
		return 2
	}
	project, perr := client.locate_project(config_dir, cwd)
	if !client.is_ok(perr) {
		fmt.eprintln("ap-tui: ", perr.message)
		return 2
	}
	agent_bin, aerr := client.resolve_agent_bin(opts.agent_bin)
	if !client.is_ok(aerr) {
		fmt.eprintln("ap-tui: ", aerr.message)
		return 2
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
			return 2
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

	term: Term
	term_ptr: ^Term
	if terminal.is_terminal(os.stdin) && terminal.is_terminal(os.stdout) {
		term_init(&term, os.stdin, os.stdout)
		term_ptr = &term
	}
	defer term_leave(&term)

	run_input_loop(&app, term_ptr)
	return 0
}
