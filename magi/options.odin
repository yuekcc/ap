package magi

import apcore "../ap-core"
import platform "../ap-core/platform"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// CLI 参数与输入解析。SDK 不读 argv，也不隐式读 stdin；
// 这些语义都属于 magi。

Output_Format :: enum {
	Json,
	Text,
}

Options :: struct {
	question:      Maybe(string),
	context_text:  Maybe(string),
	context_file:  Maybe(string),
	input_file:    Maybe(string),
	print0:        bool,
	config_dir:    Maybe(string),
	model:         Maybe(string),
	max_tokens:    Maybe(int),
	output_format: Output_Format,
	verbose:       bool,
	debug:         bool,
	help:          bool,
	version:       bool,
}

// 一次 MAGI 请求。question 是决议对象，context 是可选材料。
Magi_Request :: struct {
	question: string `json:"question"`,
	material: string `json:"context,omitempty"`,
}

option_value :: proc(
	args: []string,
	i: int,
	inline: string,
	has_inline: bool,
	name: string,
) -> (string, int, apcore.Error) {
	if has_inline {
		return inline, i + 1, apcore.ok_error()
	}
	if i + 1 >= len(args) {
		return "", i, apcore.errorf(.Usage, "%s requires a value", name)
	}
	return args[i + 1], i + 2, apcore.ok_error()
}

parse_args :: proc(args: []string) -> (Options, apcore.Error) {
	opts := Options {
		output_format = .Json,
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
		case "-q", "--question":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !apcore.is_ok(err) {
				return opts, err
			}
			opts.question = value
			i = n
		case "--context":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !apcore.is_ok(err) {
				return opts, err
			}
			opts.context_text = value
			i = n
		case "--context-file":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !apcore.is_ok(err) {
				return opts, err
			}
			opts.context_file = value
			i = n
		case "--input-file":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !apcore.is_ok(err) {
				return opts, err
			}
			opts.input_file = value
			i = n
		case "--print0":
			if has_inline {
				return opts, apcore.errorf(.Usage, "%s does not take a value", name)
			}
			opts.print0 = true
			i += 1
		case "--config-dir":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !apcore.is_ok(err) {
				return opts, err
			}
			opts.config_dir = value
			i = n
		case "--model":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !apcore.is_ok(err) {
				return opts, err
			}
			opts.model = value
			i = n
		case "--max-tokens":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !apcore.is_ok(err) {
				return opts, err
			}
			parsed, ok := strconv.parse_int(value, 10)
			if !ok || parsed <= 0 {
				return opts, apcore.errorf(.Usage, "--max-tokens must be a positive integer")
			}
			opts.max_tokens = parsed
			i = n
		case "--output-format":
			value, n, err := option_value(args, i, inline, has_inline, name)
			if !apcore.is_ok(err) {
				return opts, err
			}
			switch value {
			case "json":
				opts.output_format = .Json
			case "text":
				opts.output_format = .Text
			case:
				return opts, apcore.errorf(.Usage, "unknown output format %q (expected json or text)", value)
			}
			i = n
		case "--verbose":
			if has_inline {
				return opts, apcore.errorf(.Usage, "%s does not take a value", name)
			}
			opts.verbose = true
			i += 1
		case "--debug":
			if has_inline {
				return opts, apcore.errorf(.Usage, "%s does not take a value", name)
			}
			opts.debug = true
			i += 1
		case:
			return opts, apcore.errorf(.Usage, "unknown argument: %s", arg)
		}
	}

	if opts.help || opts.version {
		return opts, apcore.ok_error()
	}

	if opts.context_text != nil && opts.context_file != nil {
		return opts, apcore.errorf(.Usage, "--context and --context-file cannot be used together")
	}

	request_sources := 0
	if opts.question != nil {
		request_sources += 1
	}
	if opts.input_file != nil {
		request_sources += 1
	}
	if opts.print0 {
		request_sources += 1
	}
	if request_sources > 1 {
		return opts, apcore.errorf(
			.Usage,
			"--question, --input-file and --print0 are mutually exclusive",
		)
	}
	if opts.input_file != nil || opts.print0 {
		if opts.context_text != nil || opts.context_file != nil {
			return opts, apcore.errorf(
				.Usage,
				"--context and --context-file belong inside the JSON request when using --input-file or --print0",
			)
		}
	}
	if request_sources == 0 {
		return opts, apcore.errorf(
			.Usage,
			"no request given; use --question, --input-file, or --print0",
		)
	}
	return opts, apcore.ok_error()
}

read_all_stdin :: proc() -> (string, apcore.Error) {
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
			return "", apcore.errorf(.Usage, "failed to read stdin: %v", err)
		}
		if n == 0 {
			break
		}
	}
	if len(buf) == 0 {
		return "", apcore.ok_error()
	}
	if !platform.valid_utf8(buf[:]) {
		return "", apcore.errorf(.Usage, "request from stdin is not valid UTF-8")
	}
	return string(buf[:]), apcore.ok_error()
}

