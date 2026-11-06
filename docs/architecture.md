# 模块边界与依赖

本文件定义 ap 的模块划分、依赖方向、关键接口和进程模型。目标是让「谁负责什么」「谁能调谁」没有歧义。

实现语言为 Odin。文中接口用接近 Odin 的伪代码描述，不绑定具体包名。

## 模块清单

| 模块 | 负责 | 明确不做 |
| --- | --- | --- |
| CLI adapter（`ap-cli`，package `apcli`） | 参数解析、读取 `settings.json`、定位 bash、agent 定义解析、system prompt 段落组装、输出格式（含 `text` 的 stderr 渲染）、退出码、信号安装、stdout/stderr、**组装根** | 不实现 agent loop/provider/transcript，不直接 import `engine` |
| CLI tools（`ap-cli/tools`，package `aptools`） | 五个内置工具、工具配置、进程树清理、子代理启动 | 不增减 transcript 事件，不控制 loop |
| CLI skills（`ap-cli/skills`，package `apskills`） | 技能发现、frontmatter 解析、提示词块与 `--list-skills` 简表 | 不执行技能正文 |
| SDK 门面（`ap-core`，package `apcore`） | 接收已解析的 `config_dir` / `settings` / `tools`，定位 project、填充 `Session_Request`、暴露会话生命周期 | 不读 argv、不读环境变量、不打开 `settings.json`、不写 stdout（诊断日志只走 stderr）、不装信号、不决定退出码 |
| Session（`ap-core/engine/session.odin`） | 新会话/恢复/fork 解析、冻结 prompt 与工具集、`session_start`/`session_end` 写入 | 不读 agent 文件、不扫描技能/记忆、不决定退出码与输出格式 |
| Loop | turn/step 状态机、事件编排、重试决策、中断处理、工具执行管线 | 不解析 SSE，不实现具体工具 |
| Context | transcript → messages 投影、base + 工具段 + sections 的 system prompt 组装、blob 解析 | 不发请求，不写 transcript，不决定 section 顺序 |
| Tool contract（`ap-core/tool`） | `Tool` / `Tool_Context` / `Tool_Result` / `Registry` / 执行管线 | 不实现具体工具、不管理进程策略 |
| Provider | 请求翻译、SSE 解析、usage 提取、错误归一 | 不重试，不做循环控制 |
| Transcript Store | 事件追加、读取、blob 读写、重放 | 不做业务判断 |
| Protocol（`ap-core/protocol`） | 事件 schema、usage、宽松事件解析、行分帧 | 只依赖 `core:`；不含 IO、路径、agent 逻辑 |
| Platform（`ap-core/platform`） | 路径/project hash/session 发现、blob 读写、JSON/文本、平台原语、进程树、取消 token | 不依赖任何本地包，不含 UI、loop、provider、tools |
| Client（`ap-core/client`） | 前端 kit：定位 ap、拼 argv、spawn、逐行泵、取消、只读 session/blob 访问、历史展示辅助 | 不 import `ap-core/engine` 或 `apcore` 根包，不实现 agent |
| MAGI（`magi`） | 三角色投票、一票否决、输入输出、成员 session 编排 | 不 import engine/ap-cli/前端，不实现 agent loop，不执行工具 |
| Engine（`ap-core/engine`） | Loop / Provider / Context / Transcript Store / Session 编排 | 不 import `apcore`、`ap-cli`、`ap-cli/tools`、`ap-cli/skills` |
| External frontends | `ap-tui`（终端）与 `ap-web`（浏览器）：每轮拉起 ap 子进程、解析 `stream-json`、渲染；`ap-web` 额外提供 HTTP/SSE | 只 import `ap-core/client` + `ap-core/protocol`，不 import `ap-core/engine`、`ap-core/platform`、`apcore` 根包或彼此，不实现 agent |

## 依赖方向

单向，违反即视为设计错误：

