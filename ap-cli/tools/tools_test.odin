package aptools

import platform "../../ap-core/platform"
import tool "../../ap-core/tool"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

test_cancel_thread_token: ^platform.Cancel_Token

test_cancel_thread :: proc() {
	time.sleep(300 * time.Millisecond)
	platform.cancel_token_cancel(test_cancel_thread_token)
}

test_json :: proc(format: string, args: ..any) -> string {
	b := strings.builder_make()
	for ch in format {
		if ch == '{' || ch == '}' {
			strings.write_rune(&b, ch)
		}
		strings.write_rune(&b, ch)
	}
	return fmt.tprintf(strings.to_string(b), ..args)
}

json_obj :: proc(text: string) -> json.Object {
	value, err := json.parse_string(text, .JSON, true)
	if err != nil {
		panic("invalid test JSON")
	}
	obj, ok := value.(json.Object)
	if !ok {
		panic("test JSON is not an object")
	}
	return obj
}

test_temp_dir :: proc(prefix: string) -> string {
	base := os.get_env("TEMP", context.allocator)
	if len(base) == 0 {
		base = os.get_env("TMPDIR", context.allocator)
	}
	if len(base) == 0 {
		base = "."
	}
	name := fmt.tprintf("%s/ap-tools-test-%s-%d", base, prefix, time.time_to_unix_nano(time.now()))
	os.make_directory_all(name)
	return name
}

test_write_file :: proc(path, content: string) {
	dir, _ := os.split_path(path)
	if len(dir) > 0 {
		os.make_directory_all(dir)
	}
	if err := os.write_entire_file_from_bytes(path, transmute([]byte)content); err != nil {
		panic("failed to write test file")
	}
}

test_read_file :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		panic("failed to read test file")
	}
	return string(data)
}

test_cleanup :: proc(dir: string) {
	os.remove_all(dir)
}

test_contains :: proc(haystack, needle: string) -> bool {
	return strings.contains(haystack, needle)
}

Test_Tools :: struct {
	ctx:      tool.Tool_Context,
	cfg:      ^Tool_Config,
	registry: tool.Registry,
	dir:      string,
}

tool_test_context :: proc(t: ^testing.T, name: string) -> Test_Tools {
	dir := test_temp_dir(name)
	project, perr := platform.open_project(fmt.tprintf("%s/config", dir), dir)
	testing.expect(t, platform.is_ok(perr))
	cfg := new(Tool_Config)
	cfg.config_dir = fmt.tprintf("%s/config", dir)
	cfg.tool_timeout_ms = 120000
	cfg.max_capture_bytes = 1024 * 1024
	cfg.max_agent_depth = 1
	bash, berr := platform.find_bash()
	testing.expect(t, platform.is_ok(berr))
	cfg.bash_path = bash
	cfg.self_exe = "/bin/ap"
	cfg.model = "m"
	cfg.max_steps = 10
	defs := builtin_tools(cfg)
	registry, rerr := tool.registry_init(defs)
	testing.expect(t, platform.is_ok(rerr))
	ctx := tool.Tool_Context {
		cwd = dir,
		project = project,
		cancel = new(platform.Cancel_Token),
		session_id = "s",
		parent_session_id = "parent-s",
		tool_call_id = "call_1",
		agent_name = "general",
		transcript_path = platform.session_file(project, "s"),
	}
	return {ctx = ctx, cfg = cfg, registry = registry, dir = dir}
}

@(test)
test_read_file_basic_and_pagination :: proc(t: ^testing.T) {
	tt := tool_test_context(t, "tool-read")
	defer test_cleanup(tt.dir)
	path := fmt.tprintf("%s/sample.txt", tt.dir)
	test_write_file(path, "alpha\nbeta\ngamma\n")

	res := tool.tool_execute(&tt.registry, "read_file", json.Value(json_obj(test_json(`{"file_path":%q}`, path))), &tt.ctx)
	testing.expect(t, res.ok)
	testing.expect(t, test_contains(res.content, "lines 1-3 of 3"))
	testing.expect(t, test_contains(res.content, "\n1\talpha\n2\tbeta\n3\tgamma"))

	res2 := tool.tool_execute(
		&tt.registry,
		"read_file",
		json.Value(json_obj(test_json(`{"file_path":%q,"start_line":2,"end_line":2}`, path))),
		&tt.ctx,
	)
	testing.expect(t, res2.ok)
	testing.expect(t, test_contains(res2.content, "lines 2-2 of 3"))
	testing.expect(t, test_contains(res2.content, "\n2\tbeta"))
	testing.expect(t, test_contains(res2.content, "继续请用 start_line=3"))

	res3 := tool.tool_execute(
		&tt.registry,
		"read_file",
		json.Value(json_obj(test_json(`{"file_path":%q,"start_line":10}`, path))),
		&tt.ctx,
	)
	testing.expect(t, res3.ok)
	testing.expect(t, test_contains(res3.content, "lines 10-9 of 3"))
}

