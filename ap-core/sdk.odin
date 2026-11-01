package apcore

import "engine"
import "platform"
import "protocol"

// SDK 门面。
//
// 只做「解析配置 → 定位 project → 打开会话 → 跑一轮 → 关闭」这条链路，
// 不读 argv、不写 stdout/stderr、不装信号、不决定退出码。宿主侧（当前的
// ap-cli）负责那些事，并且只 import 本包与 platform 的路径/IO 原语，
// 不直接 import engine。依赖方向：apcli → apcore → engine。

VERSION :: protocol.VERSION

// ---- 对外类型别名：宿主不必 import engine ----

Error :: engine.Error
Error_Kind :: engine.Error_Kind
Log_Level :: engine.Log_Level
Session :: engine.Session
Session_Kind :: engine.Session_Kind
Session_Request :: engine.Session_Request
Session_Info :: engine.Session_Info
Close_Options :: engine.Close_Options
Turn_Result :: engine.Turn_Result
Emitter :: engine.Emitter
Progress_Style :: engine.Progress_Style
Project :: platform.Project
Cancel_Token :: platform.Cancel_Token
Settings :: engine.Settings

is_ok :: proc(err: Error) -> bool {
	return engine.is_ok(err)
}

ok_error :: proc() -> Error {
	return engine.ok_error()
}

errorf :: proc(kind: Error_Kind, format: string, args: ..any) -> Error {
	return engine.make_error(kind, format, ..args)
}

// 默认设置。配置文件（settings.json）由宿主读取后覆盖这些字段再传入。
settings_defaults :: proc() -> Settings {
	return engine.settings_defaults()
}

// engine.ALL_TOOL_NAMES 是运行期数组，返回副本避免宿主改写全局工具集。
all_tool_names :: proc() -> [5]string {
	return engine.ALL_TOOL_NAMES
}

// 运行环境。所有字段由宿主提供：SDK 不读 argv、不读环境变量、不打开
// settings.json，也不自己找 bash。`settings` 必须已经由宿主解析并校验。
Config :: struct {
	// 已解析的配置目录（通常来自 --config-dir / AP_CONFIG / ~/.ap）。
	config_dir:      string,
	// 空 = 当前目录；相对路径按进程启动目录解析。
	cwd:             string,
	// 用户主目录；宿主解析。空 = 不注入全局 AGENTS.md。
	home_dir:        string,
	// bash 可执行文件；由宿主定位（如 platform.find_bash）。
	bash_path:       string,
	// task 工具拉起子代理时用的 ap 可执行文件。空 = 当前可执行文件，
	// 方便 ap-cli 这类「自己就是 ap」的宿主；内嵌到别的宿主时必须显式给，
	// 否则子代理会拿到宿主自己的 argv。
	child_agent_bin: string,
	settings:        Settings,
}

// env_open 解析出的运行环境。settings 按值持有，session_request 取它的地址。
Env :: struct {
	config_dir:      string,
	cwd:             string,
	home_dir:        string,
	project:         Project,
	bash_path:       string,
	child_agent_bin: string,
	settings:        Settings,
}

// 一次会话的选项；对应 Session_Request 里所有“来自调用方”的字段，
// 运行环境相关的字段（project/settings/config_dir/cwd/self_exe/bash_path）
// 由 Env 填充。
Session_Options :: struct {
	kind:                 Session_Kind,
	source_session_id:    string,
	model:                Maybe(string),
	agent:                Maybe(string),
	max_steps:            Maybe(int),
	max_tokens:           Maybe(int),
	append_system_prompt: Maybe(string),
	base_system_prompt:   Maybe(string),
	no_agents_md:         bool,
	no_skills:            bool,
	tools_set:            bool,
	tools:                []string,
	agent_depth:          Maybe(int),
	parent_session_id:    Maybe(string),
	parent_tool_call_id:  Maybe(string),
}

// 空路径按当前目录处理；canonicalize 同时解析符号链接与 Windows 大小写。
resolve_cwd :: proc(input: string) -> (string, platform.Error) {
	dir := input
	if len(dir) == 0 {
		dir = "."
	}
	return platform.canonicalize_path(dir, true)
}