```
cmd/ap ──► ap-cli（package apcli，组装根）
             ├──► apcore（SDK 门面）
             ├──► ap-core/platform, ap-core/protocol, ap-core/tool
             ├──► ap-cli/tools（package aptools）
             └──► ap-cli/skills（package apskills）

ap-cli/tools ──► ap-core/tool, ap-core/platform, ap-core/protocol
ap-cli/skills ──► ap-core/platform

apcore ──► engine, ap-core/tool, platform, protocol
engine ──► ap-core/tool, platform, protocol
tool ──► platform, protocol

ap-core/client ──► ap-core/platform, ap-core/protocol

cmd/ap-tui ──► ap-tui（package aptui）─┐
cmd/ap-web ──► ap-web（package apweb）─┴──► ap-core/client, ap-core/protocol

cmd/magi-cli ──► magi（package magi）
                    ├──► apcore（SDK 门面）
                    └──► ap-core/platform
```

Engine 内部：

```
Session ──► Loop ──► Context ──► (纯计算)
              │
              ├────► Provider ──► vendor:curl ──► OpenAI API
              ├────► Tool Registry ──► Tool.execute（应用层实现）
              └────► Transcript Store ──► *.jsonl + blobs/
```

1. `Provider` 与 `Tool` 互不依赖；`Transcript Store` 只提供事件/blob 的读写原语；`tool` 只定义契约与注册表，不实现具体工具
2. `Context` 只读 transcript、配置和 blob，不写回、不发请求；system prompt 只拼 base、工具段与应用层 sections
3. `Tool` 不感知 Loop 的状态机；只接收 `(args, ctx)` 返回结构化结果；`ctx` 不含宿主配置，应用配置通过 `Tool.user` 绑定
4. 子代理只能通过命令行 + stdout/stderr 协议交互，不允许依赖父进程内存结构；`task` 属于 `ap-cli/tools`
5. `ap-core/protocol` 只依赖 `core:`；`ap-core/platform` 只依赖 `core:`/`vendor:`；`ap-core/tool` 只依赖 platform/protocol；`engine` 只依赖 tool/platform/protocol；`apcore` 依赖 engine/tool/platform/protocol；`ap-cli` 依赖 apcore、tool、platform、protocol 与自己的 tools/skills 子包，不直接 import `engine`；前端只依赖 `ap-core/client` 与 `ap-core/protocol`
6. 子目录就是独立包：`ap-cli/*.odin` 是 `package apcli`，`ap-cli/tools/*.odin` 是 `package aptools`，`ap-cli/skills/*.odin` 是 `package apskills`，`ap-core/*.odin` 是 `package apcore`（SDK 门面），`ap-core/tool/*.odin` 是 `package tool`，`ap-core/engine/*.odin` 是 `package engine`。`cmd/*` 里只有 `main`，`odin build cmd/ap` 只链接需要的那部分
7. `text` 格式的 stderr 渲染在 `ap-cli/console.odin`（package `apcli`），只依赖 `ap-core/protocol` 与 `ap-core/platform`。它与 `ap-tui/render.odin` 保持同一套视觉语言，但两份实现独立：`ap-cli` 不允许 import `ap-core/client`，且 `ap-cli` 不需要流式 assistant 文本与历史重放。展示规则（参数格式化、结果预览截断）与 `ap-core/client/history.odin` 等价，改一处要同时改另一处。

## 关键接口