@(test)
test_read_file_crlf_and_utf8_errors :: proc(t: ^testing.T) {
	tt := tool_test_context(t, "tool-read-utf8")
	defer test_cleanup(tt.dir)
	crlf := fmt.tprintf("%s/crlf.txt", tt.dir)
	test_write_file(crlf, "a\r\nb\r\n")
	res := tool.tool_execute(&tt.registry, "read_file", json.Value(json_obj(test_json(`{"file_path":%q}`, crlf))), &tt.ctx)
	testing.expect(t, res.ok)
	testing.expect(t, test_contains(res.content, "\n1\ta\n2\tb"))
	testing.expect(t, !test_contains(res.content, "\r"))

	binary := fmt.tprintf("%s/bin.dat", tt.dir)
	data: []byte = {0xff, 0xfe, 0x00, 0x01}
	_ = os.write_entire_file_from_bytes(binary, data)
	res2 := tool.tool_execute(&tt.registry, "read_file", json.Value(json_obj(test_json(`{"file_path":%q}`, binary))), &tt.ctx)
	testing.expect(t, !res2.ok)

	dir_res := tool.tool_execute(&tt.registry, "read_file", json.Value(json_obj(test_json(`{"file_path":%q}`, tt.dir))), &tt.ctx)
	testing.expect(t, !dir_res.ok)

	missing := tool.tool_execute(
		&tt.registry,
		"read_file",
		json.Value(json_obj(test_json(`{"file_path":%q}`, fmt.tprintf("%s/nope", tt.dir)))),
		&tt.ctx,
	)
	testing.expect(t, !missing.ok)
}

@(test)
test_read_file_2000_line_cap :: proc(t: ^testing.T) {
	tt := tool_test_context(t, "tool-read-cap")
	defer test_cleanup(tt.dir)
	path := fmt.tprintf("%s/big.txt", tt.dir)
	b := strings.builder_make()
	for i in 1 ..= 2500 {
		fmt.sbprintf(&b, "line %d\n", i)
	}
	test_write_file(path, strings.to_string(b))

	res := tool.tool_execute(
		&tt.registry,
		"read_file",
		json.Value(json_obj(test_json(`{"file_path":%q,"start_line":1,"end_line":3000}`, path))),
		&tt.ctx,
	)
	testing.expect(t, res.ok)
	testing.expect(t, test_contains(res.content, "lines 1-2000 of 2500"))
	testing.expect(t, test_contains(res.content, "已截断到 2000 行"))
	testing.expect(t, test_contains(res.content, "继续请用 start_line=2001"))
}

@(test)
test_read_file_single_line_limit :: proc(t: ^testing.T) {
	tt := tool_test_context(t, "tool-read-line")
	defer test_cleanup(tt.dir)
	tt.cfg.max_capture_bytes = 64
	path := fmt.tprintf("%s/long.txt", tt.dir)
	test_write_file(path, strings.repeat("x", 200))
	res := tool.tool_execute(&tt.registry, "read_file", json.Value(json_obj(test_json(`{"file_path":%q}`, path))), &tt.ctx)
	testing.expect(t, !res.ok)
}

