package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// 假 picker：与生产实现同签名，记调用次数，可选阻塞来模拟「对话框已打开」。
// 结果所有权按约定转交给 handler（返回后清空自己那份）。
Pick_Test_Picker :: struct {
	calls:    int,
	result:   Pick_Result,
	blocking: bool,
	entered:  i32,
	release:  i32,
}

pick_test_fn :: proc(user: rawptr) -> Pick_Result {
	picker := (^Pick_Test_Picker)(user)
	picker.calls += 1
	if picker.blocking {
		sync.atomic_store(&picker.entered, 1)
		start := time.tick_now()
		for sync.atomic_load(&picker.release) == 0 && time.tick_since(start) < 10 * time.Second {
			time.sleep(time.Millisecond)
		}
	}
	result := picker.result
	picker.result = {}
	return result
}

pick_test_fixture :: proc(t: ^testing.T, app: ^App, dir: string, picker: ^Pick_Test_Picker) {
	api_fixture_setup(t, app, dir)
	app.pick = pick_test_fn
	app.pick_user = rawptr(picker)
}

@(test)
test_pick_cancelled_returns_409_without_touching_cwd :: proc(t: ^testing.T) {
	dir := test_temp_dir("pick-cancel")
	defer os.remove_all(dir)

	app: App
	picker := Pick_Test_Picker{result = pick_cancelled()}
	pick_test_fixture(t, &app, dir, &picker)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	before, before_err := canonicalize_path(".", true)
	testing.expect_value(t, before_err.message, "")

	response := api_call(&app, .Post, "/api/cwd/pick")
	testing.expect_value(t, response.status, 409)
	testing.expect(t, strings.contains(api_response_text(&response), `"code":"cancelled"`))
	testing.expect_value(t, picker.calls, 1)

	// 取消不改变任何状态，并且占位必须释放（下一次还能再弹）。
	testing.expect_value(t, app_cwd(&app), dir)
	testing.expect_value(t, sync.atomic_load(&app.picker_busy), i32(0))

	after, after_err := canonicalize_path(".", true)
	testing.expect_value(t, after_err.message, "")
	testing.expect_value(t, after, before)
}

@(test)
test_pick_success_returns_canonical_cwd_without_switching_project :: proc(t: ^testing.T) {
	base := test_temp_dir("pick-ok")
	defer os.remove_all(base)

	selected := fmt.aprintf("%s/selected", base)
	os.make_directory_all(selected)
	expected, expected_err := canonicalize_path(selected, true)
	testing.expect_value(t, expected_err.message, "")

	original, original_err := canonicalize_path(".", true)
	testing.expect_value(t, original_err.message, "")
	defer os.chdir(original)

	app: App
	picker := Pick_Test_Picker{result = pick_ok(selected)}
	pick_test_fixture(t, &app, base, &picker)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)
	_ = runner_session_resume(&app, "ses_old", app_cwd(&app))

	response := api_call(&app, .Post, "/api/cwd/pick")
	testing.expect_value(t, response.status, 200)
	testing.expect(t, strings.contains(api_response_text(&response), expected))

	// 选择目录只返回路径；进程 cwd / 默认 project / 已有 session 全部保持不变。
	// project 身份属于单个 session，由前端接着 POST /api/session/new {cwd}。
	testing.expect_value(t, app_cwd(&app), base)
	project := app_project(&app)
	testing.expect_value(t, project.root, base)
	current, current_err := canonicalize_path(".", true)
	testing.expect_value(t, current_err.message, "")
	testing.expect_value(t, current, original)
	session := runner_session(&app)
	defer delete(session)
	testing.expect_value(t, session, "ses_old")

	cwd_response := api_call(&app, .Get, "/api/cwd")
	testing.expect_value(t, cwd_response.status, 200)
	stored_cwd, has_stored_cwd := api_json_field(t, api_response_text(&cwd_response), "cwd")
	testing.expect(t, has_stored_cwd)
	testing.expect_value(t, stored_cwd.(json.String), json.String(base))
	testing.expect_value(t, sync.atomic_load(&app.picker_busy), i32(0))
}

@(test)
test_pick_error_returns_500_with_manual_hint :: proc(t: ^testing.T) {
	dir := test_temp_dir("pick-error")
	defer os.remove_all(dir)

	app: App
	picker := Pick_Test_Picker{result = pick_error("COM initialization failed (0x80010106)")}
	pick_test_fixture(t, &app, dir, &picker)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	response := api_call(&app, .Post, "/api/cwd/pick")
	testing.expect_value(t, response.status, 500)
	body := api_response_text(&response)
	testing.expect(t, strings.contains(body, `"code":"picker_failed"`))
	testing.expect(t, strings.contains(body, "manually"))
	testing.expect_value(t, sync.atomic_load(&app.picker_busy), i32(0))
}

