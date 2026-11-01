package apcli

import apcore "../ap-core"
import platform "../ap-core/platform"
import "core:os"
import "core:strconv"
import "core:strings"

Output_Format :: enum {
	Text,
	Json,
	Stream_Json,
}

Options :: struct {
	session_id:           Maybe(string),
	continue_session:     bool,
	fork_session:         bool,
	agent:                Maybe(string),
	input_file:           Maybe(string),
	print_prompt:         Maybe(string),
	print0:               bool,
	config_dir:           Maybe(string),
	model:                Maybe(string),
	max_steps:            Maybe(int),
	max_tokens:           Maybe(int),
	output_format:        Output_Format,
	parent_session_id:    Maybe(string),
	parent_tool_call_id:  Maybe(string),
	agent_depth:          Maybe(int),
	append_system_prompt: Maybe(string),
	base_system_prompt:   Maybe(string),
	base_system_prompt_file: Maybe(string),
	no_agents_md:         bool,
	no_skills:            bool,
	tools_set:            bool,
	tools:                []string,
	verbose:              bool,
	debug:                bool,
	help:                 bool,
	version:              bool,
	list_skills:          bool,
	list_tools:           bool,
	print_system_prompt:  bool,
}

parse_args :: proc(args: []string) -> (Options, Error) {
	opts := Options {
		output_format = .Text,
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
			opts.help = true
			i += 1
		case "--version":
			opts.version = true
			i += 1
		case "--list-skills":
			if has_inline {
				return opts, make_error(.Usage, "%s does not take a value", name)
			}
			opts.list_skills = true
			i += 1
		case "--list-tools":
			if has_inline {
				return opts, make_error(.Usage, "%s does not take a value", name)
			}
			opts.list_tools = true
			i += 1
		case "--print-system-prompt":
			if has_inline {
				return opts, make_error(.Usage, "%s does not take a value", name)
			}
			opts.print_system_prompt = true
			i += 1
		case "-s", "--session":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			if len(value) == 0 {
				return opts, make_error(.Usage, "%s requires a session id", name)
			}
			if !session_id_safe(value) {
				return opts, make_error(.Usage, "invalid session id %q", value)
			}
			opts.session_id = value
			i = n
		case "-c", "--continue":
			if has_inline {
				return opts, make_error(.Usage, "%s does not take a value", name)
			}
			opts.continue_session = true
			i += 1
		case "--fork-session":
			if has_inline {
				return opts, make_error(.Usage, "%s does not take a value", name)
			}
			opts.fork_session = true
			i += 1
		case "--agent":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			opts.agent = value
			i = n
		case "--input-file":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			opts.input_file = value
			i = n
		case "-p", "--print":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			opts.print_prompt = value
			i = n
		case "--print0":
			if has_inline {
				return opts, make_error(.Usage, "%s does not take a value", name)
			}
			opts.print0 = true
			i += 1
		case "--config-dir":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			opts.config_dir = value
			i = n
		case "--model":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			opts.model = value
			i = n
		case "--max-steps":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			parsed, ok := strconv.parse_int(value, 10)
			if !ok || parsed <= 0 {
				return opts, make_error(.Usage, "--max-steps must be a positive integer")
			}
			opts.max_steps = parsed
			i = n
		case "--max-tokens":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			parsed, ok := strconv.parse_int(value, 10)
			if !ok || parsed <= 0 {
				return opts, make_error(.Usage, "--max-tokens must be a positive integer")
			}
			opts.max_tokens = parsed
			i = n
		case "--output-format":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			switch value {
			case "text":
				opts.output_format = .Text
			case "json":
				opts.output_format = .Json
			case "stream-json":
				opts.output_format = .Stream_Json
			case:
				return opts, make_error(.Usage, "unknown output format %q (expected text, json or stream-json)", value)
			}
			i = n
		case "--parent-session-id":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			if !session_id_safe(value) {
				return opts, make_error(.Usage, "invalid parent session id %q", value)
			}
			opts.parent_session_id = value
			i = n
		case "--parent-tool-call-id":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			opts.parent_tool_call_id = value
			i = n
		case "--agent-depth":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			parsed, ok := strconv.parse_int(value, 10)
			if !ok || parsed < 0 {
				return opts, make_error(.Usage, "--agent-depth must be a non-negative integer")
			}
			opts.agent_depth = parsed
			i = n
		case "--append-system-prompt":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			opts.append_system_prompt = value
			i = n
		case "--base-system-prompt":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			if len(strings.trim_space(value)) == 0 {
				return opts, make_error(.Usage, "--base-system-prompt requires non-empty text")
			}
			opts.base_system_prompt = value
			i = n
		case "--base-system-prompt-file":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			if len(value) == 0 {
				return opts, make_error(.Usage, "--base-system-prompt-file requires a path")
			}
			opts.base_system_prompt_file = value
			i = n
		case "--no-agents-md":
			if has_inline {
				return opts, make_error(.Usage, "%s does not take a value", name)
			}
			opts.no_agents_md = true
			i += 1
		case "--no-skills":
			if has_inline {
				return opts, make_error(.Usage, "%s does not take a value", name)
			}
			opts.no_skills = true
			i += 1
		case "--tools":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !is_ok(err) {
				return opts, err
			}
			parsed, perr := parse_tool_list(value)
			if !is_ok(perr) {
				return opts, perr
			}
			opts.tools = parsed
			opts.tools_set = true
			i = n
		case "--verbose":
			if has_inline {
				return opts, make_error(.Usage, "%s does not take a value", name)
			}
			opts.verbose = true
			i += 1
		case "--debug":
			if has_inline {
				return opts, make_error(.Usage, "%s does not take a value", name)
			}
			opts.debug = true
			i += 1
		case "--":
			return opts, make_error(.Usage, "unexpected argument: %s", arg)
		case:
			return opts, make_error(.Usage, "unknown argument: %s", arg)
		}
	}

	if opts.session_id != nil && opts.continue_session {
		return opts, make_error(.Usage, "--session and --continue cannot be used together")
	}
	if opts.fork_session && opts.session_id == nil && !opts.continue_session {
		return opts, make_error(.Usage, "--fork-session requires --session or --continue")
	}
	if opts.parent_tool_call_id != nil && opts.parent_session_id == nil {
		return opts, make_error(.Usage, "--parent-tool-call-id requires --parent-session-id")
	}
	prompt_sources := 0
	if _, ok := opts.print_prompt.?; ok {
		prompt_sources += 1
	}
	if _, ok := opts.input_file.?; ok {
		prompt_sources += 1
	}
	if opts.print0 {
		prompt_sources += 1
	}
	if prompt_sources > 1 {
		return opts, make_error(.Usage, "--print, --input-file and --print0 are mutually exclusive")
	}
	if opts.base_system_prompt != nil && opts.base_system_prompt_file != nil {
		return opts, make_error(
			.Usage,
			"--base-system-prompt and --base-system-prompt-file are mutually exclusive",
		)
	}
	if opts.list_skills && opts.list_tools {
		return opts, make_error(.Usage, "--list-skills and --list-tools are mutually exclusive")
	}
	if name, ok := opts.agent.?; ok && len(name) == 0 {
		return opts, make_error(.Usage, "--agent requires a name")
	}
	if dir, ok := opts.config_dir.?; ok && len(dir) == 0 {
		return opts, make_error(.Usage, "--config-dir requires a path")
	}
	if model, ok := opts.model.?; ok && len(model) == 0 {
		return opts, make_error(.Usage, "--model requires a model id")
	}
	if parent, ok := opts.parent_session_id.?; ok && len(parent) == 0 {
		return opts, make_error(.Usage, "--parent-session-id requires an id")
	}
	if call_id, ok := opts.parent_tool_call_id.?; ok && len(call_id) == 0 {
		return opts, make_error(.Usage, "--parent-tool-call-id requires an id")
	}
	return opts, ok_error()
}