@(test)
test_write_file_and_edit :: proc(t: ^testing.T) {
	tt := tool_test_context(t, "tool-write")
	defer test_cleanup(tt.dir)
	path := fmt.tprintf("%s/sub/out.txt", tt.dir)
	res := tool.tool_execute(
		&tt.registry,
		"write_file",
		json.Value(json_obj(test_json(`{"file_path":%q,"content":"one\r\ntwo\r\n"}`, path))),
		&tt.ctx,
	)
	testing.expect(t, res.ok)
	testing.expect_value(t, test_read_file(path), "one\ntwo\n")
	testing.expect(t, test_contains(res.content, "wrote"))

	edit := tool.tool_execute(
		&tt.registry,
		"edit_file",
		json.Value(json_obj(test_json(`{"file_path":%q,"old_string":"two","new_string":"three"}`, path))),
		&tt.ctx,
	)
	testing.expect(t, edit.ok)
	testing.expect_value(t, test_read_file(path), "one\nthree\n")

	multi := fmt.tprintf("%s/multi.txt", tt.dir)
	test_write_file(multi, "x x x\n")
	edit_multi := tool.tool_execute(
		&tt.registry,
		"edit_file",
		json.Value(json_obj(test_json(`{"file_path":%q,"old_string":"x","new_string":"y"}`, multi))),
		&tt.ctx,
	)
	testing.expect(t, !edit_multi.ok)
	testing.expect(t, test_contains(edit_multi.error, "matched 3 times"))
	testing.expect_value(t, test_read_file(multi), "x x x\n")

	edit_all := tool.tool_execute(
		&tt.registry,
		"edit_file",
		json.Value(
			json_obj(test_json(`{"file_path":%q,"old_string":"x","new_string":"y","replace_all":true}`, multi)),
		),
		&tt.ctx,
	)
	testing.expect(t, edit_all.ok)
	testing.expect_value(t, test_read_file(multi), "y y y\n")

	edit_none := tool.tool_execute(
		&tt.registry,
		"edit_file",
		json.Value(json_obj(test_json(`{"file_path":%q,"old_string":"zzz","new_string":"q"}`, multi))),
		&tt.ctx,
	)
	testing.expect(t, !edit_none.ok)
	testing.expect(t, test_contains(edit_none.error, "not found"))
}

@(test)
test_tool_argument_validation :: proc(t: ^testing.T) {
	tt := tool_test_context(t, "tool-args")
	defer test_cleanup(tt.dir)
	res := tool.tool_execute(&tt.registry, "read_file", json.Value(json_obj(`{}`)), &tt.ctx)
	testing.expect(t, !res.ok)
	testing.expect(t, test_contains(res.error, "file_path"))

	res2 := tool.tool_execute(&tt.registry, "write_file", json.Value(json_obj(`{"file_path":"x"}`)), &tt.ctx)
	testing.expect(t, !res2.ok)

	res3 := tool.tool_execute(&tt.registry, "bash", json.Value(json_obj(`{"command":""}`)), &tt.ctx)
	testing.expect(t, !res3.ok)
}

@(test)
test_bash_success_and_exit_code :: proc(t: ^testing.T) {
	tt := tool_test_context(t, "tool-bash")
	defer test_cleanup(tt.dir)
	res := tool.tool_execute(&tt.registry, "bash", json.Value(json_obj(`{"command":"echo hello; echo err >&2"}`)), &tt.ctx)
	testing.expect(t, res.ok)
	testing.expect(t, test_contains(res.content, "[exit 0,"))
	testing.expect(t, test_contains(res.content, "hello"))
	testing.expect(t, test_contains(res.content, "err"))

	res2 := tool.tool_execute(&tt.registry, "bash", json.Value(json_obj(`{"command":"exit 3"}`)), &tt.ctx)
	testing.expect(t, res2.ok)
	testing.expect(t, test_contains(res2.content, "[exit 3,"))
	testing.expect_value(t, res2.exit_code.?, 3)
}

@(test)
test_bash_timeout_kills_tree :: proc(t: ^testing.T) {
	tt := tool_test_context(t, "tool-bash-timeout")
	defer test_cleanup(tt.dir)
	sentinel := fmt.tprintf("%s/leaked.txt", tt.dir)
	command := fmt.tprintf(`(sleep 1; echo leaked > "%s") & sleep 30; wait`, sentinel)
	res := tool.tool_execute(
		&tt.registry,
		"bash",
		json.Value(json_obj(test_json(`{"command":%q,"timeout_ms":300}`, command))),
		&tt.ctx,
	)
	testing.expect(t, !res.ok)
	testing.expect(t, test_contains(res.error, "timeout after 300ms"))
	time.sleep(1200 * time.Millisecond)
	testing.expect(t, !os.exists(sentinel))
}

