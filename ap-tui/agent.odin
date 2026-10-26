package tui

import client "../ap/client"
import protocol "../ap/protocol"
import "core:fmt"
import "core:strings"

remember_session :: proc(app: ^App, session_id: string) {
	if len(session_id) == 0 {
		return
	}
	cloned := strings.clone(session_id, context.allocator)
	if len(app.session_id) > 0 {
		delete(app.session_id, context.allocator)
	}
	app.session_id = cloned
}

on_agent_event :: proc(user: rawptr, ev: protocol.Stream_Event) {
	app := (^App)(user)
	if ev.type == "session_start" && len(ev.session_id) > 0 {
		remember_session(app, ev.session_id)
	}
	render_event(&app.renderer, ev, .Live)
	free_all(context.temp_allocator)
}

on_agent_stderr_line :: proc(user: rawptr, line: string) {
	app := (^App)(user)
	if app.options.verbose {
		renderer_note(app, fmt.tprintf("[ap] %s", line))
	}
	free_all(context.temp_allocator)
}

// 执行一个 turn：每轮都启动一个新的 ap 进程，stdout 读 stream-json，stderr 收集后按需展示。
run_agent_turn :: proc(app: ^App, prompt: string) -> int {
	had_session := len(app.session_id) > 0
	options := client.Turn_Options {
		agent_bin  = app.agent_bin,
		config_dir = app.project.config_dir,
		cwd        = app.project.root,
		session_id = app.session_id,
		model      = app.options.model,
		agent      = app.options.agent,
		max_steps  = app.options.max_steps,
		max_tokens = app.options.max_tokens,
		verbose    = app.options.verbose,
	}
	callbacks := client.Turn_Callbacks {
		user       = app,
		on_event   = on_agent_event,
		on_stderr  = on_agent_stderr_line,
	}
	result := client.turn_run(&options, prompt, callbacks)
	exit_code := result.exit_code
	if len(result.session_id) > 0 {
		delete(result.session_id, context.allocator)
	}

	finish_assistant(&app.renderer)
	ensure_line_start(&app.renderer)

	if !had_session && len(app.session_id) > 0 {
		renderer_note(app, fmt.tprintf("session: %s", app.session_id))
	}

	if exit_code != 0 {
		if exit_code == 130 || exit_code == 143 {
			renderer_note(app, "agent interrupted")
		} else {
			renderer_note(app, fmt.tprintf("agent exited with code %d", exit_code))
		}
	}
	if !app.options.verbose && len(result.stderr_preview) > 0 && exit_code != 0 {
		renderer_note(app, "── agent stderr ──")
		for line in strings.split_lines(result.stderr_preview, context.temp_allocator) {
			if len(strings.trim_space(line)) > 0 {
				renderer_note(app, line)
			}
		}
	}
	if len(result.stderr_preview) > 0 {
		delete(result.stderr_preview, context.allocator)
	}
	return exit_code
}

// 启动时重放已有 transcript；只展示历史，不重新执行工具或调用模型。
replay_session :: proc(app: ^App, session_id: string) -> client.Error {
	data, err := client.read_transcript(app.project, session_id)
	if !client.is_ok(err) {
		return err
	}
	defer delete(data)

	renderer_note(app, fmt.tprintf("── resumed %s ──", session_id))
	it := client.Line_Iterator{data = string(data)}
	for {
		line, more := client.next_line(&it)
		if !more {
			break
		}
		ev, ok := protocol.parse_stream_event(line)
		if ok {
			render_event(&app.renderer, ev, .History)
		}
		free_all(context.temp_allocator)
	}
	finish_assistant(&app.renderer)
	ensure_line_start(&app.renderer)
	return client.ok_error()
}
