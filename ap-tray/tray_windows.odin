#+build windows
package aptray

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

WINDOW_CLASS :: "ap-tray-window"
TRAY_UID :: 1
TRAY_CALLBACK :: win.WM_APP + 1

MENU_OPEN :: 1001
MENU_RESTART :: 1002
MENU_EXIT :: 1003

PROCESS_STILL_ACTIVE :: 259

TRAY_ICON_DATA :: #load("../tray.ico", string)

Web_Process :: struct {
	handle: win.HANDLE,
	pid:    u32, // 启动时记录，便于诊断；结束进程用 handle
}

App :: struct {
	hwnd:            win.HWND,
	icon:            win.HICON,
	web:             Web_Process,
	taskbar_created: win.UINT,
}

run :: proc() -> int {
	setup_dpi_awareness()
	app := new(App)
	defer free(app)

	app.icon = load_icon()
	if app.icon == nil {
		show_error("加载 tray.ico 失败")
		return 1
	}
	defer {
		if app.icon != nil {
			_ = win.DestroyIcon(app.icon)
		}
	}

	hinstance := win.HINSTANCE(win.GetModuleHandleW(nil))
	class := win.WNDCLASSEXW {
		cbSize        = u32(size_of(win.WNDCLASSEXW)),
		lpfnWndProc   = wnd_proc,
		hInstance     = hinstance,
		hIcon         = app.icon,
		lpszClassName = win.L(WINDOW_CLASS),
		hIconSm       = app.icon,
	}
	if win.RegisterClassExW(&class) == 0 {
		show_error("注册托盘窗口类失败")
		return 1
	}
	defer win.UnregisterClassW(win.L(WINDOW_CLASS), hinstance)

	hwnd := win.CreateWindowExW(
		0,
		win.L(WINDOW_CLASS),
		win.L("ap-tray"),
		0,
		0, 0, 0, 0,
		nil,
		nil,
		hinstance,
		nil,
	)
	if hwnd == nil {
		show_error("创建托盘窗口失败")
		return 1
	}
	app.hwnd = hwnd
	win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, win.LONG_PTR(uintptr(app)))
	defer {
		_ = win.DestroyWindow(hwnd)
		app.hwnd = nil
	}

	app.taskbar_created = win.RegisterWindowMessageW(win.L("TaskbarCreated"))
	if !add_tray(app) {
		show_error("添加托盘图标失败")
		return 1
	}

	// 启动后立即拉起 ap-web。启动失败时托盘仍保留，用户可以重启或先释放端口再试。
	_ = start_web(app)

	msg: win.MSG
	for {
		result := win.GetMessageW(&msg, nil, 0, 0)
		if result == 0 || result == -1 {
			break
		}
		_ = win.TranslateMessage(&msg)
		_ = win.DispatchMessageW(&msg)
	}
	stop_web(app)
	return 0
}