@(test)
test_bash_output_truncates_at_2000_lines :: proc(t: ^testing.T) {
	tt := tool_test_context(t, "tool-bash-large")
	defer test_cleanup(tt.dir)
	res := tool.tool_execute(&tt.registry, "bash", json.Value(json_obj(`{"command":"seq 1 2500"}`)), &tt.ctx)
	testing.expect(t, res.ok)
	testing.expect(t, test_contains(res.content, "\n2000\n"))
	testing.expect(t, !test_contains(res.content, "\n2001\n"))
	testing.expect(t, test_contains(res.content, "共 2500 行"))
	testing.expect(t, test_contains(res.content, "read_file(file_path="))

	marker := "完整输出已保存到 "
	start := strings.index(res.content, marker)
	testing.expect(t, start >= 0)
	rest := res.content[start + len(marker):]
	sep := strings.index(rest, "；")
	testing.expect(t, sep > 0)
	path := rest[:sep]
	testing.expect(t, os.exists(path))

	res2 := tool.tool_execute(
		&tt.registry,
		"read_file",
		json.Value(json_obj(test_json(`{"file_path":%q,"start_line":2001}`, path))),
		&tt.ctx,
	)
	testing.expect(t, res2.ok)
	testing.expect(t, test_contains(res2.content, "2001"))
	testing.expect(t, test_contains(res2.content, "2500"))
}

@(test)
test_bash_output_keeps_2000_lines :: proc(t: ^testing.T) {
	tt := tool_test_context(t, "tool-bash-2000")
	defer test_cleanup(tt.dir)
	res := tool.tool_execute(&tt.registry, "bash", json.Value(json_obj(`{"command":"seq 1 2000"}`)), &tt.ctx)
	testing.expect(t, res.ok)
	testing.expect(t, test_contains(res.content, "\n2000\n"))
	testing.expect(t, !test_contains(res.content, "完整输出已保存到"))
}

@(test)
test_bash_output_limit :: proc(t: ^testing.T) {
	tt := tool_test_context(t, "tool-bash-limit")
	defer test_cleanup(tt.dir)
	tt.cfg.max_capture_bytes = 1000
	res := tool.tool_execute(
		&tt.registry,
		"bash",
		json.Value(json_obj(`{"command":"yes x | head -c 5000"}`)),
		&tt.ctx,
	)
	testing.expect(t, !res.ok)
	testing.expect(t, test_contains(res.error, "output exceeded"))
}

@(test)
test_bash_cancel_kills_process_tree :: proc(t: ^testing.T) {
	tt := tool_test_context(t, "tool-bash-cancel")
	defer test_cleanup(tt.dir)
	test_cancel_thread_token = tt.ctx.cancel
	th := thread.create_and_start(test_cancel_thread)
	started := time.tick_now()
	res := tool.tool_execute(&tt.registry, "bash", json.Value(json_obj(`{"command":"sleep 30"}`)), &tt.ctx)
	elapsed := time.tick_since(started)
	thread.join(th)
	testing.expect(t, !res.ok)
	testing.expect(t, test_contains(res.error, "cancelled"))
	testing.expect(t, elapsed < 5 * time.Second)
}

@(test)
test_bash_strips_api_key :: proc(t: ^testing.T) {
	tt := tool_test_context(t, "tool-bash-env")
	defer test_cleanup(tt.dir)
	os.set_env("AP_API_KEY", "secret-value")
	defer os.unset_env("AP_API_KEY")
	res := tool.tool_execute(&tt.registry, "bash", json.Value(json_obj(`{"command":"test -z \"$AP_API_KEY\" && echo stripped"}`)), &tt.ctx)
	testing.expect(t, res.ok)
	testing.expect(t, test_contains(res.content, "stripped"))
}

