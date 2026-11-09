# 模块、进程与契约

本文件定义 ap 的模块职责、依赖方向、关键接口、进程生命周期、状态归属、内存契约和 Odin 约束。包布局与允许的 import 边只在 [dependencies.md](dependencies.md) 定义。事件字段与恢复规则见 [react-loop-and-session.md](react-loop-and-session.md)。

## 进程形态

ap 有三种进程形态，共用同一套 SDK 或进程协议。

| 形态 | 入口 | 启动方式 | 主要通道 |
| --- | --- | --- | --- |
| 一次性 CLI | `cmd/ap` 调 `apcli.run` | 用户或脚本直接执行 | 结果写 stdout，诊断与进度写 stderr |
| 前端 | `cmd/ap-tui` 调 `aptui.run`，`cmd/ap-web` 调 `apweb.run` | 每个 turn 启动一个 `ap` 子进程 | 提示词走 stdin，事件走 stdout |
| 决策器 | `cmd/magi-cli` 调 `magi.run` | 进程内 import `apcore` | 决议写 stdout，进度写 stderr |

ap 本体只有一条控制流。一个 turn 内按顺序执行 step 和工具，没有工作线程池。ap 创建的子进程只有两类：`bash` 工具启动的 shell，以及 `task` 工具启动的子代理。两者都在取消时终止整棵进程树。`bash` 另有超时，超时同样终止整棵进程树；`task` 本身不设超时。

`ap-tui` 与 `ap-web` 不链接 agent 代码。它们每轮拼出 `ap --print0 --output-format stream-json`，把提示词写入子进程 stdin，逐行解析 stdout。前端只理解 `ap-core/protocol` 的宽松事件结构和 `ap-core/client` 的进程辅助。`ap-tui` 直接读 transcript 做历史重放。`ap-web` 还维护 HTTP/SSE 连接和按 session 的单飞。

`magi` 是第二个进程内宿主。它 import `apcore` 与 `ap-core/platform`，为三名角色各开一个隔离 session。它不启动 `ap` 子进程，不链接 `ap-cli`，不注册工具。

## 模块职责

| 模块 | 负责 | 明确不做 |
| --- | --- | --- |
| `cmd/*` | 解析后调用对应库的 `run` | 不承载业务逻辑 |
| `ap-cli`（`apcli`） | argv、环境发现、`settings.json(c)`、agent 定义、prompt sections、输出、退出码、信号、组装 | 不 import engine，不含 loop 或 provider |
| `ap-cli/tools`（`aptools`） | 五个内置工具、`Tool_Config`、进程树、子代理启动 | 不写 transcript 事件，不控制 loop |
| `ap-cli/skills`（`apskills`） | 技能发现、frontmatter、提示词块、`--list-skills` | 不执行技能正文 |
| `apcore` | 接收 `Config`、定位 project、组装 `Session_Request`、暴露会话生命周期、日志入口 | 不读 argv、环境变量或 `settings.json(c)`，不写 stdout，不装信号，不决定退出码 |
| `ap-core/engine` | session、loop、provider、context、transcript 的编排 | 不 import `apcore`、`ap-cli` 或前端 |
| `ap-core/tool` | `Tool`、`Tool_Context`、`Tool_Result`、`Registry`、执行管线 | 不 import engine，不提供具体工具 |
| `ap-core/platform` | 路径与 project hash、session 发现、blob、JSON 与文本、平台原语、进程树、取消 token、日志文件 | 不 import 任何本地包，不含 agent 逻辑 |
| `ap-core/protocol` | 事件 schema 与 wire 常量、宽松解析、`Line_Reader`、usage | 不 import 任何本地包，不含 IO、路径或 agent 逻辑 |
| `ap-core/client` | spawn、拼 argv、逐行泵、取消、只读 project/session/blob、历史展示辅助 | 不 import engine 或 `apcore` 根包，不含 agent |
| `ap-tui`（`aptui`） | 终端渲染、输入、编辑器、按键、terminal 控制、历史重放 | 不 import engine 或 platform，不含 agent |
| `ap-web`（`apweb`） | HTTP/1.1、SSE、API、turn runner、前端资源、目录选择 | 不 import engine 或 platform，不含 agent |
| `magi` | 三角色提示词、并行 session、投票聚合、一票否决、输出 | 不 import engine 或 `ap-cli`，不执行工具 |