// 解析 --tools 的值：支持 all / none，去重后按 ALL_TOOL_NAMES 的固定顺序返回。
parse_tool_list :: proc(value: string) -> ([]string, Error) {
	parts, _ := strings.split(value, ",")
	names := make([dynamic]string, 0, len(parts))
	special := ""
	has_token := false
	for part in parts {
		name := strings.trim_space(part)
		if len(name) == 0 {
			continue
		}
		has_token = true
		switch name {
		case "all", "none":
			if len(special) > 0 {
				return nil, make_error(.Usage, "--tools: all/none must be the only value")
			}
			special = name
		case:
			if !apcore.tool_name_known(name) {
				return nil, make_error(
					.Usage,
					"unknown tool %q (expected read_file, write_file, edit_file, bash, task, all or none)",
					name,
				)
			}
			append(&names, name)
		}
	}
	if !has_token {
		return nil, make_error(.Usage, "--tools requires a non-empty list; use --tools none for no tools")
	}
	if len(special) > 0 {
		if len(names) > 0 {
			return nil, make_error(.Usage, "--tools: all/none must be the only value")
		}
		if special == "none" {
			return make([]string, 0), ok_error()
		}
		all := apcore.all_tool_names()
		return apcore.select_tools(all[:]), ok_error()
	}
	return apcore.select_tools(names[:]), ok_error()
}

