package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:unicode/utf16"

// 工作目录选择（docs/web.md「工作目录选择」）：
// 浏览器拿不到真实绝对路径，所以由 ap-web 侧弹原生对话框。Windows 用
// IFileDialog（COM/STA），Unix 没有统一 API，phase 1 返回 501。
//
// handler 只依赖可注入的 Pick_Fn：测试用假 picker 覆盖 busy/取消/成功/失败，
// 生产实现（native_pick_directory）负责真正的 COM 调用。COM 对话框会阻塞到
// 用户关闭，因此始终在专用 STA 线程里跑，HTTP 连接线程只等待结果。

Pick_Status :: enum {
	Ok,
	Cancelled,
	Unsupported,
	Error,
}

// path/message 由 pickdir 自己拥有（heap），handler 用完调 pick_result_destroy。
Pick_Result :: struct {
	status:  Pick_Status,
	path:    string,
	message: string,
}

Pick_Fn :: #type proc(user: rawptr) -> Pick_Result

pick_ok :: proc(path: string) -> Pick_Result {
	return {status = .Ok, path = strings.clone(path, runtime.heap_allocator())}
}

pick_cancelled :: proc() -> Pick_Result {
	return {status = .Cancelled}
}

pick_unsupported :: proc(message: string) -> Pick_Result {
	return {status = .Unsupported, message = strings.clone(message, runtime.heap_allocator())}
}

pick_error :: proc(format: string, args: ..any) -> Pick_Result {
	message := fmt.tprintf(format, ..args)
	return {status = .Error, message = strings.clone(message, runtime.heap_allocator())}
}

pick_result_destroy :: proc(result: ^Pick_Result) {
	delete(result.path, runtime.heap_allocator())
	delete(result.message, runtime.heap_allocator())
	result^ = {}
}

// ---------------------------------------------------------------------------
// 对话框线程
// ---------------------------------------------------------------------------

Pick_Job :: struct {
	pick:   Pick_Fn,
	user:   rawptr,
	result: Pick_Result,
}

pick_job_run :: proc(user: rawptr) {
	job := (^Pick_Job)(user)
	context = runtime.default_context()
	job.result = job.pick(job.user)
	free_all(context.temp_allocator)
}

// 弹窗放在独立线程：Show() 会阻塞到用户关闭，不能占住 HTTP 连接线程。
// 这里 join 等待结果，但被阻塞的是调用线程（连接线程）而不是 accept 循环。
pick_directory_async :: proc(pick: Pick_Fn, pick_user: rawptr) -> Pick_Result {
	job := Pick_Job{pick = pick, user = pick_user}
	handle := thread.create_and_start_with_data(rawptr(&job), pick_job_run, name = "dir-picker")
	if handle == nil {
		return pick_error("cannot start the directory picker thread")
	}
	thread.join(handle)
	return job.result
}

// ---------------------------------------------------------------------------
// cwd / project 状态
// ---------------------------------------------------------------------------

// 目录选择对话框的并发占位：同一时刻只允许一个模态对话框。
picker_begin :: proc(app: ^App) -> bool {
	_, acquired := sync.atomic_compare_exchange_strong(&app.picker_busy, i32(0), i32(1))
	return acquired
}

picker_end :: proc(app: ^App) {
	sync.atomic_store(&app.picker_busy, i32(0))
}

// cwd 与 project 在 pick 成功后由连接线程替换，其它 handler（config/sessions/
// history/turn 启动）可能并发读取，所以统一走锁。旧字符串不回收：变更极少，
// 且测试 fixture 里的 project 字符串可能指向调用方内存，误释放会踩雷。
app_cwd :: proc(app: ^App) -> string {
	sync.mutex_lock(&app.cwd_mu)
	defer sync.mutex_unlock(&app.cwd_mu)
	return app.cwd
}

app_project :: proc(app: ^App) -> Project {
	sync.mutex_lock(&app.cwd_mu)
	defer sync.mutex_unlock(&app.cwd_mu)
	return app.project
}

// ---------------------------------------------------------------------------
// POST /api/cwd/pick
// ---------------------------------------------------------------------------