```
Transcript_Store :: struct { ... }

transcript_append_line :: proc(store: ^Transcript_Store, event: any) -> (line: string, err: Error)
transcript_read_all :: proc(project: Project, session_id: string) -> ([]Event, Error)
blob_read :: proc(project: Project, sha256: string) -> ([]byte, Error)
blob_write :: proc(project: Project, data: []byte) -> (sha256: string, err: Error)

Loop :: struct { ... }

loop_init :: proc(
    project: Project,
    settings: ^Settings,
    store: ^Transcript_Store,
    registry: tool.Registry,
    active_tools: []string,
    model, agent_name, session_id: string,
    agent_depth, max_steps, max_tokens: int,
    cancel: ^platform.Cancel_Token,
    events: []Event,
    emitter: Emitter,
) -> Loop
loop_run_turn :: proc(l: ^Loop, prompt: string) -> Loop_Result

context_build :: proc(project: Project, events: []Event) -> (system_prompt: string, messages: []Chat_Message, err: Error)
context_build_in :: proc(project: Project, events: []Event, allocator: runtime.Allocator) -> (system_prompt: string, messages: []Chat_Message, err: Error)
build_system_prompt :: proc(opts: System_Prompt_Options) -> string

Session_Request :: struct { ... }
preview_prompt :: proc(req: Session_Request) -> (Session_Info, Error)
session_open :: proc(req: Session_Request) -> (Session, Session_Info, Error)
turn_run :: proc(s: ^Session, prompt: string, cancel: ^platform.Cancel_Token, emitter: Emitter) -> (Turn_Result, Error)
session_close :: proc(s: ^Session, opts: Close_Options) -> (line: string, Error)

Provider :: struct { ... }

provider_stream :: proc(
    p:      ^Provider,
    req:    ^Chat_Message_Request,
    sink:   Stream_Sink,
    cancel: ^platform.Cancel_Token,
) -> Provider_Error

// ap-core/tool
Registry :: struct { ... }
registry_init :: proc(tools: []Tool) -> (Registry, platform.Error)
registry_select :: proc(registry: ^Registry, names: []string) -> ([]string, platform.Error)
registry_definitions :: proc(registry: ^Registry, active_tools: []string) -> ([]Tool_Def, platform.Error)
registry_definitions_in :: proc(registry: ^Registry, active_tools: []string, allocator: runtime.Allocator) -> ([]Tool_Def, platform.Error)
registry_prompt_section :: proc(registry: ^Registry, active_tools: []string) -> string
tool_execute :: proc(registry: ^Registry, name: string, args: json.Value, ctx: ^Tool_Context) -> Tool_Result
```

说明：

- `Stream_Sink` 是 `{user, on_event}`，所有 Provider 事件通过 `Provider_Event` union 回调：`Provider_Message_Start` / `Provider_Text_Delta` / `Provider_Reasoning_Delta` / `Provider_Tool_Start` / `Provider_Tool_Delta` / `Provider_Tool_End` / `Provider_Message_End` / `Provider_Error_Event`。Odin 没有 async/await，流式用回调 + 阻塞 IO 实现。
- `platform.Cancel_Token` 只有一个原子标志；信号处理器设置它，Provider 在 curl 的进度回调里轮询。没有关闭通知或额外的 `loop_cancel` 接口。
- `Tool_Result` / `Tool_Context` / `Tool` / `Registry` 定义在 `ap-core/tool`，见 [tools.md](tools.md)。`Tool_Context` 只含通用字段（cwd、project、cancel、session_id、tool_call_id、agent_name、agent_depth、回调），宿主配置通过 `Tool.user` 绑定。
- 技能发现、`AGENTS.md`、环境段、agent 正文与用户追加段都在应用层；`context_build` 只从 transcript 的 `session_start` 取冻结的 system prompt。
- `context_build_in` / `registry_definitions_in` 与不带 `_in` 的版本语义完全相同，只是把全部中间分配交给传入的 allocator。Loop 每个 step 都要重建一次上下文，用 step arena 承接这些分配，step 结束时整体回收；不带 `_in` 的版本等价于传入 `context.allocator`，供测试与一次性调用使用。
- 子代理没有独立的 `subagent_run` 接口；它由 `ap-cli/tools` 的 `tool_task` 通过 `run_child` 拉起当前 ap 可执行文件实现。

### SDK 门面（`apcore`）

宿主（当前的 `ap-cli`）只 import `apcore`、`ap-core/tool` 与 platform/protocol 原语，不直接 import `engine`。门面的输入全部是显式数据：配置目录、`Settings`、已注册的工具；SDK 不打开任何配置文件、不读环境变量、不解析 agent 文件或技能目录。

```
Config :: struct {
    config_dir: string,   // 已解析：--config-dir / AP_CONFIG / ~/.ap
    cwd:        string,   // 空 = 当前目录
    settings:   Settings,
    tools:      []Tool,   // 应用层构造的注册表内容
}

Env :: struct {
    config_dir, cwd: string,
    project:  Project,
    settings: Settings,
    tools:    Registry,
}

Session_Options :: struct {
    kind, source_session_id: ...,
    agent_name, model: string,
    max_steps, max_tokens, agent_depth: int,
    parent_session_id, parent_tool_call_id: Maybe(string),
    base_system_prompt: Maybe(string),
    prompt_sections: []string,
    tools: []string, // 生效工具集；空切片 = 零工具
}

env_open :: proc(cfg: Config) -> (Env, Error)
session_request :: proc(env: ^Env, opts: Session_Options) -> Session_Request
preview_prompt :: proc(env: ^Env, opts: Session_Options) -> (Session_Info, Error)
session_open :: proc(env: ^Env, opts: Session_Options) -> (Session, Session_Info, Error)
turn_run :: proc(s: ^Session, prompt: string, cancel: ^Cancel_Token, sink: Emitter) -> (Turn_Result, Error)
session_close :: proc(s: ^Session, opts: Close_Options) -> (string, Error)

session_options_append :: proc(opts: ^Session_Options, section: string)
```