// CRLF / 单独 CR → LF；去首尾空白；内部空行与缩进保持不变。
// ensure_trailing_newline 为 true 时保证结尾恰好一个 \n。
normalize_prompt_block :: proc(text: string, ensure_trailing_newline: bool) -> (string, Error) {
	b := strings.builder_make()
	i := 0
	for i < len(text) {
		ch := text[i]
		if ch == '\r' {
			if i + 1 < len(text) && text[i + 1] == '\n' {
				i += 1
			}
			strings.write_byte(&b, '\n')
		} else {
			strings.write_byte(&b, ch)
		}
		i += 1
	}
	trimmed := strings.trim_space(strings.to_string(b))
	if len(trimmed) == 0 {
		return "", make_error(.Usage, "prompt text must not be empty")
	}
	if ensure_trailing_newline {
		return strings.concatenate([]string{trimmed, "\n"}), ok_error()
	}
	return strings.clone(trimmed), ok_error()
}

// --base-system-prompt / --base-system-prompt-file：文件读取放在 CLI 层，
// engine 只接收规范化后的最终文本。
read_base_system_prompt :: proc(opts: Options, cwd: string) -> (Maybe(string), Error) {
	if value, ok := opts.base_system_prompt.?; ok {
		normalized, nerr := normalize_prompt_block(value, true)
		if !is_ok(nerr) {
			return nil, nerr
		}
		return normalized, ok_error()
	}
	if path, ok := opts.base_system_prompt_file.?; ok {
		resolved, rerr := platform.resolve_tool_path(cwd, path)
		if !platform.is_ok(rerr) {
			return nil, make_error(.Usage, "%s", rerr.message)
		}
		data, derr := os.read_entire_file_from_path(resolved, context.allocator)
		if derr != nil {
			return nil, make_error(.Usage, "cannot read --base-system-prompt-file %s: %v", resolved, derr)
		}
		if len(data) == 0 {
			return nil, make_error(.Usage, "--base-system-prompt-file is empty: %s", resolved)
		}
		if !platform.valid_utf8(data) {
			return nil, make_error(.Usage, "--base-system-prompt-file is not valid UTF-8: %s", resolved)
		}
		normalized, nerr := normalize_prompt_block(string(data), true)
		if !is_ok(nerr) {
			return nil, make_error(.Usage, "--base-system-prompt-file is empty: %s", resolved)
		}
		return normalized, ok_error()
	}
	return nil, ok_error()
}