wnd_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	context = runtime.default_context()
	app := cast(^App)(uintptr(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA)))
	if app != nil {
		if app.taskbar_created != 0 && msg == app.taskbar_created {
			refresh_icon(app)
			_ = add_tray(app)
			return 0
		}
		switch msg {
		case TRAY_CALLBACK:
			switch u32(lparam) {
			case win.WM_LBUTTONDBLCLK:
				open_web()
			case win.WM_RBUTTONUP:
				show_menu(app)
			}
			return 0
		case win.WM_DPICHANGED, win.WM_DISPLAYCHANGE, win.WM_SETTINGCHANGE:
			refresh_icon(app)
			return 0
		case win.WM_CLOSE:
			stop_web(app)
			_ = win.DestroyWindow(hwnd)
			return 0
		case win.WM_DESTROY:
			remove_tray(app)
			win.PostQuitMessage(0)
			return 0
		}
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

add_tray :: proc(app: ^App) -> bool {
	data := tray_data(app, app.icon, win.NIF_MESSAGE | win.NIF_ICON | win.NIF_TIP)
	data.uCallbackMessage = TRAY_CALLBACK
	_ = win.utf8_to_utf16_buf(data.szTip[:], TRAY_TIP)
	return win.Shell_NotifyIconW(win.NIM_ADD, &data) != win.FALSE
}

update_tray_icon :: proc(app: ^App, icon: win.HICON) -> bool {
	data := tray_data(app, icon, win.NIF_ICON)
	return win.Shell_NotifyIconW(win.NIM_MODIFY, &data) != win.FALSE
}

tray_data :: proc(app: ^App, icon: win.HICON, flags: win.UINT) -> win.NOTIFYICONDATAW {
	return {
		cbSize = u32(size_of(win.NOTIFYICONDATAW)),
		hWnd   = app.hwnd,
		uID    = TRAY_UID,
		uFlags = flags,
		hIcon  = icon,
	}
}

refresh_icon :: proc(app: ^App) {
	icon := load_icon()
	if icon == nil {
		return
	}
	if update_tray_icon(app, icon) {
		old := app.icon
		app.icon = icon
		if old != nil {
			_ = win.DestroyIcon(old)
		}
	} else {
		_ = win.DestroyIcon(icon)
	}
}

remove_tray :: proc(app: ^App) {
	data := win.NOTIFYICONDATAW {
		cbSize = u32(size_of(win.NOTIFYICONDATAW)),
		hWnd   = app.hwnd,
		uID    = TRAY_UID,
	}
	_ = win.Shell_NotifyIconW(win.NIM_DELETE, &data)
}

show_menu :: proc(app: ^App) {
	menu := win.CreatePopupMenu()
	if menu == nil {
		return
	}
	defer win.DestroyMenu(menu)

	_ = win.AppendMenuW(menu, win.MF_STRING, MENU_OPEN, win.L("打开 AP"))
	_ = win.AppendMenuW(menu, win.MF_STRING, MENU_RESTART, win.L("重启 ap-web"))
	_ = win.AppendMenuW(menu, win.MF_SEPARATOR, 0, nil)
	_ = win.AppendMenuW(menu, win.MF_STRING, MENU_EXIT, win.L("退出"))

	point: win.POINT
	if win.GetCursorPos(&point) == win.FALSE {
		return
	}
	win.SetForegroundWindow(app.hwnd)
	command := win.TrackPopupMenu(
		menu,
		win.TPM_RIGHTBUTTON | win.TPM_RETURNCMD | win.TPM_NONOTIFY,
		point.x,
		point.y,
		0,
		app.hwnd,
		nil,
	)
	_ = win.PostMessageW(app.hwnd, win.WM_NULL, 0, 0)

	switch command {
	case MENU_OPEN:
		open_web()
	case MENU_RESTART:
		stop_web(app)
		_ = start_web(app)
	case MENU_EXIT:
		stop_web(app)
		_ = win.DestroyWindow(app.hwnd)
	}
}

open_web :: proc() {
	result := win.ShellExecuteW(
		nil,
		win.L("open"),
		win.utf8_to_wstring(WEB_URL),
		nil,
		nil,
		win.SW_SHOWNORMAL,
	)
	if uintptr(result) <= 32 {
		show_error(fmt.tprintf("打开 %s 失败", WEB_URL))
	}
}

start_web :: proc(app: ^App) -> bool {
	dir, ok := executable_dir()
	if !ok {
		show_error("无法定位 ap-tray.exe 所在目录")
		return false
	}
	path := web_exe_path(dir)
	if !os.exists(path) {
		show_error(fmt.tprintf("找不到 %s。请确认 ap-web.exe 与 ap-tray.exe 在同一目录。", path))
		return false
	}

	startup := win.STARTUPINFOW {
		cb = u32(size_of(win.STARTUPINFOW)),
	}
	info: win.PROCESS_INFORMATION
	ok = bool(win.CreateProcessW(
		win.utf8_to_wstring(path),
		win.utf8_to_wstring(web_command_line(path)),
		nil,
		nil,
		win.FALSE,
		win.CREATE_NO_WINDOW,
		nil,
		nil,
		&startup,
		&info,
	))
	if !ok {
		show_error(fmt.tprintf("启动 %s 失败（错误码 %d）", path, win.GetLastError()))
		return false
	}

	_ = win.CloseHandle(info.hThread)
	app.web = Web_Process {
		handle = info.hProcess,
		pid    = u32(info.dwProcessId),
	}
	return true
}

stop_web :: proc(app: ^App) {
	if app.web.handle == nil {
		return
	}
	code: win.DWORD
	if win.GetExitCodeProcess(app.web.handle, &code) && code == PROCESS_STILL_ACTIVE {
		_ = win.TerminateProcess(app.web.handle, 1)
	}
	_ = win.WaitForSingleObject(app.web.handle, 5000)
	_ = win.CloseHandle(app.web.handle)
	app.web = {}
}

Dpi_Awareness_Context_Proc :: #type proc "system" (value: win.DPI_AWARENESS_CONTEXT) -> win.BOOL

// 托盘菜单和图标由本进程渲染；不是 DPI aware 时，Windows 会把整个菜单位图拉伸。
// 优先 Per-Monitor V2，旧系统或策略禁用时退回 system DPI aware。
// SetProcessDpiAwarenessContext 只有 Win10 1703+ 才有，用 GetProcAddress 动态取，
// 避免静态导入在旧系统上导致进程无法启动。
setup_dpi_awareness :: proc() {
	user32_dll := win.utf8_to_wstring("user32.dll", context.temp_allocator)
	module := win.GetModuleHandleW(user32_dll)
	if module != nil {
		if address := win.GetProcAddress(module, "SetProcessDpiAwarenessContext"); address != nil {
			set_context := cast(Dpi_Awareness_Context_Proc)address
			if set_context(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) {
				return
			}
		}
	}
	_ = win.SetProcessDPIAware()
}

// tray.ico 编译期内嵌。ICO 目录里的图片可能是 PNG 或 DIB；
// CreateIconFromResourceEx 两种都支持，不需要运行目录里另带图标文件。
load_icon :: proc() -> win.HICON {
	return icon_from_ico(TRAY_ICON_DATA)
}

icon_from_ico :: proc(data: string) -> win.HICON {
	if len(data) < 6 + 16 {
		return nil
	}
	reserved := read_u16_le(data, 0)
	kind := read_u16_le(data, 2)
	count := int(read_u16_le(data, 4))
	if reserved != 0 || kind != 1 || count <= 0 {
		return nil
	}

	best_area := 0
	best_offset := -1
	best_bytes: u32
	for i in 0 ..< count {
		entry := 6 + i * 16
		if entry + 16 > len(data) {
			break
		}
		width := int(data[entry])
		height := int(data[entry + 1])
		if width == 0 {
			width = 256
		}
		if height == 0 {
			height = 256
		}
		area := width * height
		if area <= best_area {
			continue
		}
		bytes := read_u32_le(data, entry + 8)
		offset := read_u32_le(data, entry + 12)
		if int(offset) + int(bytes) > len(data) {
			continue
		}
		best_area = area
		best_offset = int(offset)
		best_bytes = bytes
	}
	if best_offset < 0 {
		return nil
	}

	bits := cast(win.PBYTE)(uintptr(raw_data(data)) + uintptr(best_offset))
	return win.CreateIconFromResourceEx(
		bits,
		win.DWORD(best_bytes),
		win.TRUE,
		0x00030000,
		0,
		0,
		win.LR_DEFAULTCOLOR,
	)
}

read_u16_le :: proc(data: string, offset: int) -> u16 {
	return u16(data[offset]) | u16(data[offset + 1]) << 8
}

read_u32_le :: proc(data: string, offset: int) -> u32 {
	return u32(data[offset]) |
		u32(data[offset + 1]) << 8 |
		u32(data[offset + 2]) << 16 |
		u32(data[offset + 3]) << 24
}

executable_dir :: proc() -> (string, bool) {
	buffer: [32768]u16
	length := win.GetModuleFileNameW(nil, &buffer[0], u32(len(buffer)))
	if length == 0 || length >= u32(len(buffer)) {
		return "", false
	}
	path, err := win.wstring_to_utf8(win.wstring(&buffer[0]), int(length), context.temp_allocator)
	if err != nil || len(path) == 0 {
		return "", false
	}
	slash := strings.last_index_byte(path, '\\')
	if slash <= 0 {
		return "", false
	}
	return path[:slash], true
}

show_error :: proc(message: string) {
	win.MessageBoxW(
		nil,
		win.utf8_to_wstring(message),
		win.L("ap-tray"),
		win.MB_OK | win.MB_ICONERROR | win.MB_SETFOREGROUND,
	)
}
