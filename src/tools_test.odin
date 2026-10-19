package ap

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

test_cancel_thread_token: ^Cancel_Token

test_cancel_thread :: proc() {
	time.sleep(300 * time.Millisecond)
	cancel_token_cancel(test_cancel_thread_token)
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

tool_test_context :: proc(t: ^testing.T, name: string) -> (Tool_Context, string) {
	dir := test_temp_dir(name)
	project, perr := open_project(fmt.tprintf("%s/config", dir), dir)
	testing.expect_value(t, perr.code, Exit_Code.OK)
	settings := new(Settings)
	settings^ = settings_defaults()
	settings.max_capture_bytes = 1024 * 1024
	bash, berr := find_bash()
	testing.expect_value(t, berr.code, Exit_Code.OK)
	ctx := Tool_Context {
		cwd = dir,
		project = project,
		settings = settings,
		cancel = new(Cancel_Token),
		session_id = "s",
		agent_name = "general",
		config_dir = fmt.tprintf("%s/config", dir),
		bash_path = bash,
		model = "m",
		max_steps = 10,
	}
	return ctx, dir
}

@(test)
test_read_file_basic_and_pagination :: proc(t: ^testing.T) {
	ctx, dir := tool_test_context(t, "tool-read")
	defer test_cleanup(dir)
	path := fmt.tprintf("%s/sample.txt", dir)
	test_write_file(path, "alpha\nbeta\ngamma\n")

	res := tool_execute("read_file", json.Value(json_obj(test_json(`{"file_path":%q}`, path))), &ctx)
	testing.expect(t, res.ok)
	testing.expect(t, test_contains(res.content, "lines 1-3 of 3"))
	testing.expect(t, test_contains(res.content, "alpha\nbeta\ngamma"))

	res2 := tool_execute(
		"read_file",
		json.Value(json_obj(test_json(`{"file_path":%q,"start_line":2,"end_line":2}`, path))),
		&ctx,
	)
	testing.expect(t, res2.ok)
	testing.expect(t, test_contains(res2.content, "lines 2-2 of 3"))
	testing.expect(t, test_contains(res2.content, "\nbeta"))
	testing.expect(t, test_contains(res2.content, "继续请用 start_line=3"))

	res3 := tool_execute(
		"read_file",
		json.Value(json_obj(test_json(`{"file_path":%q,"start_line":10}`, path))),
		&ctx,
	)
	testing.expect(t, res3.ok)
	testing.expect(t, test_contains(res3.content, "lines 10-9 of 3"))
}

@(test)
test_read_file_crlf_and_utf8_errors :: proc(t: ^testing.T) {
	ctx, dir := tool_test_context(t, "tool-read-utf8")
	defer test_cleanup(dir)
	crlf := fmt.tprintf("%s/crlf.txt", dir)
	test_write_file(crlf, "a\r\nb\r\n")
	res := tool_execute("read_file", json.Value(json_obj(test_json(`{"file_path":%q}`, crlf))), &ctx)
	testing.expect(t, res.ok)
	testing.expect(t, test_contains(res.content, "a\nb"))
	testing.expect(t, !test_contains(res.content, "\r"))

	binary := fmt.tprintf("%s/bin.dat", dir)
	data: []byte = {0xff, 0xfe, 0x00, 0x01}
	_ = os.write_entire_file_from_bytes(binary, data)
	res2 := tool_execute("read_file", json.Value(json_obj(test_json(`{"file_path":%q}`, binary))), &ctx)
	testing.expect(t, !res2.ok)

	dir_res := tool_execute("read_file", json.Value(json_obj(test_json(`{"file_path":%q}`, dir))), &ctx)
	testing.expect(t, !dir_res.ok)

	missing := tool_execute(
		"read_file",
		json.Value(json_obj(test_json(`{"file_path":%q}`, fmt.tprintf("%s/nope", dir)))),
		&ctx,
	)
	testing.expect(t, !missing.ok)
}

@(test)
test_read_file_2000_line_cap :: proc(t: ^testing.T) {
	ctx, dir := tool_test_context(t, "tool-read-cap")
	defer test_cleanup(dir)
	path := fmt.tprintf("%s/big.txt", dir)
	b := strings.builder_make()
	for i in 1 ..= 2500 {
		fmt.sbprintf(&b, "line %d\n", i)
	}
	test_write_file(path, strings.to_string(b))

	res := tool_execute(
		"read_file",
		json.Value(json_obj(test_json(`{"file_path":%q,"start_line":1,"end_line":3000}`, path))),
		&ctx,
	)
	testing.expect(t, res.ok)
	testing.expect(t, test_contains(res.content, "lines 1-2000 of 2500"))
	testing.expect(t, test_contains(res.content, "已截断到 2000 行"))
	testing.expect(t, test_contains(res.content, "继续请用 start_line=2001"))
}

@(test)
test_read_file_single_line_limit :: proc(t: ^testing.T) {
	ctx, dir := tool_test_context(t, "tool-read-line")
	defer test_cleanup(dir)
	ctx.settings.max_capture_bytes = 64
	path := fmt.tprintf("%s/long.txt", dir)
	test_write_file(path, strings.repeat("x", 200))
	res := tool_execute("read_file", json.Value(json_obj(test_json(`{"file_path":%q}`, path))), &ctx)
	testing.expect(t, !res.ok)
}

@(test)
test_write_file_and_edit :: proc(t: ^testing.T) {
	ctx, dir := tool_test_context(t, "tool-write")
	defer test_cleanup(dir)
	path := fmt.tprintf("%s/sub/out.txt", dir)
	res := tool_execute(
		"write_file",
		json.Value(json_obj(test_json(`{"file_path":%q,"content":"one\r\ntwo\r\n"}`, path))),
		&ctx,
	)
	testing.expect(t, res.ok)
	testing.expect_value(t, test_read_file(path), "one\ntwo\n")
	testing.expect(t, test_contains(res.content, "wrote"))

	edit := tool_execute(
		"edit_file",
		json.Value(json_obj(test_json(`{"file_path":%q,"old_string":"two","new_string":"three"}`, path))),
		&ctx,
	)
	testing.expect(t, edit.ok)
	testing.expect_value(t, test_read_file(path), "one\nthree\n")

	multi := fmt.tprintf("%s/multi.txt", dir)
	test_write_file(multi, "x x x\n")
	edit_multi := tool_execute(
		"edit_file",
		json.Value(json_obj(test_json(`{"file_path":%q,"old_string":"x","new_string":"y"}`, multi))),
		&ctx,
	)
	testing.expect(t, !edit_multi.ok)
	testing.expect(t, test_contains(edit_multi.error, "matched 3 times"))
	testing.expect_value(t, test_read_file(multi), "x x x\n")

	edit_all := tool_execute(
		"edit_file",
		json.Value(
			json_obj(test_json(`{"file_path":%q,"old_string":"x","new_string":"y","replace_all":true}`, multi)),
		),
		&ctx,
	)
	testing.expect(t, edit_all.ok)
	testing.expect_value(t, test_read_file(multi), "y y y\n")

	edit_none := tool_execute(
		"edit_file",
		json.Value(json_obj(test_json(`{"file_path":%q,"old_string":"zzz","new_string":"q"}`, multi))),
		&ctx,
	)
	testing.expect(t, !edit_none.ok)
	testing.expect(t, test_contains(edit_none.error, "not found"))
}

@(test)
test_tool_argument_validation :: proc(t: ^testing.T) {
	ctx, dir := tool_test_context(t, "tool-args")
	defer test_cleanup(dir)
	res := tool_execute("read_file", json.Value(json_obj(`{}`)), &ctx)
	testing.expect(t, !res.ok)
	testing.expect(t, test_contains(res.error, "file_path"))

	res2 := tool_execute("write_file", json.Value(json_obj(`{"file_path":"x"}`)), &ctx)
	testing.expect(t, !res2.ok)

	res3 := tool_execute("bash", json.Value(json_obj(`{"command":""}`)), &ctx)
	testing.expect(t, !res3.ok)
}

@(test)
test_bash_success_and_exit_code :: proc(t: ^testing.T) {
	ctx, dir := tool_test_context(t, "tool-bash")
	defer test_cleanup(dir)
	res := tool_execute("bash", json.Value(json_obj(`{"command":"echo hello; echo err >&2"}`)), &ctx)
	testing.expect(t, res.ok)
	testing.expect(t, test_contains(res.content, "[exit 0,"))
	testing.expect(t, test_contains(res.content, "hello"))
	testing.expect(t, test_contains(res.content, "err"))

	res2 := tool_execute("bash", json.Value(json_obj(`{"command":"exit 3"}`)), &ctx)
	testing.expect(t, res2.ok)
	testing.expect(t, test_contains(res2.content, "[exit 3,"))
	testing.expect_value(t, res2.exit_code.?, 3)
}

@(test)
test_bash_timeout_kills_tree :: proc(t: ^testing.T) {
	ctx, dir := tool_test_context(t, "tool-bash-timeout")
	defer test_cleanup(dir)
	sentinel := fmt.tprintf("%s/leaked.txt", dir)
	command := fmt.tprintf(`(sleep 1; echo leaked > "%s") & sleep 30; wait`, sentinel)
	res := tool_execute(
		"bash",
		json.Value(json_obj(test_json(`{"command":%q,"timeout_ms":300}`, command))),
		&ctx,
	)
	testing.expect(t, !res.ok)
	testing.expect(t, test_contains(res.error, "timeout after 300ms"))
	time.sleep(1200 * time.Millisecond)
	testing.expect(t, !os.exists(sentinel))
}

@(test)
test_bash_large_output_not_truncated :: proc(t: ^testing.T) {
	ctx, dir := tool_test_context(t, "tool-bash-large")
	defer test_cleanup(dir)
	res := tool_execute("bash", json.Value(json_obj(`{"command":"seq 1 60000"}`)), &ctx)
	testing.expect(t, res.ok)
	testing.expect(t, len(res.content) > 250000)
	testing.expect(t, test_contains(res.content, "\n60000"))
}

@(test)
test_bash_output_limit :: proc(t: ^testing.T) {
	ctx, dir := tool_test_context(t, "tool-bash-limit")
	defer test_cleanup(dir)
	ctx.settings.max_capture_bytes = 1000
	res := tool_execute(
		"bash",
		json.Value(json_obj(`{"command":"yes x | head -c 5000"}`)),
		&ctx,
	)
	testing.expect(t, !res.ok)
	testing.expect(t, test_contains(res.error, "output exceeded"))
}

@(test)
test_bash_cancel_kills_process_tree :: proc(t: ^testing.T) {
	ctx, dir := tool_test_context(t, "tool-bash-cancel")
	defer test_cleanup(dir)
	test_cancel_thread_token = ctx.cancel
	th := thread.create_and_start(test_cancel_thread)
	started := time.tick_now()
	res := tool_execute("bash", json.Value(json_obj(`{"command":"sleep 30"}`)), &ctx)
	elapsed := time.tick_since(started)
	thread.join(th)
	testing.expect(t, !res.ok)
	testing.expect(t, test_contains(res.error, "cancelled"))
	testing.expect(t, elapsed < 5 * time.Second)
}

@(test)
test_bash_strips_api_key :: proc(t: ^testing.T) {
	ctx, dir := tool_test_context(t, "tool-bash-env")
	defer test_cleanup(dir)
	os.set_env("AP_API_KEY", "secret-value")
	defer os.unset_env("AP_API_KEY")
	res := tool_execute("bash", json.Value(json_obj(`{"command":"test -z \"$AP_API_KEY\" && echo stripped"}`)), &ctx)
	testing.expect(t, res.ok)
	testing.expect(t, test_contains(res.content, "stripped"))
}

@(test)
test_tool_definitions_are_valid :: proc(t: ^testing.T) {
	agent := agent_default_general()
	defs, err := tool_definitions(agent, 0, 1)
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, len(defs), 5)
	for def in defs {
		testing.expect(t, len(def.function.name) > 0)
		testing.expect(t, def.function.parameters != nil)
	}
	defs2, _ := tool_definitions(agent, 1, 1)
	testing.expect_value(t, len(defs2), 4)
}