// --append-system-prompt 只做 CRLF→LF 与首尾 trim；空内容视为未提供。
read_append_system_prompt :: proc(opts: Options) -> (Maybe(string), Error) {
	value, ok := opts.append_system_prompt.?
	if !ok {
		return nil, ok_error()
	}
	if len(strings.trim_space(value)) == 0 {
		return nil, ok_error()
	}
	normalized, nerr := normalize_prompt_block(value, false)
	if !is_ok(nerr) {
		return nil, nerr
	}
	return normalized, ok_error()
}

session_id_safe :: proc(value: string) -> bool {
	if value == "." || value == ".." {
		return false
	}
	for ch in value {
		if ch == '/' || ch == '\\' || ch == 0 {
			return false
		}
	}
	return true
}

option_value :: proc(
	args: []string,
	i: int,
	inline: string,
	has_inline: bool,
	name: string,
) -> (string, int, Error) {
	if has_inline {
		return inline, i + 1, ok_error()
	}
	if i + 1 >= len(args) {
		return "", i, make_error(.Usage, "%s requires a value", name)
	}
	return args[i + 1], i + 2, ok_error()
}

read_all_stdin :: proc() -> (string, Error) {
	buf := make([dynamic]byte, 0, 4096)
	chunk: [8192]byte
	for {
		n, err := os.read(os.stdin, chunk[:])
		if n > 0 {
			append(&buf, ..chunk[:n])
		}
		if err != nil {
			if err == .EOF || err == .Broken_Pipe {
				break
			}
			return "", make_error(.Usage, "failed to read stdin: %v", err)
		}
		if n == 0 {
			break
		}
	}
	if len(buf) == 0 {
		return "", ok_error()
	}
	if !platform.valid_utf8(buf[:]) {
		return "", make_error(.Usage, "prompt from stdin is not valid UTF-8")
	}
	return string(buf[:]), ok_error()
}

read_prompt :: proc(opts: Options, cwd: string) -> (string, Error) {
	prompt: string
	switch {
	case opts.print_prompt != nil:
		value, _ := opts.print_prompt.?
		if len(value) == 0 {
			return "", make_error(.Usage, "--print requires a non-empty prompt")
		}
		if !platform.valid_utf8(transmute([]byte)value) {
			return "", make_error(
				.Usage,
				"--print prompt is not valid UTF-8; on Windows check the console code page or use --input-file",
			)
		}
		prompt = value
	case opts.input_file != nil:
		path, _ := opts.input_file.?
		resolved, rerr := platform.resolve_tool_path(cwd, path)
		if !platform.is_ok(rerr) {
			return "", make_error(.Usage, "%s", rerr.message)
		}
		data, derr := os.read_entire_file_from_path(resolved, context.allocator)
		if derr != nil {
			return "", make_error(.Usage, "cannot read --input-file %s: %v", resolved, derr)
		}
		if len(data) == 0 {
			return "", make_error(.Usage, "--input-file is empty: %s", resolved)
		}
		if !platform.valid_utf8(data) {
			return "", make_error(.Usage, "--input-file is not valid UTF-8: %s", resolved)
		}
		prompt = string(data)
	case opts.print0:
		data, derr := read_all_stdin()
		if !is_ok(derr) {
			return "", derr
		}
		if len(data) == 0 {
			return "", make_error(.Usage, "--print0 received an empty prompt from stdin")
		}
		prompt = data
	case:
		if os.is_tty(os.stdin) {
			return "", make_error(
				.Usage,
				"no prompt given; use --print, --input-file, --print0, or pipe a prompt on stdin",
			)
		}
		data, derr := read_all_stdin()
		if !is_ok(derr) {
			return "", derr
		}
		if len(data) == 0 {
			return "", make_error(.Usage, "empty prompt on stdin")
		}
		prompt = data
	}
	return prompt, ok_error()
}