parse_request_json :: proc(text, origin: string) -> (Magi_Request, apcore.Error) {
	value, err := json.parse_string(text, .JSON, true)
	if err != nil {
		return {}, apcore.errorf(.Usage, "invalid JSON in %s: %v", origin, err)
	}
	obj, ok := value.(json.Object)
	if !ok {
		return {}, apcore.errorf(.Usage, "%s must contain a JSON object", origin)
	}

	request := Magi_Request{}
	question_value, has_question := obj["question"]
	if !has_question {
		return {}, apcore.errorf(.Usage, "%s: question is required", origin)
	}
	question, is_string := question_value.(json.String)
	if !is_string {
		return {}, apcore.errorf(.Usage, "%s: question must be a string", origin)
	}
	request.question = string(question)

	if context_value, has_context := obj["context"]; has_context {
		#partial switch v in context_value {
		case json.String:
			request.material = string(v)
		case json.Null:
		case:
			return {}, apcore.errorf(.Usage, "%s: context must be a string", origin)
		}
	}

	if !has_non_space(request.question) {
		return {}, apcore.errorf(.Usage, "%s: question must not be empty", origin)
	}
	return request, apcore.ok_error()
}

has_non_space :: proc(text: string) -> bool {
	for ch in text {
		if ch != ' ' && ch != '\t' && ch != '\r' && ch != '\n' {
			return true
		}
	}
	return false
}

read_text_file :: proc(path, label: string) -> (string, apcore.Error) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return "", apcore.errorf(.Usage, "cannot read %s %s: %v", label, path, err)
	}
	if !platform.valid_utf8(data) {
		return "", apcore.errorf(.Usage, "%s is not valid UTF-8: %s", label, path)
	}
	return string(data), apcore.ok_error()
}

read_request :: proc(opts: Options, cwd: string) -> (Magi_Request, apcore.Error) {
	if opts.input_file != nil {
		path, _ := opts.input_file.?
		resolved, rerr := platform.resolve_tool_path(cwd, path)
		if !platform.is_ok(rerr) {
			return {}, apcore.errorf(.Usage, "%s", rerr.message)
		}
		text, terr := read_text_file(resolved, "--input-file")
		if !apcore.is_ok(terr) {
			return {}, terr
		}
		return parse_request_json(text, resolved)
	}
	if opts.print0 {
		text, terr := read_all_stdin()
		if !apcore.is_ok(terr) {
			return {}, terr
		}
		if len(text) == 0 {
			return {}, apcore.errorf(.Usage, "--print0 received an empty request from stdin")
		}
		return parse_request_json(text, "stdin")
	}

	question_value, _ := opts.question.?
	request := Magi_Request {
		question = question_value,
	}
	if !has_non_space(request.question) {
		return {}, apcore.errorf(.Usage, "--question must not be empty")
	}
	if opts.context_text != nil {
		value, _ := opts.context_text.?
		request.material = value
	} else if opts.context_file != nil {
		path, _ := opts.context_file.?
		resolved, rerr := platform.resolve_tool_path(cwd, path)
		if !platform.is_ok(rerr) {
			return {}, apcore.errorf(.Usage, "%s", rerr.message)
		}
		text, terr := read_text_file(resolved, "--context-file")
		if !apcore.is_ok(terr) {
			return {}, terr
		}
		request.material = text
	}
	return request, apcore.ok_error()
}

print_usage :: proc() {
	fmt.println(
		`magi-cli - 由三名角色投票的 MAGI 决策器

用法:
  magi-cli --question <问题> [--context <材料> | --context-file <路径>] [选项]
  magi-cli --input-file <request.json> [选项]
  magi-cli --print0 [选项] < request.json

请求 JSON:
  {"question": "是否包含恶意行为", "context": "<材料>"}

选项:
  -q, --question <文本>       决议问题
      --context <文本>        内联材料
      --context-file <路径>   从 UTF-8 文件读取材料
      --input-file <路径>     读取完整 JSON 请求
      --print0                从 stdin 读取完整 JSON 请求
      --config-dir <目录>     配置目录（默认 $AP_CONFIG 或 ~/.ap）
      --model <id>            覆盖 settings.json 的 model
      --max-tokens <n>        覆盖单次响应的 max_tokens
      --output-format <格式>  json（默认）或 text
      --verbose               把成员进度写到 stderr
      --debug                 输出更详细的诊断日志
  -h, --help                  显示帮助
      --version               显示版本

退出码:
  0  决议完成（通过与否决都算完成）
  2  参数、输入或配置错误
  3  至少一名成员未能完成投票（决议按否决处理）
  1  内部错误
  130 SIGINT, 143 SIGTERM
`,
	)
}