@(test)
test_bash_exposes_session_environment :: proc(t: ^testing.T) {
	tt := tool_test_context(t, "tool-bash-session-env")
	defer test_cleanup(tt.dir)
	// 外层进程同名变量必须被当前 session 的值覆盖。
	os.set_env("AP_SESSION_ID", "stale")
	os.set_env("AP_PARENT_SESSION_ID", "stale-parent")
	os.set_env("AP_TRANSCRIPT_PATH", "stale-path")
	defer {
		os.unset_env("AP_SESSION_ID")
		os.unset_env("AP_PARENT_SESSION_ID")
		os.unset_env("AP_TRANSCRIPT_PATH")
	}
	command := `printf '%s|%s|%s' "$AP_SESSION_ID" "$AP_PARENT_SESSION_ID" "$AP_TRANSCRIPT_PATH"`
	res := tool.tool_execute(&tt.registry, "bash", json.Value(json_obj(test_json(`{"command":%q}`, command))), &tt.ctx)
	testing.expect(t, res.ok)
	expected := fmt.tprintf("s|parent-s|%s", tt.ctx.transcript_path)
	testing.expect(t, test_contains(res.content, expected))

	tt.ctx.parent_session_id = nil
	res2 := tool.tool_execute(&tt.registry, "bash", json.Value(json_obj(test_json(`{"command":%q}`, command))), &tt.ctx)
	testing.expect(t, res2.ok)
	expected_root := fmt.tprintf("s||%s", tt.ctx.transcript_path)
	testing.expect(t, test_contains(res2.content, expected_root))
}

@(test)
test_tool_definitions_are_valid :: proc(t: ^testing.T) {
	cfg := new(Tool_Config)
	cfg.tool_timeout_ms = 120000
	cfg.max_capture_bytes = 1024
	defs := builtin_tools(cfg)
	registry, _ := tool.registry_init(defs)
	names := tool.registry_names(&registry)
	out, err := tool.registry_definitions(&registry, names)
	testing.expect(t, platform.is_ok(err))
	testing.expect_value(t, len(out), 5)
	for def in out {
		testing.expect(t, len(def.function.name) > 0)
		testing.expect(t, def.function.parameters != nil)
	}

	none, nerr := tool.registry_definitions(&registry, []string{})
	testing.expect(t, platform.is_ok(nerr))
	testing.expect_value(t, len(none), 0)
	section := tool.registry_prompt_section(&registry, []string{})
	testing.expect_value(t, section, "（本次没有可用工具）")
}

@(test)
test_task_child_args_propagates_context_switches :: proc(t: ^testing.T) {
	ctx := tool.Tool_Context {
		session_id = "ses_parent",
		tool_call_id = "call_1",
		agent_depth = 0,
	}
	cfg := Tool_Config {
		self_exe = "/bin/ap",
		config_dir = "/cfg",
		model = "m",
		max_steps = 7,
	}
	base := task_child_args(&ctx, &cfg, "scout", cfg.max_steps)
	testing.expect(t, !has_arg_pair(base, "--tools"))
	testing.expect(t, !has_arg(base, "--no-agents-md"))
	testing.expect(t, !has_arg(base, "--no-skills"))
	testing.expect(t, has_arg_pair_value(base, "--parent-tool-call-id", "call_1"))

	cfg.no_agents_md = true
	cfg.no_skills = true
	args := task_child_args(&ctx, &cfg, "scout", cfg.max_steps)
	testing.expect(t, has_arg(args, "--no-agents-md"))
	testing.expect(t, has_arg(args, "--no-skills"))
	testing.expect(t, !has_arg_pair(args, "--tools"))
	testing.expect(t, !has_arg_pair(args, "--base-system-prompt"))
	testing.expect(t, !has_arg_pair(args, "--append-system-prompt"))
}

has_arg :: proc(args: []string, flag: string) -> bool {
	for arg in args {
		if arg == flag {
			return true
		}
	}
	return false
}

has_arg_pair :: proc(args: []string, flag: string) -> bool {
	for i in 0 ..< len(args) - 1 {
		if args[i] == flag {
			return true
		}
	}
	return false
}

has_arg_pair_value :: proc(args: []string, flag, value: string) -> bool {
	for i in 0 ..< len(args) - 1 {
		if args[i] == flag && args[i + 1] == value {
			return true
		}
	}
	return false
}

@(test)
test_tools_brief_order_and_empty :: proc(t: ^testing.T) {
	names := builtin_tool_names()
	text := tools_brief(names)
	testing.expect(t, test_contains(text, "1. read_file:"))
	testing.expect(t, test_contains(text, "5. task:"))
	read_pos := strings.index(text, "1. read_file:")
	task_pos := strings.index(text, "5. task:")
	testing.expect(t, read_pos < task_pos)

	testing.expect_value(t, tools_brief([]string{}), "No tool found\n")
	info, _ := tool_info_by_name("bash")
	testing.expect_value(t, tools_brief([]string{"bash"}), fmt.tprintf("1. bash: %s\n", info.description))
}