// 只负责返回用户选择的目录，不改变进程状态：目录现在属于单个 session，
// 前端选完后会切到该 project / 新建 slot。因此其它 project 的 turn 在跑时
// 也可以继续浏览新目录，不再有全局 cwd 的互斥。
api_cwd_pick :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	app := (^App)(user)
	if !picker_begin(app) {
		api_error(response, 409, "picker_busy", "a directory picker is already open")
		return
	}
	defer picker_end(app)

	pick := app.pick
	if pick == nil {
		pick = native_pick_directory
	}
	result := pick_directory_async(pick, app.pick_user)
	defer pick_result_destroy(&result)

	switch result.status {
	case .Ok:
		canonical, canonical_err := canonicalize_path(result.path, true)
		if !is_ok(canonical_err) {
			api_error(response, 500, "cwd_failed", canonical_err.message)
			return
		}
		if !os.is_dir(canonical) {
			api_error(
				response,
				500,
				"cwd_failed",
				fmt.tprintf("selected path is not a directory: %s", canonical),
			)
			return
		}
		api_json(response, 200, Api_Cwd{cwd = canonical})
	case .Cancelled:
		// 前端静默忽略：用户主动关掉对话框不是错误。
		api_error(response, 409, "cancelled", "directory selection was cancelled")
	case .Unsupported:
		api_error(response, 501, "not_implemented", result.message)
	case .Error:
		api_error(
			response,
			500,
			"picker_failed",
			fmt.tprintf("%s (you can enter the path manually)", result.message),
		)
	}
}

// ---------------------------------------------------------------------------
// 平台实现
// ---------------------------------------------------------------------------

// Win32 的 GetPath 返回 CoTaskMemAlloc 的 UTF-16 NUL 结尾字符串；转成拥有
// 所有权的 UTF-8。放在 when 外面只为让 import 在所有平台都被使用（函数本身
// 仅 Windows 分支调用）。
utf16_to_utf8 :: proc(wide: [^]u16) -> string {
	if wide == nil {
		return ""
	}
	length := 0
	for wide[length] != 0 {
		length += 1
	}
	if length == 0 {
		return ""
	}
	// 一个 UTF-16 code unit 最多产生 3 字节 UTF-8。
	scratch := make([]byte, length * 3, runtime.heap_allocator())
	defer delete(scratch, runtime.heap_allocator())
	written := utf16.decode_to_utf8(scratch, wide[:length])
	return strings.clone(string(scratch[:written]), runtime.heap_allocator())
}