// Unix 的生产实现返回 Unsupported，handler 映射 501；Windows 上同一个映射用
// 假 picker 覆盖（真实 COM 实现会弹窗，不能进自动化测试）。
@(test)
test_pick_unsupported_returns_501 :: proc(t: ^testing.T) {
	dir := test_temp_dir("pick-unsupported")
	defer os.remove_all(dir)

	app: App
	picker := Pick_Test_Picker{result = pick_unsupported("not available on this platform")}
	pick_test_fixture(t, &app, dir, &picker)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	response := api_call(&app, .Post, "/api/cwd/pick")
	testing.expect_value(t, response.status, 501)
	testing.expect(t, strings.contains(api_response_text(&response), `"code":"not_implemented"`))
}

@(test)
test_pick_native_implementation_matches_platform :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		// Windows 真实实现只能在手工验证里跑（会阻塞等待用户点确认）。
	} else {
		result := native_pick_directory(nil)
		defer pick_result_destroy(&result)
		testing.expect_value(t, result.status, Pick_Status.Unsupported)
	}
}

// COM 绑定最容易错的是 vtable 槽位偏移：Show 必须在 IUnknown 三槽之后，
// SetOptions 是 IModalWindow 之后的第 6 个 IFileDialog 方法，GetResult 第 17 个。
@(test)
test_pick_windows_vtable_layout :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		slot := size_of(rawptr)
		testing.expect_value(t, offset_of(File_Dialog_Vtbl, Release), 2 * uintptr(slot))
		testing.expect_value(t, offset_of(File_Dialog_Vtbl, Show), 3 * uintptr(slot))
		testing.expect_value(t, offset_of(File_Dialog_Vtbl, SetOptions), 9 * uintptr(slot))
		testing.expect_value(t, offset_of(File_Dialog_Vtbl, GetResult), 20 * uintptr(slot))
		testing.expect_value(t, offset_of(Shell_Item_Vtbl, Release), 2 * uintptr(slot))
		testing.expect_value(t, offset_of(Shell_Item_Vtbl, GetDisplayName), 5 * uintptr(slot))
	}
}

// 并发重复调用：第一个请求卡在假对话框里，第二个必须立刻 409 picker_busy；
// 放开假对话框后第一个完成并更新 cwd。
Pick_Test_Call :: struct {
	app:      ^App,
	response: Http_Response,
}

pick_test_call_run :: proc(user: rawptr) {
	call := (^Pick_Test_Call)(user)
	context = runtime.default_context()
	call.response = api_call(call.app, .Post, "/api/cwd/pick")
}

@(test)
test_pick_concurrent_duplicate_returns_busy :: proc(t: ^testing.T) {
	base := test_temp_dir("pick-busy")
	defer os.remove_all(base)

	selected := fmt.aprintf("%s/selected", base)
	os.make_directory_all(selected)

	original, original_err := canonicalize_path(".", true)
	testing.expect_value(t, original_err.message, "")
	defer os.chdir(original)

	app: App
	picker := Pick_Test_Picker{result = pick_ok(selected), blocking = true}
	pick_test_fixture(t, &app, base, &picker)
	defer sse_hub_destroy(&app.hub)
	defer runner_shutdown(&app)

	call := Pick_Test_Call{app = &app}
	handle := thread.create_and_start_with_data(
		rawptr(&call),
		pick_test_call_run,
		name = "pick-call",
	)
	testing.expect(t, handle != nil, "cannot start first pick request")
	if handle == nil {
		return
	}
	defer sync.atomic_store(&picker.release, 1)

	start := time.tick_now()
	for sync.atomic_load(&picker.entered) == 0 && time.tick_since(start) < 5 * time.Second {
		time.sleep(time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&picker.entered) == 1, "picker never started")
	testing.expect_value(t, sync.atomic_load(&app.picker_busy), i32(1))

	busy := api_call(&app, .Post, "/api/cwd/pick")
	testing.expect_value(t, busy.status, 409)
	testing.expect(t, strings.contains(api_response_text(&busy), `"code":"picker_busy"`))
	testing.expect_value(t, picker.calls, 1)

	sync.atomic_store(&picker.release, 1)
	thread.join(handle)

	testing.expect_value(t, call.response.status, 200)
	testing.expect_value(t, app_cwd(&app), base)
	testing.expect_value(t, sync.atomic_load(&app.picker_busy), i32(0))
}