env_open :: proc(cfg: Config) -> (Env, Error) {
	env := Env {
		config_dir      = cfg.config_dir,
		home_dir        = cfg.home_dir,
		bash_path       = cfg.bash_path,
		child_agent_bin = cfg.child_agent_bin,
		settings        = cfg.settings,
	}

	// 只准备运行时需要的目录与 project 元数据；配置文件不在这里读。
	if werr := platform.ensure_writable_dir(cfg.config_dir); !platform.is_ok(werr) {
		return env, engine.from_platform(werr)
	}

	cwd, cwderr := resolve_cwd(cfg.cwd)
	if !platform.is_ok(cwderr) {
		return env, engine.from_platform(cwderr)
	}
	env.cwd = cwd

	project, perr := platform.open_project(cfg.config_dir, cwd)
	if !platform.is_ok(perr) {
		return env, engine.from_platform(perr)
	}
	env.project = project

	if len(env.child_agent_bin) == 0 {
		env.child_agent_bin = platform.resolve_self_exe()
	}
	return env, engine.ok_error()
}

// 把 Env + Session_Options 合成 engine 的请求结构；导出用于测试与
// 需要直接读 Session_Request 的调用方。
//
// settings 是 Env 内部字段的地址：Session 存活期间 Env 不得移动或释放。
session_request :: proc(env: ^Env, opts: Session_Options) -> Session_Request {
	return Session_Request {
		kind = opts.kind,
		project = env.project,
		settings = &env.settings,
		config_dir = env.config_dir,
		cwd = env.cwd,
		home_dir = env.home_dir,
		self_exe = env.child_agent_bin,
		bash_path = env.bash_path,
		source_session_id = opts.source_session_id,
		model = opts.model,
		agent = opts.agent,
		max_steps = opts.max_steps,
		max_tokens = opts.max_tokens,
		append_system_prompt = opts.append_system_prompt,
		base_system_prompt = opts.base_system_prompt,
		no_agents_md = opts.no_agents_md,
		no_skills = opts.no_skills,
		tools_set = opts.tools_set,
		tools = opts.tools,
		agent_depth = opts.agent_depth,
		parent_session_id = opts.parent_session_id,
		parent_tool_call_id = opts.parent_tool_call_id,
	}
}

preview_prompt :: proc(env: ^Env, opts: Session_Options) -> (Session_Info, Error) {
	return engine.preview_prompt(session_request(env, opts))
}

session_open :: proc(env: ^Env, opts: Session_Options) -> (Session, Session_Info, Error) {
	return engine.session_open(session_request(env, opts))
}

turn_run :: proc(
	s: ^Session,
	prompt: string,
	cancel: ^Cancel_Token,
	sink: Emitter,
) -> (Turn_Result, Error) {
	return engine.turn_run(s, prompt, cancel, sink)
}

session_close :: proc(s: ^Session, opts: Close_Options) -> (string, Error) {
	return engine.session_close(s, opts)
}

// ---- 日志 ----

log_set_level :: proc(level: Log_Level) {
	engine.log_set_level(level)
}

log_error :: proc(format: string, args: ..any) {
	engine.log_error(format, ..args)
}

log_warn :: proc(format: string, args: ..any) {
	engine.log_warn(format, ..args)
}

// ---- 工具名 ----

select_tools :: proc(names: []string) -> []string {
	return engine.select_tools(names)
}

tool_name_known :: proc(name: string) -> bool {
	return engine.tool_name_known(name)
}

// ---- 只读查询：算在 SDK，打印留给宿主 ----

// 列出当前目录可见技能。cwd 为空时按当前目录处理。
list_skills_text :: proc(cwd: string) -> (string, Error) {
	dir, cerr := resolve_cwd(cwd)
	if !platform.is_ok(cerr) {
		return "", engine.from_platform(cerr)
	}
	return engine.skills_brief(engine.discover_skills(dir)), engine.ok_error()
}

// 列出 agent 定义 + 工具覆盖后的声明工具集。不读 settings.json、
// 不需要 API key、不创建 session。
list_tools_text :: proc(
	config_dir: string,
	agent: Maybe(string),
	tools_set: bool,
	tools: []string,
) -> (string, Error) {
	agent_name := "general"
	if value, ok := agent.?; ok {
		agent_name = value
	}
	def, aerr := engine.load_agent(config_dir, agent_name)
	if !engine.is_ok(aerr) {
		return "", aerr
	}
	if tools_set {
		if terr := engine.apply_tool_override(&def, tools); !engine.is_ok(terr) {
			return "", terr
		}
	}
	return engine.tools_brief(def.tools), engine.ok_error()
}
