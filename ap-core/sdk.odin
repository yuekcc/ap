package apcore

import "engine"
import "platform"
import "protocol"
import "tool"

// SDK 门面。
//
// 只做「接收已解析配置 → 定位 project → 打开会话 → 跑一轮 → 关闭」这条链路，
// 不读 argv、不写 stdout/stderr、不装信号、不决定退出码、不解析 agent 文件、
// 不扫描技能目录、不实现具体工具。宿主侧（当前的 ap-cli）负责那些事，
// 并且只 import 本包与 platform/protocol 原语，不直接 import engine。
// 依赖方向：apcli → apcore → engine / tool。

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
Progress_Kind :: tool.Progress_Kind
Project :: platform.Project
Cancel_Token :: platform.Cancel_Token
Settings :: engine.Settings
Tool :: tool.Tool
Tool_Context :: tool.Tool_Context
Tool_Result :: tool.Tool_Result
Tool_Def :: tool.Tool_Def
Registry :: tool.Registry

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

// 工具注册辅助：把 platform 错误提升为 SDK Error。
registry_init :: proc(tools: []Tool) -> (Registry, Error) {
	registry, err := tool.registry_init(tools)
	return registry, engine.from_platform(err)
}

// 运行环境。所有字段由宿主提供：SDK 不读 argv、不读环境变量、不打开
// settings.json，也不自己找 bash 或子代理可执行文件。
Config :: struct {
	// 已解析的配置目录（通常来自 --config-dir / AP_CONFIG / ~/.ap）。
	config_dir: string,
	// 空 = 当前目录；相对路径按进程启动目录解析。
	cwd:        string,
	// 已解析的设置，只含 SDK 机制字段。
	settings:   Settings,
	// 工具契约；具体实现由应用层提供。
	tools:      []Tool,
}

// env_open 解析出的运行环境。settings 按值持有，session_request 取它的地址。
Env :: struct {
	config_dir: string,
	cwd:        string,
	project:    Project,
	settings:   Settings,
	tools:      Registry,
}

// 一次会话的选项；全部是已解析值。
Session_Options :: struct {
	kind:              Session_Kind,
	source_session_id: string,

	// prompt / tools / agent_name / model 只在新 session 生效；恢复 / fork 使用冻结值。
	// max_steps / max_tokens 不在 session_start 中冻结，恢复时仍取本次设置。
	agent_name:          string, // 仅作标签，不触发文件读取
	model:               string, // 空 = 用 Settings.model
	max_steps:           int,    // 0 = 用 Settings.max_steps
	max_tokens:          int,    // 0 = 用 Settings.max_tokens
	agent_depth:         int,
	parent_session_id:   Maybe(string),
	parent_tool_call_id: Maybe(string),

	base_system_prompt: Maybe(string), // 空 = 用 SDK 内置 base
	prompt_sections:    []string,      // 按顺序 append；空串跳过
	tools:              []string,      // 生效工具集；空切片 = 零工具，不能省略
}

// 追加一段 system prompt；顺序 = 调用顺序。
session_options_append :: proc(opts: ^Session_Options, section: string) {
	if len(section) == 0 {
		return
	}
	next := make([]string, len(opts.prompt_sections) + 1)
	copy(next, opts.prompt_sections)
	next[len(opts.prompt_sections)] = section
	opts.prompt_sections = next
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
		config_dir = cfg.config_dir,
		settings    = cfg.settings,
	}

	// 只准备运行时需要的目录与 project 元数据；配置文件与工具配置不在这里读。
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

	// 注册表在 session 生命周期内不可变；这里复制切片，应用层仍持有 user 指针。
	tools_copy := make([]Tool, len(cfg.tools))
	copy(tools_copy, cfg.tools)
	registry, rerr := registry_init(tools_copy)
	if !engine.is_ok(rerr) {
		return env, rerr
	}
	env.tools = registry
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
		registry = env.tools,
		source_session_id = opts.source_session_id,
		agent_name = opts.agent_name,
		model = opts.model,
		max_steps = opts.max_steps,
		max_tokens = opts.max_tokens,
		agent_depth = opts.agent_depth,
		parent_session_id = opts.parent_session_id,
		parent_tool_call_id = opts.parent_tool_call_id,
		base_system_prompt = opts.base_system_prompt,
		prompt_sections = opts.prompt_sections,
		tools = opts.tools,
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
//
// 诊断日志同时写 stderr 与 $AP_CONFIG/logs/app-YYYY-MM-DD.log。
// 文件输出默认关闭，由宿主 adapter 在解析出 $AP_CONFIG 后显式打开：
// SDK 不读环境变量、不猜配置目录，只有显式传进来的目录才会被写。

log_set_level :: proc(level: Log_Level) {
	engine.log_set_level(level)
}

// log_file_open 打开当天的日志文件（已在其它位置初始化过目录时可省略）。
log_file_open :: proc(config_dir: string) {
	platform.log_file_init(config_dir)
}

log_file_close :: proc() {
	platform.log_file_close()
}

log_error :: proc(format: string, args: ..any) {
	engine.log_error(format, ..args)
}

log_warn :: proc(format: string, args: ..any) {
	engine.log_warn(format, ..args)
}