另有 `settings_defaults`（只给默认值，不读文件）、`registry_init`、`is_ok` / `errorf`、`log_set_level` / `log_warn` / `log_error`（诊断同时写 stderr 与文件日志），以及给宿主用的 `Error` / `Settings` / `Session` / `Emitter` / `Tool` / `Tool_Result` / `Registry` 等类型别名。

文件日志的目录由宿主显式打开（`apcore.log_file_open(config_dir)` → `platform.log_file_init`），SDK 不去猜 `$AP_CONFIG`。级别过滤只在 `engine` 的 `log_message` 里做一次，决定输出的消息同时写 stderr 与 `$AP_CONFIG/logs/app-YYYY-MM-DD.log`；文件写入复用 `platform.log_file_write`，失败静默。新宿主不调用 `log_file_open` 时只剩 stderr，行为与之前一致。

`settings.json` 由宿主 adapter 读取与校验：`ap-cli` 读取完整字段并拆成 `apcore.Settings` 与 `aptools.Tool_Config`，`magi` 只读取 provider 相关字段。`env_open` 不做 `setup_console`、不装信号、不写 stdout，只确保配置目录可写、解析 cwd/project、校验并保存工具注册表。`--list-skills` 的文本生成属于应用层；当前 CLI 不接受 `--list-tools`（与既有行为一致）。

## 契约要点

1. `context_build` 必须是纯函数：同一 transcript + 同一 project 得到同一 messages；否则重放不可信。它不做摘要、不压缩、不调 LLM。system prompt 取自 `session_start`（必要时读 blob），不重新扫描记忆文件或技能目录。
2. `provider_stream` 通过 sink 报告流式事件，同时把本次请求的失败作为 `Provider_Error` 返回。sink 里的 `Provider_Error_Event` 只是通知；Loop 以返回值为准。流结束后不得再回调。
3. `tool_execute` 必须尊重取消：取消时自己终止子进程树，并返回 `ok:false`。
4. `transcript_append_line` 成功返回即意味着该行已写入并 flush；进程崩溃最多丢失最后一行。blob 必须在引用它的事件之前写完并 fsync。
5. `transcript_read_all` 按文件行序读取；遇到未知事件类型跳过；遇到 `v` 大于支持版本、且类型已知时返回错误，避免误读。
6. 任何模块都不得绕过 Loop 直接写 transcript 事件（Transcript Store 只提供追加原语）。恢复时唯一允许的物理改动是截掉崩溃留下的不完整尾行，不写修复事件。
7. SDK 门面（`apcore`）不得读 `os.args` / `os.stdin`、不得写 `os.stdout`、不得装信号、不得 `os.exit`，也不得打开 `settings.json` 或读 `AP_CONFIG` / `AP_API_KEY` / `AP_BASH`：配置加载、环境发现、agent/技能/记忆解析都属于宿主 adapter（`ap-cli` / `magi`），SDK 只接收 `Config.settings` / `config_dir` / `cwd` / `tools`。退出码映射、输出格式、控制台初始化同样只属于宿主 adapter。

## 进程与生命周期

1. **单主进程**：ap 本体只有一个进程；工具串行执行，不需要工作线程池
2. **子进程只出现在两处**：`bash` 执行命令（Windows 上为 Git Bash），`task` 拉起子代理
4. 所有子进程在创建时尝试加入进程树管理：
   - Unix：不创建独立进程组；超时/取消时用 `os.process_list` + PPid 递归收集后代，先发 `SIGTERM`，2s 后对同一快照发 `SIGKILL`
   - Windows：每个子进程创建一个 Job Object 并加入；超时/取消时 `TerminateJobObject`，创建或分配失败时退化为 `taskkill /T /F`；正常返回的 Job 登记到运行期表，ap 退出时统一 `TerminateJobObject`
   - Unix 的递归扫描不是运行期登记表：正常返回后 ap 不会在退出时再次清理后台后代
