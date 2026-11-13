package apweb

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"

// 在工作目录打开外部程序（docs/11-web.md「打开工作目录」）：
// 浏览器拿不到文件管理器和终端，只能发请求，由 ap-web 在本机拉起对应程序。
// 这些程序都是长驻 GUI 进程，handler 不能等它们退出，所以 spawn 成功后把
// 子进程交给独立线程 wait：既回收退出状态（Unix 的僵尸、Windows 的句柄），
// 又不占住 HTTP 连接线程。

Open_Target :: enum {
	Files, // 文件管理器
	Terminal, // 终端
}

// 启动器签名。ok=false 时 message 说明原因，直接进 JSON 错误体。
// App.open 为 nil 时用 open_workdir；测试注入假实现，避免真的弹窗。
Open_Fn :: #type proc(target: Open_Target, cwd: string, user: rawptr) -> (ok: bool, message: string)

// ---------------------------------------------------------------------------
// 子进程回收线程
// ---------------------------------------------------------------------------

Reap_Job :: struct {
	process: os.Process,
}

reap_job_run :: proc(user: rawptr) {
	job := (^Reap_Job)(user)
	context = runtime.default_context()
	_, _ = os.process_wait(job.process, -1)
	free(job, runtime.heap_allocator())
	free_all(context.temp_allocator)
}

// 启动后立即返回，进程退出由 reaper 线程处理。self_cleanup 让线程退出时
// 自己释放 Thread 结构，调用方不需要（也不能）再 join。
spawn_detached :: proc(command: []string, working_dir: string) -> (ok: bool, message: string) {
	desc := os.Process_Desc {
		working_dir = working_dir,
		command     = command,
	}
	process, err := os.process_start(desc)
	if err != nil {
		return false, fmt.tprintf("cannot start %s: %v", command[0], err)
	}

	job := new(Reap_Job, runtime.heap_allocator())
	job.process = process
	handle := thread.create_and_start_with_data(
		rawptr(job),
		reap_job_run,
		self_cleanup = true,
		name = "open-reaper",
	)
	if handle == nil {
		// 拉不起回收线程时进程仍在跑，只是退出状态要留到 ap-web 结束时才收；
		// 这比把「已启动」报成失败更有用。
		free(job, runtime.heap_allocator())
	}
	return true, ""
}

// Unix 的终端没有统一名字：依次尝试，第一个启动成功的就返回。
spawn_first :: proc(working_dir: string, commands: ..[]string) -> (ok: bool, message: string) {
	message = "no terminal emulator found"
	for command in commands {
		attempt_ok, attempt_message := spawn_detached(command, working_dir)
		if attempt_ok {
			return true, ""
		}
		message = attempt_message
	}
	return false, message
}

// ---------------------------------------------------------------------------
// 平台命令
// ---------------------------------------------------------------------------

// 客户端传来的 cwd 是 canonicalize 过的正斜杠路径；explorer 和 wt 只认
// Windows 分隔符（正斜杠会被 explorer 当成无效路径，退到「文档」）。
when ODIN_OS == .Windows {
	windows_path :: proc(path: string, allocator := context.temp_allocator) -> string {
		b := strings.builder_make(allocator)
		for r in path {
			strings.write_rune(&b, '\\' if r == '/' else r)
		}
		return strings.to_string(b)
	}
}

// 子进程的 working_dir 一律设为 cwd，所以不依赖程序自己解析目录参数；
// Windows 的 wt 需要显式 -d，explorer 直接把路径当参数。
open_workdir :: proc(
	target: Open_Target,
	cwd: string,
	user: rawptr,
) -> (ok: bool, message: string) {
	when ODIN_OS == .Windows {
		path := windows_path(cwd)
		switch target {
		case .Files:
			return spawn_detached({"explorer", path}, cwd)
		case .Terminal:
			return spawn_detached({"wt.exe", "-d", path}, cwd)
		}
	} else when ODIN_OS == .Darwin {
		switch target {
		case .Files:
			return spawn_detached({"open", cwd}, cwd)
		case .Terminal:
			return spawn_detached({"open", "-a", "Terminal", cwd}, cwd)
		}
	} else {
		switch target {
		case .Files:
			return spawn_detached({"xdg-open", cwd}, cwd)
		case .Terminal:
			return spawn_first(
				cwd,
				{"x-terminal-emulator"},
				{"gnome-terminal"},
				{"konsole"},
				{"xfce4-terminal"},
				{"kitty"},
				{"alacritty"},
				{"xterm"},
			)
		}
	}
	// when 已经覆盖所有目标平台；保留兜底返回让过程在语法上完整。
	return false, "unsupported platform"
}

// ---------------------------------------------------------------------------
// POST /api/cwd/reveal、POST /api/cwd/terminal
// ---------------------------------------------------------------------------

Api_Open_Body :: struct {
	cwd: string `json:"cwd"`,
}

api_cwd_reveal :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	api_cwd_open(user, request, response, .Files)
}

api_cwd_terminal :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	api_cwd_open(user, request, response, .Terminal)
}

// 只读语义：打开外部程序不改变 cwd/project，也不碰任何 session 运行态。
api_cwd_open :: proc(
	user: rawptr,
	request: ^Http_Request,
	response: ^Http_Response,
	target: Open_Target,
) {
	app := (^App)(user)
	body: Api_Open_Body
	if len(request.body) > 0 && !api_parse_json(request.body, &body) {
		api_error(response, 400, "invalid_json", "request body must be a JSON object")
		return
	}
	project, message := resolve_cwd_project(app, body.cwd)
	if len(message) > 0 {
		api_error(response, 400, "invalid_cwd", message)
		return
	}

	open := app.open
	if open == nil {
		open = open_workdir
	}
	ok, open_error := open(target, project.root, app.open_user)
	if !ok {
		api_error(response, 500, "open_failed", open_error)
		return
	}
	api_json(response, 200, Api_Cwd{cwd = project.root})
}