`ap-core/engine` 内部按文件分工：

| 文件 | 负责 |
| --- | --- |
| `session.odin` | 新会话、恢复、fork 的解析，冻结值与 `session_start`、`session_end` |
| `loop.odin` | turn/step 状态机、重试决策、取消路径、工具执行编排、事件追加 |
| `context.odin` | transcript 到 messages 的投影、system prompt 组装、blob 解引用 |
| `provider.odin`、`sse.odin` | OpenAI chat completions 请求、SSE 解析、tool call 组装、usage、错误归一 |
| `transcript.odin` | 事件追加与读取、最后一个 `session_start` 的定位、fork 与恢复 |
| `errors.odin`、`config.odin` | 错误值、日志级别、`Settings` 与默认值 |
| `prompts/system.md` | 编译期内嵌的基础 system prompt |

## 依赖方向

依赖只能向下。箭头表示 import 方向：

```
cmd/ap ──► ap-cli ──► apcore ──► engine ──┬──► provider ──► vendor:curl
            │         │                  ├──► tool ──► platform、protocol
            │         └──► tool          └──► transcript ──► JSONL + blobs
            ├──► ap-cli/tools ──► tool、platform、protocol
            └──► ap-cli/skills ──► platform

cmd/ap-tui ──► ap-tui ──┐
cmd/ap-web ──► ap-web ──┴──► ap-core/client ──► platform、protocol

cmd/magi-cli ──► magi ──► apcore ──► engine
                        └──► platform
```

维持这条方向的五条规则：

1. `apcli` 只通过 `apcore` 使用 agent 机制。宿主嵌入 SDK 时不需要链接 CLI。
2. `engine` 只依赖 tool、platform、protocol。应用层的 agent 文件、技能、记忆和工具实现都不进入 engine。
3. `tool` 只依赖 platform 与 protocol。`Tool.user` 让宿主把配置绑到具体工具，SDK 把它当作不透明指针。
4. `platform` 与 `protocol` 是叶子包。它们只使用 `core:`、`base:`、`vendor:`。
5. 前端只依赖 client 与 protocol。前端二进制里不能出现 `ap-core/engine/`，这条由检查器的编译文件清单断言。

完整白名单与检查器用法见 [dependencies.md](dependencies.md)。

## 关键接口

SDK 门面（`apcore`）的输入全部是已解析值：

```odin
Config :: struct {
	config_dir: string,
	cwd:        string,
	settings:   Settings,
	tools:      []Tool,
}

Env :: struct {
	config_dir: string,
	cwd:        string,
	project:    Project,
	settings:   Settings,
	tools:      Registry,
}

Session_Options :: struct {
	kind:                Session_Kind,
	source_session_id:   string,
	agent_name:          string,
	model:               string,
	max_steps:           int,
	max_tokens:          int,
	agent_depth:         int,
	parent_session_id:   Maybe(string),
	parent_tool_call_id: Maybe(string),
	base_system_prompt:  Maybe(string),
	prompt_sections:     []string,
	tools:               []string,
}

env_open :: proc(cfg: Config) -> (Env, Error)
session_request :: proc(env: ^Env, opts: Session_Options) -> Session_Request
preview_prompt :: proc(env: ^Env, opts: Session_Options) -> (Session_Info, Error)
session_open :: proc(env: ^Env, opts: Session_Options) -> (Session, Session_Info, Error)
turn_run :: proc(s: ^Session, prompt: string, cancel: ^Cancel_Token, sink: Emitter) -> (Turn_Result, Error)
session_close :: proc(s: ^Session, opts: Close_Options) -> (string, Error)
```