5. 主进程正常退出、SIGTERM、SIGINT 走统一清理；panic 按运行时行为尽力清理，`kill -9` 与断电无法清理，可能留孤儿
6. 子进程 stdout/stderr 分流：子代理把 stream-json 事件写 stdout，人类可读日志写 stderr；父进程解析 stdout、转发/捕获 stderr
7. 启动顺序（`ap-cli`）：解析参数 → 确定 `$AP_CONFIG` → 打开文件日志（`apcore.log_file_open`，只记录目录）→ 读取并校验 `settings.json`（拆成 SDK `Settings` 与 `Tool_Config`）→ 定位 bash → 读取提示词 → （新 session）解析 agent / 发现技能 / 读取 `$AP_CONFIG/SYSTEM.md` → 构造工具注册表 → 应用工具白名单与深度规则 → 组装 prompt sections（此处读取 `AGENTS.md`）→ `apcore.env_open` → `preview_prompt` 或 `session_open` → 写 `session_start` → 进入 Loop
8. 退出顺序：停止循环 → 清理登记的 Job（仅 Windows；Unix 无登记）→ 写 `session_end` → 关闭 transcript 与 blob 文件 → 关闭日志文件
9. 中断顺序：设置取消标志 → 中止 HTTP 请求 → 终止工具/子代理进程树 → 写 `cancel` → 写未闭合的 `tool_execution_end` → `message_end(cancelled)`（若正在流式）→ `turn_end` → `session_end(reason=signal)` → 退出

## 状态归属

1. **transcript 是唯一事实来源**。内存里的消息列表、usage、agent 信息都是缓存，可随时从 transcript 重建
2. 不允许出现「只在内存里有、没进 transcript」的对话内容；流式增量是例外，它们只用于实时展示，不参与恢复
3. 配置与 agent 定义是外部输入，不进 transcript；但 `session_start` 冻结当次使用的 system prompt、model、provider、agent_name、agent_depth、cwd，保证恢复可解释
4. blob 是 transcript 的一部分（按引用计入），不是缓存；内容寻址、只读、用户负责清理

## 内存契约

长对话的内存峰值必须与 transcript 大小成线性，不能与 step 数的平方成正比。以下几条是硬约束：

1. **每个 step 的中间量必须整体回收。** Loop 按契约每 step 重新 `context_build`，因此 tools、messages、请求体都各有一份。它们存进 `Step_Arena`，step 结束（包括提前 return 的所有路径）一次性释放。
2. **每个 SSE chunk 的解析结果必须释放。** 一次回答会拆成上千个 chunk，`assembler_feed` 每轮 `json.unmarshal` 出一棵临时对象树。需要留下来的 `message_id` / `model` / `finish_reason` / `slot.id` / `slot.name` 先拷进 assembler 自己的 arena，剩下的在返回前销毁。
3. **序列化中间结果用完就放。** `json_marshal_utf8` 的 Unicode 还原缓冲、`transcript_append_line` 的规范化结果都只在一次调用内有效；`Transcript_Event.line` 是单独 clone 的副本，`type` 统一用静态字面量，调用方不需要管理所有权。
4. **所有权归持有者。** `Loop.events` 只释放自己追加的行（`initial_event_count` 之前的历史事件属于 `Session.events`）；`Loop.last_text` 只在 `loop_destroy` 释放；`Loop_Result.result_text` 是独立副本，归调用方所有（`ap-cli` / `magi` 负责释放）。Provider 借给 loop 的 `message_id` 与 tool call 的 `id` / `name` 由 loop 自己 clone，因为 assembler 的临时缓冲在 `provider_stream` 返回时就回收了。

回归用例：`test_transcript_append_does_not_leak_per_event`、`test_assembler_feed_does_not_leak_per_chunk` 用 tracking allocator 断言每事件 / 每 chunk 的净分配低于阈值。

## 包布局与边界

