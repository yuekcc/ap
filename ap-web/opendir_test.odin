package apweb

import client "../ap-core/client"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// 假启动器：只记录 handler 传下来的目标与目录，避免测试真的弹出文件管理器。
Open_Test_Launcher :: struct {
	calls:  int,
	target: Open_Target,
	cwd:    string,
	fail:   bool,
}

open_test_fn :: proc(
	target: Open_Target,
	cwd: string,
	user: rawptr,
) -> (
	ok: bool,
	message: string,
) {
	launcher := (^Open_Test_Launcher)(user)
	launcher.calls += 1
	launcher.target = target
	launcher.cwd = cwd
	if launcher.fail {
		return false, "cannot start wt.exe: Not_Exist"
	}
	return true, ""
}

open_test_fixture :: proc(t: ^testing.T, app: ^App, dir: string, launcher: ^Open_Test_Launcher) {
	api_fixture_setup(t, app, dir)
	app.open = open_test_fn
	app.open_user = rawptr(launcher)
}

// 路径在 Windows 上带反斜杠：必须走 JSON 编码，手拼字符串会产生非法转义。
open_test_body :: proc(t: ^testing.T, cwd: string) -> string {
	data, err := json.marshal(Api_Open_Body{cwd = cwd}, {}, context.temp_allocator)
	if err != nil {
		testing.expectf(t, false, "cannot encode request body: %v", err)
		return ""
	}
	return transmute(string)data
}

@(test)
test_open_reveal_uses_active_project_cwd :: proc(t: ^testing.T) {
	dir := test_temp_dir("open-reveal")
	defer os.remove_all(dir)

	app: App
	launcher: Open_Test_Launcher
	open_test_fixture(t, &app, dir, &launcher)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	response := api_call(&app, .Post, "/api/cwd/reveal")
	testing.expect_value(t, response.status, 200)
	cwd, has_cwd := api_json_field(t, api_response_text(&response), "cwd")
	testing.expect(t, has_cwd, "response must echo the working directory")
	testing.expect_value(t, cwd.(string), dir)
	testing.expect_value(t, launcher.calls, 1)
	testing.expect_value(t, launcher.target, Open_Target.Files)
	testing.expect_value(t, launcher.cwd, dir)
}

@(test)
test_open_terminal_uses_requested_cwd :: proc(t: ^testing.T) {
	dir := test_temp_dir("open-terminal")
	defer os.remove_all(dir)

	app: App
	launcher: Open_Test_Launcher
	open_test_fixture(t, &app, dir, &launcher)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	response := api_call(&app, .Post, "/api/cwd/terminal", body = open_test_body(t, dir))
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, launcher.calls, 1)
	testing.expect_value(t, launcher.target, Open_Target.Terminal)
	// 显式传入的 cwd 会走 locate_project/canonicalize，Windows 上大小写与分隔符会变。
	expected, expected_err := client.canonicalize_path(dir, true)
	testing.expect_value(t, expected_err.message, "")
	testing.expect_value(t, launcher.cwd, expected)
}

// 目录不存在时不能把请求透给启动器：那会拉起一个 cwd 不存在的进程。
@(test)
test_open_missing_cwd_is_rejected :: proc(t: ^testing.T) {
	dir := test_temp_dir("open-missing")
	defer os.remove_all(dir)

	app: App
	launcher: Open_Test_Launcher
	open_test_fixture(t, &app, dir, &launcher)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	missing := fmt.aprintf("%s/nope", dir)
	response := api_call(&app, .Post, "/api/cwd/reveal", body = open_test_body(t, missing))
	testing.expect_value(t, response.status, 400)
	testing.expect(t, strings.contains(api_response_text(&response), `"code":"invalid_cwd"`))
	testing.expect_value(t, launcher.calls, 0)
}

@(test)
test_open_launch_failure_returns_500 :: proc(t: ^testing.T) {
	dir := test_temp_dir("open-failed")
	defer os.remove_all(dir)

	app: App
	launcher := Open_Test_Launcher{fail = true}
	open_test_fixture(t, &app, dir, &launcher)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	response := api_call(&app, .Post, "/api/cwd/terminal")
	testing.expect_value(t, response.status, 500)
	body := api_response_text(&response)
	testing.expect(t, strings.contains(body, `"code":"open_failed"`))
	testing.expect(t, strings.contains(body, "wt.exe"))
}

// explorer/wt 只认反斜杠：正斜杠路径会被 explorer 静默退到「文档」。
@(test)
test_open_windows_path_uses_backslashes :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		testing.expect_value(t, windows_path("z:/projects/ap/tmp/x"), `z:\projects\ap\tmp\x`)
		testing.expect_value(t, windows_path(`c:\already\windows`), `c:\already\windows`)
	}
}