`Session_Options.tools` 不能省略。空切片表示零工具。`tools` 只在 `kind == .New` 时生效。恢复与 fork 使用 `session_start` 里的冻结值。`max_steps` 与 `max_tokens` 不在冻结范围内，恢复时取本次设置。

engine 的会话与上下文接口：

```odin
session_open :: proc(req: Session_Request) -> (Session, Session_Info, Error)
turn_run :: proc(s: ^Session, prompt: string, cancel: ^platform.Cancel_Token, emitter: Emitter) -> (Turn_Result, Error)
session_close :: proc(s: ^Session, opts: Close_Options) -> (string, Error)
preview_prompt :: proc(req: Session_Request) -> (Session_Info, Error)

context_build :: proc(project: Project, events: []Event) -> (string, []Chat_Message, Error)
context_build_in :: proc(project: Project, events: []Event, allocator: runtime.Allocator) -> (string, []Chat_Message, Error)
context_build_budgeted :: proc(project: Project, events: []Event, tools_tokens, limit_tokens, calibration_percent: int, allocator: runtime.Allocator) -> (Budgeted_Context, Error)
build_system_prompt :: proc(opts: System_Prompt_Options) -> string
```

Provider 通过 sink 回调流式事件，同时用返回值报告本次请求的结果：

```odin
Provider_Event :: union {
	Provider_Message_Start,
	Provider_Text_Delta,
	Provider_Reasoning_Delta,
	Provider_Tool_Start,
	Provider_Tool_Delta,
	Provider_Tool_End,
	Provider_Message_End,
	Provider_Error_Event,
}

Stream_Sink :: struct {
	user:     rawptr,
	on_event: proc(user: rawptr, event: Provider_Event),
}

provider_stream :: proc(
	p:      ^Provider,
	req:    ^Chat_Message_Request,
	sink:   Stream_Sink,
	cancel: ^platform.Cancel_Token,
) -> Provider_Error
```

工具契约与注册表：

```odin
Tool :: struct {
	name:            string,
	description:     string,
	parameters_json: string,
	user:            rawptr,
	execute:         proc(user: rawptr, args: json.Value, ctx: ^Tool_Context) -> Tool_Result,
}

Tool_Context :: struct {
	cwd:          string,
	project:      platform.Project,
	cancel:       ^platform.Cancel_Token,
	session_id:   string,
	tool_call_id: string,
	agent_name:   string,
	agent_depth:  int,
	on_update:    proc(user: rawptr, chunk: string),
	update_user:  rawptr,
	on_progress:  proc(user: rawptr, kind: Progress_Kind, line: string),
	progress_user: rawptr,
}

registry_init :: proc(tools: []Tool) -> (Registry, platform.Error)
registry_select :: proc(registry: ^Registry, names: []string) -> ([]string, platform.Error)
registry_definitions :: proc(registry: ^Registry, active_tools: []string) -> ([]Tool_Def, platform.Error)
registry_definitions_in :: proc(registry: ^Registry, active_tools: []string, allocator: runtime.Allocator) -> ([]Tool_Def, platform.Error)
registry_prompt_section :: proc(registry: ^Registry, active_tools: []string) -> string
tool_execute :: proc(registry: ^Registry, name: string, args: json.Value, ctx: ^Tool_Context) -> Tool_Result
```

`context_build_in` 与 `registry_definitions_in` 的语义和不带 `_in` 的版本相同，只是把中间分配交给传入的 allocator。不带 `_in` 的版本等价于传 `context.allocator`。

`Tool_Context` 只放通用字段。宿主的工具配置通过 `Tool.user` 绑定，SDK 不解释。技能、`AGENTS.md`、环境段、agent 正文和其余 prompt sections 全在应用层。`context_build` 只从 transcript 的 `session_start` 取冻结的 system prompt。