```
cmd/ap/              package main：os.exit(apcli.run(os.args))
cmd/ap-tui/          package main：os.exit(aptui.run(os.args))
cmd/ap-web/          package main：os.exit(apweb.run(os.args))
cmd/magi-cli/        package main：os.exit(magi.run(os.args))
ap-cli/              package apcli：options / settings / agent / prompt / run / output / console / app / signals
ap-cli/tools/        package aptools：五个内置工具、Tool_Config、process
ap-cli/skills/       package apskills：技能发现与提示词块
ap-core/             package apcore：SDK 门面（env_open / session_request / 会话生命周期）
ap-core/tool/        package tool：Tool / Tool_Context / Tool_Result / Registry / execute
ap-core/protocol/    package protocol：事件 schema、parse、Line_Reader、usage
ap-core/platform/    package platform：paths / sessions / blob / json / text / 平台原语 / 进程树 / cancel
ap-core/engine/      package engine：errors / config / session / loop / provider / sse / context / transcript / prompts
ap-core/client/      package client：turn / spawn / store / history / errors
ap-tui/              package aptui：args / render / agent / input / editor / keys / term
ap-web/              package apweb：server / http_util / api / sse / runner / assets / pickdir / net_*
magi/                package magi：options / settings / prompt / vote / run / signals
magi/prompts/        三角色与公共投票规则，编译期内嵌
```

允许的 import 边：

| 源 | 允许 | 禁止 |
| --- | --- | --- |
| `cmd/ap` | `ap-cli` | 其他一切 |
| `cmd/ap-tui` | `ap-tui` | 其他一切 |
| `cmd/ap-web` | `ap-web` | 其他一切 |
| `cmd/magi-cli` | `magi` | 其他一切 |
| `ap-cli` | `apcore`、`ap-core/tool`、`ap-core/platform`、`ap-core/protocol`、`ap-cli/tools`、`ap-cli/skills`、`core:`/`vendor:` | `ap-core/engine`、`ap-core/client`、`ap-web`、`ap-tui` |
| `ap-cli/tools` | `ap-core/tool`、`ap-core/platform`、`ap-core/protocol`、`core:`/`vendor:` | `apcore`、`ap-core/engine`、`ap-cli/skills` |
| `ap-cli/skills` | `ap-core/platform`、`core:`/`vendor:` | `apcore`、`ap-core/engine`、`ap-cli/tools` |
| `ap-web` / `ap-tui` | `ap-core/client`、`ap-core/protocol`、`core:`/`vendor:` | `ap-core/engine`、`ap-core/platform`、`apcore` 根包、`ap-cli`、彼此 |
| `magi` | `apcore`、`ap-core/platform`、`core:`/`vendor:` | `ap-core/engine`、`ap-cli`、前端、`ap-core/client` |
| `ap-core/client` | `ap-core/platform`、`ap-core/protocol`、`core:`/`vendor:` | `ap-core/engine`、`apcore` 根包 |
| `apcore` | `ap-core/engine`、`ap-core/tool`、`ap-core/platform`、`ap-core/protocol`、`core:`/`vendor:` | `ap-cli`、`ap-web`、`ap-tui`、`ap-core/client` |
| `ap-core/engine` | `ap-core/tool`、`ap-core/platform`、`ap-core/protocol`、`core:`/`vendor:` | `apcore`、`ap-cli`、`ap-cli/tools`、`ap-cli/skills`、`ap-core/client`、前端 |
| `ap-core/tool` | `ap-core/platform`、`ap-core/protocol`、`core:`/`vendor:` | 所有其它本地包 |
| `ap-core/platform` | `core:`/`vendor:` | 所有本地包 |
| `ap-core/protocol` | `core:` | 所有本地包 |

Odin 没有 Go 的 `internal` 机制，边界由 `tools/check-deps.sh` / `.ps1` 在测试与构建前强制：扫描 import 行（含 `ap-cli` 不得直接 import `engine`、`engine` 不得反向 import `ap-cli/tools`），并用 `-export-dependencies:json` 断言前端的编译文件清单里没有 `ap-core/engine/`。脚本带 `--self-test` 反向用例，确认禁止 import 会返回非 0。

## 外部消费者：ap-tui、ap-web 与 magi