when ODIN_OS == .Windows {
	HResult :: distinct i32

	// Windows SDK 的 GUID 布局：DWORD/WORD/WORD/BYTE[8]。
	Guid :: struct {
		data1: u32,
		data2: u16,
		data3: u16,
		data4: [8]u8,
	}

	COINIT_APARTMENTTHREADED :: 0x2
	CLSCTX_INPROC_SERVER     :: 0x1
	FOS_PICKFOLDERS          :: 0x20
	FOS_FORCEFILESYSTEM      :: 0x40
	SIGDN_FILESYSPATH        :: 0x80058000
	// HRESULT_FROM_WIN32(ERROR_CANCELLED) = 0x800704C7
	HRESULT_CANCELLED :: HResult(-2147023673)

	// FileOpenDialog 与 IFileDialog 的官方 CLSID/IID（shobjidl.h）。
	CLSID_FILE_OPEN_DIALOG: Guid = {
		0xDC1C5A9C,
		0xE88A,
		0x4DDE,
		{0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7},
	}
	IID_IFILE_DIALOG: Guid = {
		0x42F85136,
		0xDB7E,
		0x439C,
		{0x85, 0xF1, 0xE4, 0x07, 0x5D, 0x13, 0x5F, 0xC8},
	}

	foreign import ole32 "system:Ole32.lib"

	@(default_calling_convention="system")
	foreign ole32 {
		CoInitializeEx :: proc(reserved: rawptr, coinit: u32) -> HResult ---
		CoCreateInstance :: proc(
			clsid: ^Guid,
			outer: rawptr,
			cls_context: u32,
			iid: ^Guid,
			out: ^rawptr,
		) -> HResult ---
		CoTaskMemFree :: proc(memory: rawptr) ---
		CoUninitialize :: proc() ---
	}

	// IFileDialog 的 vtable 顺序必须与 shobjidl.h 完全一致：
	// IUnknown(QueryInterface/AddRef/Release) → IModalWindow::Show →
	// IFileDialog(SetFileTypes/SetFileTypeIndex/GetFileTypeIndex/Advise/Unadvise/
	// SetOptions/GetOptions/SetDefaultFolder/SetFolder/GetFolder/
	// GetCurrentSelection/SetFileName/GetFileName/SetTitle/SetOkButtonLabel/
	// SetFileNameLabel/GetResult/AddPlace/SetDefaultExtension/Close/
	// SetClientGuid/ClearClientData/SetFilter)。
	// 不用的槽位用 rawptr 占位（与函数指针同宽），保证偏移不错位。
	File_Dialog_Vtbl :: struct {
		QueryInterface:      rawptr,
		AddRef:              rawptr,
		Release:             proc "system" (this: ^File_Dialog) -> u32,
		Show:                proc "system" (this: ^File_Dialog, owner: rawptr) -> HResult,
		SetFileTypes:        rawptr,
		SetFileTypeIndex:    rawptr,
		GetFileTypeIndex:    rawptr,
		Advise:              rawptr,
		Unadvise:            rawptr,
		SetOptions:          proc "system" (this: ^File_Dialog, options: u32) -> HResult,
		GetOptions:          rawptr,
		SetDefaultFolder:    rawptr,
		SetFolder:           rawptr,
		GetFolder:           rawptr,
		GetCurrentSelection: rawptr,
		SetFileName:         rawptr,
		GetFileName:         rawptr,
		SetTitle:            rawptr,
		SetOkButtonLabel:    rawptr,
		SetFileNameLabel:    rawptr,
		GetResult:           proc "system" (this: ^File_Dialog, item: ^rawptr) -> HResult,
		AddPlace:            rawptr,
		SetDefaultExtension: rawptr,
		Close:               rawptr,
		SetClientGuid:       rawptr,
		ClearClientData:     rawptr,
		SetFilter:           rawptr,
	}

	File_Dialog :: struct {
		vtbl: ^File_Dialog_Vtbl,
	}

	// IShellItem：IUnknown(3) → BindToHandler/GetParent/GetDisplayName/
	// GetAttributes/Compare。
	Shell_Item_Vtbl :: struct {
		QueryInterface: rawptr,
		AddRef:         rawptr,
		Release:        proc "system" (this: ^Shell_Item) -> u32,
		BindToHandler:  rawptr,
		GetParent:      rawptr,
		GetDisplayName: proc "system" (this: ^Shell_Item, sigdn: u32, name: ^rawptr) -> HResult,
		GetAttributes:  rawptr,
		Compare:        rawptr,
	}

	Shell_Item :: struct {
		vtbl: ^Shell_Item_Vtbl,
	}

	hresult_failed :: proc(hr: HResult) -> bool {
		return i32(hr) < 0
	}

	// 必须在 STA 线程上调用（pick_directory_async 已保证）；Show(NULL) 阻塞到
	// 用户确认或关闭。
	native_pick_directory :: proc(user: rawptr) -> Pick_Result {
		init_result := CoInitializeEx(nil, COINIT_APARTMENTTHREADED)
		if hresult_failed(init_result) {
			return pick_error("COM initialization failed (0x%08x)", u32(init_result))
		}
		defer CoUninitialize()

		dialog_raw: rawptr
		create_result := CoCreateInstance(
			&CLSID_FILE_OPEN_DIALOG,
			nil,
			CLSCTX_INPROC_SERVER,
			&IID_IFILE_DIALOG,
			&dialog_raw,
		)
		if hresult_failed(create_result) || dialog_raw == nil {
			return pick_error("cannot create the folder dialog (0x%08x)", u32(create_result))
		}
		dialog := (^File_Dialog)(dialog_raw)
		defer dialog.vtbl.Release(dialog)

		options := u32(FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM)
		if set_result := dialog.vtbl.SetOptions(dialog, options); hresult_failed(set_result) {
			return pick_error("cannot configure the folder dialog (0x%08x)", u32(set_result))
		}

		show_result := dialog.vtbl.Show(dialog, nil)
		if show_result == HRESULT_CANCELLED {
			return pick_cancelled()
		}
		if hresult_failed(show_result) {
			return pick_error("cannot show the folder dialog (0x%08x)", u32(show_result))
		}

		item_raw: rawptr
		get_result := dialog.vtbl.GetResult(dialog, &item_raw)
		if hresult_failed(get_result) || item_raw == nil {
			return pick_error("the folder dialog returned no selection (0x%08x)", u32(get_result))
		}
		item := (^Shell_Item)(item_raw)
		defer item.vtbl.Release(item)

		name_raw: rawptr
		display_result := item.vtbl.GetDisplayName(item, SIGDN_FILESYSPATH, &name_raw)
		if hresult_failed(display_result) || name_raw == nil {
			return pick_error(
				"cannot read the selected folder path (0x%08x)",
				u32(display_result),
			)
		}
		defer CoTaskMemFree(name_raw)

		path := utf16_to_utf8(([^]u16)(name_raw))
		if len(path) == 0 {
			return pick_error("the selected folder path is empty")
		}
		return {status = .Ok, path = path}
	}
} else {
	native_pick_directory :: proc(user: rawptr) -> Pick_Result {
		return pick_unsupported(
			"native directory picker is not available on this platform; enter the path manually",
		)
	}
}