前端 kit 的核心接口：

```odin
Turn_Options :: struct {
	agent_bin:    string,
	config_dir:   string,
	cwd:          string,
	session_id:   string,
	fork_session: bool,
	model:        Maybe(string),
	agent:        Maybe(string),
	max_steps:    Maybe(int),
	max_tokens:   Maybe(int),
	verbose:      bool,
	cancel:       ^platform.Cancel_Token,
	allocator:    runtime.Allocator,
}

turn_run :: proc(options: ^Turn_Options, prompt: string, callbacks: Turn_Callbacks) -> Turn_Result
resolve_agent_bin :: proc(configured: Maybe(string)) -> (string, Error)
```

`Turn_Callbacks` 同时提供结构化事件和原始行。`on_event_line` 让 SSE 原样转发 ap 的 JSON 行，避免重新序列化丢掉字段。子代理没有独立的 `subagent_run` 接口，它由 `ap-cli/tools` 里的 `task` 工具启动当前 ap 可执行文件。

## 契约

1. `context_build` 必须是纯函数。同一 transcript 和同一 project 得到逐字节相同的 messages。它不调用 LLM，不压缩，不写 transcript，不重新扫描记忆或技能。

   `context_build_budgeted` 把契约扩展成「(transcript, budget) 的纯函数」：`limit_tokens` 与 `calibration_percent` 由调用方显式传入，不读环境、不读时钟、不做 IO 决策。它唯一新增的行为是把较早的大工具输出在投影层替换成固定桩文本。`limit_tokens <= 0` 时与 `context_build` 逐字节相同。
2. transcript 只追加。`transcript_append_line` 成功返回时，该行已写入并 flush。恢复时唯一允许的物理改动是截掉崩溃留下的不完整尾行，不写修复事件。
3. blob 先写后引用。`blob_write` 先写临时文件，执行 `os.sync`，再改名到 `<sha256>`。引用 blob 的事件必须在这之后追加。blob 缺失或校验失败时恢复失败，不静默降级。
4. provider 的返回值是本次请求的权威结果。sink 里的 `Provider_Error_Event` 只是通知。`provider_stream` 返回后不得再回调。
5. 工具必须尊重取消。取消时工具终止自己的进程树，返回 `ok:false`。`tool_execute` 对非 JSON 对象参数和未知工具名一律返回工具失败。
6. transcript 读取时跳过未知事件类型。已知类型的版本高于 `SCHEMA_VERSION` 时返回错误。非最后一行的损坏视为错误。最后一条非空行损坏时忽略并 warning；恢复流程只截掉没有换行结尾的半行。
7. 任何模块都不得绕过 Loop 直接写 transcript 事件。`Transcript_Store` 只提供追加与读取原语。
8. SDK 门面不读 `os.args`、`os.stdin` 或环境变量，不写 stdout，不装信号，不调用 `os.exit`。配置加载、agent 解析、技能发现与退出码映射都属于宿主 adapter。
9. 退出码由宿主 adapter 映射。`apcore` 与工具返回错误值，不调用 `os.exit`。`ap-cli` 与 `magi` 各自映射自己的退出码。

## 启动、退出与取消

### 启动顺序

`apcli.run` 的顺序如下：