`ap-tui` 不属于 ap 进程内的模块，也不依赖 ap 的内存结构。它每轮启动一个新的 ap 子进程，通过 `--print0 --output-format stream-json` 交互，并直接读取 v1 transcript 做历史重放。修改 stream-json 事件或 transcript schema 时要同步检查 [tui.md](tui.md)。

`ap-web` 与 ap-tui 同构，只是把渲染器换成浏览器：每轮 spawn 一个 ap 子进程，逐行解析 `stream-json` 并经 SSE 转发；历史同样来自 transcript，额外用 `ap-core/client` 的 session/blob 原语做重放。它自带 HTTP/1.1 + SSE 服务器（`core:net`）和编译期内置的前端资源，不 import ap 或 ap-tui；运行态按 session 注册并记录各自的 working directory，同一 session 单飞、不同标签页/不同 project 可并发。协议、并发、取消和目录选择见 [web.md](web.md)。

`magi` 是进程内宿主，不走 `ap` 子进程协议：它直接 import `apcore`，为三名角色各开一个隔离 session，聚合投票后一次退出。它不链接 `ap-cli`，工具、技能、agent 文件与信号安装都在自己的 adapter 中。协议与决策语义见 [magi.md](magi.md)。

## 实现约束（Odin）

以下是在 Odin `dev-2026-10-nightly:84bc3fc` 上核实过的约束，实现前必须按此规划：

1. **HTTP/TLS**：`core:net` 只有 socket，没有 HTTP 客户端，也没有 TLS 包。统一走 `vendor:curl`：
   - Windows 使用随 Odin 分发的静态 `lib/libcurl.lib`（8.17.0，Schannel，系统 CA），可保持单 exe
   - Linux/macOS 的绑定链接系统 libcurl（`system:curl`），构建/运行依赖需写进发布说明
2. **进程树**：`core:os` 的 `process_kill` 只杀直接子进程，没有进程组/Job Object；`Process_Desc` 不暴露 `CREATE_NEW_PROCESS_GROUP`。实现没有自写 spawn 层：Unix 用 PPid 递归扫描，Windows 自己声明 Win32 Job Object 绑定，失败时退化 `taskkill /T /F`
3. **可执行文件定位**：优先 `os.get_executable_path()`；失败时把 `argv[0]` 转成绝对路径；再失败则直接使用原始 `argv[0]`。子进程用该路径启动，不经过 shell
4. **标准库可用**：`core:encoding/json`、`core:crypto/sha2`、`core:encoding/uuid`、`core:sync`、`core:thread`、`core:unicode/utf8`
5. **YAML frontmatter**：没有 stdlib，agent 定义的 5 个字段手写解析
6. **流式 UTF-8**：SSE 回调可能切断多字节字符；`Sse_Parser` 的行缓冲保留未完成的行，直到换行后再交给 JSON 解析，因此不需要额外的 UTF-8 解码器
7. **Windows 控制台**：输出中文前设置 UTF-8 code page；文件路径用宽字符 API（`core:sys/windows` 已封装）
8. **版本记录**：README 与 AGENTS.md 记录验证过的 nightly 版本，构建脚本打印当前 `odin version`；nightly 的 stdlib 会变，升级后必须重跑完整测试。构建脚本目前不强制版本。

## 验证

1. **重放一致性**：同一 transcript 重复 `context_build`，输出 messages 逐字节一致；这是核心回归用例
2. **崩溃恢复**：在 `message_end`、`tool_execution_end` 前后 kill 进程，恢复后消息列表合法，且不重复执行工具
3. **进程清理**：bash 启动多层子进程后取消，验证 Unix 递归后代扫描与 Windows Job 内全部退出
4. **跨平台路径**：Windows 大小写/分隔符变体落到同一 project hash；`-s` 跨目录失败并给出清晰错误
5. **blob**：超过阈值的工具结果/参数落 blob；删除 blob 后恢复明确失败
6. **内存线性**：用 fake provider 跑 10/20/40/80/160 step 的 turn，堆峰值应随 step 线性增长；修复前 80 step 会到 62MB，现在约 1.8MB

## 后续扩展

- handoff：新增事件与 session 链接，`context_build` 只需识别一个“摘要消息”来源
- 并行工具：事件已按 `tool_call_id` 关联，读取方不假设相邻即可
- 后台子代理：需要额外的进程注册表和结果取回协议