1. `platform.setup_console`，`platform.normalize_args`，`parse_args`。
2. 处理 `--help`、`--version`、`--list-skills` 后提前返回。
3. 按 `--debug`、`--verbose` 或默认值设置日志级别。
4. 解析配置目录。优先级是 `--config-dir`、`AP_CONFIG`、`~/.ap`。打开文件日志。
5. 读取并校验配置文件（`settings.jsonc` 优先，否则 `settings.json`；内容按 JSON5 解析），拆成 `apcore.Settings` 与 `aptools.Tool_Config`。`--print-system-prompt` 不要求 API key。
6. 规范化启动目录，定位 bash，读取 home 目录。
7. 由 `-s`、`-c`、`--fork-session` 决定 `Session_Kind`。
8. 读取提示词。`--print-system-prompt` 跳过这一步。
9. 新 session 才加载 agent 定义，按 CLI、agent、settings 的优先级合并 model 与 max_steps，读取 `$AP_CONFIG/SYSTEM.md`，发现技能。
10. 构造工具注册表。新 session 再按 agent 白名单与 `max_agent_depth` 选出工具集。
11. 新 session 组装 prompt sections。顺序是环境、技能、全局记忆、项目记忆、agent 正文。
12. `apcore.env_open`。它确保配置目录可写，再次规范化 cwd，打开 project 目录，建立不可变注册表。
13. `preview_prompt` 或 `session_open`。新 session 在这里写 `session_start`，必要时把 system prompt 写入 blob。恢复与 fork 也追加一条新的 `session_start`。
14. 安装信号处理器，初始化输出，`stream-json` 立即写出 `session_start` 行。
15. `turn_run`。

恢复与 fork 跳过第 9 步到第 11 步里只属于新 session 的部分。`model`、`agent_name`、system prompt、工具集、cwd 与 `agent_depth` 取自冻结的 `session_start`。冲突参数只产生 warning。

### 退出顺序

1. `turn_run` 返回。若返回错误值，CLI 写 `session_end(reason="error")`，关闭 transcript，按错误类型映射退出码。
2. 正常情况下先检查信号状态，再调用 `platform.cleanup_jobs` 清理登记的子进程树。
3. 选 `session_end.reason`：取消为 `signal`，错误为 `error`，其余为 `exit`。
4. `session_close` 重读 transcript，优先用所有 `turn_end.usage` 的总和，写 `session_end`，关闭 transcript。
5. `stream-json` 输出 `session_end` 行。`text` 与 `json` 输出最终结果，`stream-json` 由事件流表达结果。
6. 释放 `Turn_Result.result_text`，映射退出码。`apcli.run` 的 `defer` 关闭文件日志。

没有成功打开 session 的早期错误没有 `session_end`。`magi` 在每个成员线程的 `defer` 里关闭该成员的 session。

### 取消顺序

1. 信号处理器记录退出码，并设置 `platform.Cancel_Token`。Unix 的 `SIGINT` 对应 130，`SIGTERM` 对应 143。Windows 的 Ctrl+C 与 Ctrl+Break 对应 130。1 秒内收到第二次信号时直接 `os.exit`。
2. Provider 在 curl 进度回调与返回前轮询 token，命中后中止 HTTP 请求。
3. 正在执行的工具轮询 token，终止子进程树，返回 `ok:false` 与 `cancelled`。
4. Loop 写 `cancel` 事件。正在流式输出时补一条 `message_end(stop_reason="cancelled")`，然后写 `turn_end(stop_reason="cancelled")`。
5. `Turn_Result.cancelled` 置位。CLI 用信号处理器记录的码映射退出码，缺省为 130，`session_close` 写 `session_end(reason="signal")`。
6. 前端侧取消时，`ap-core/client` 终止 ap 子进程树，等待 3 秒，超时再强杀，然后继续排空已缓冲的 stdout。

## 状态归属

1. transcript 是唯一事实来源。`Session.events` 是已读事件的缓存，可以从 transcript 重建。
2. 只存在于内存的对话内容不允许出现。流式增量只用于实时展示，不参与恢复。
3. 配置与 agent 定义是外部输入，不写入 transcript。`session_start` 冻结 system prompt、model、provider、agent、agent_depth、cwd、工具集与父子 session 关系。
4. blob 是 transcript 的一部分。它按引用计入，内容寻址，只读，由用户清理。
5. 工具注册表在 session 期间不可变。宿主配置通过 `Tool.user` 绑定，注册表本身不保存会话状态。
6. usage 以 `turn_end` 为准。`session_close` 重读全部 `turn_end` 求和，优先采用这个总和。
7. `magi` 的投票结果只在内存里聚合。每名成员的 session 仍有自己的 transcript。

## 内存契约

长对话的内存峰值随 transcript 大小线性增长，不随 step 数平方增长。

1. 每个 step 的中间量整体回收。`context_build_in` 与 `registry_definitions_in` 的输出，以及拼好的 messages，都放进 `Step_Arena`，step 结束时销毁，提前 return 的路径也一样。序列化后的请求体在 `provider_stream` 内单独分配，并在返回前释放。
2. 每个 SSE chunk 的解析结果及时释放。`assembler_feed` 每轮解析出的 JSON 树在返回前销毁。需要留下的 `message_id`、`model`、`finish_reason`、tool call 的 `id` 与 `name` 先复制到 assembler 自己的 arena。
3. 序列化中间结果用完就放。`json_marshal_utf8` 的 Unicode 还原缓冲、`flatten_event_json` 的临时行只在一次调用内有效。`Transcript_Event.line` 是单独 clone 的副本。已知事件类型的 `type` 使用静态字面量，调用方不需要释放。
4. 所有权归持有者。`Loop` 只释放自己追加的行，`initial_event_count` 之前的事件属于 `Session.events`。`Loop.last_text` 在 `loop_destroy` 释放。`Loop_Result.result_text` 是独立副本，归调用方释放。provider 借出的 `message_id` 与 tool call 字段由 loop 自己 clone。

回归用例用 tracking allocator 断言净分配：`test_transcript_append_does_not_leak_per_event` 与 `test_assembler_feed_does_not_leak_per_chunk`。

## Odin 约束

开发与验证使用 `dev-2026-10-nightly:84bc3fc`。升级 Odin 后必须重跑 `./test.sh`。

1. HTTP 与 TLS 只走 `vendor:curl`。`core:net` 没有 HTTP 客户端，也没有 TLS。Windows 使用 Odin 随附的静态 libcurl。Linux 与 macOS 链接系统 libcurl，构建和运行需要开发包。
2. `core:os` 的 `process_kill` 只杀直接子进程，没有进程组或 Job Object。Unix 用 PPid 递归收集后代，先发 `SIGTERM`，2 秒后对同一快照发 `SIGKILL`。Windows 自己声明 Win32 Job Object 绑定，失败时退化为 `taskkill /T /F`。
3. 可执行文件定位依次尝试 `os.get_executable_path`、把 `os.args[0]` 转成绝对路径、使用原始 `os.args[0]`。子进程用该路径启动，不经过 shell。
4. 可用标准库包括 `core:encoding/json`、`core:crypto/sha2`、`core:encoding/uuid`、`core:sync`、`core:thread` 与 `core:unicode/utf8`。
5. 没有 YAML frontmatter 标准库。agent 定义的 `name`、`description`、`tools`、`model`、`max_steps` 由 `ap-cli/agent.odin` 手写解析。
6. SSE 回调可能切断多字节字符。`Sse_Parser` 按行缓冲，收到换行后才交给 JSON 解析，因此不需要额外的 UTF-8 解码器。
7. Windows 控制台在输出前把输入与输出代码页设为 UTF-8。命令行代码页不是 UTF-8 时，`normalize_args` 用宽字符命令行重建参数。文件路径使用宽字符 API。
8. 基础 system prompt 由 `#load("prompts/system.md", string)` 在编译期内嵌。`ap-web/dist` 由 `#load_directory("dist")` 内嵌，构建前必须先刷新前端产物。

## 相关文档

- [dependencies.md](dependencies.md)：包布局与 import 白名单
- [react-loop-and-session.md](react-loop-and-session.md)：turn/step、事件 schema、恢复与 fork
- [context-management.md](context-management.md)：system prompt 与消息投影
- [errors-and-cancellation.md](errors-and-cancellation.md)：错误分类、重试与取消
- [integration.md](integration.md)：前端接入 ap 的进程契约
