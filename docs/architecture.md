# 模块边界与依赖

本文件定义 ap 的模块划分、依赖方向、关键接口和进程模型。目标是让「谁负责什么」「谁能调谁」没有歧义。

实现语言为 Odin。文中接口用接近 Odin 的伪代码描述，不绑定具体包名。

## 模块清单

| 模块 | 负责 | 明确不做 |
| --- | --- | --- |
| CLI adapter（`apcore`） | 参数解析、配置入口、输出格式、退出码、信号安装 | 不组装消息，不碰 provider/loop/transcript |
| Session（`ap-core/engine/session.odin`） | 新会话/恢复/fork 解析、system prompt 预览、`session_start`/`session_end` 写入 | 不决定退出码与输出格式 |
| Loop | turn/step 状态机、事件编排、重试决策、中断处理 | 不解析 SSE，不实现工具 |
| Context | transcript → messages 投影、system prompt 组装、blob 解析 | 不发请求，不写 transcript |
| Skills | 发现并解析技能目录、生成 system prompt 清单与 `--list-skills` 简表 | 不执行技能、不把正文注入上下文 |
| Provider | 请求翻译、SSE 解析、usage 提取、错误归一 | 不重试，不做循环控制 |
| Tools | 工具注册、参数校验、执行、结果结构化、进程树管理 | 不改上下文，不做循环控制 |
| Subagent Runner | 拉起 `ap` 子进程、解析 stream-json、转换为 tool 结果 | 不直接调用父进程内存里的对象 |
| Transcript Store | 事件追加、读取、blob 读写、重放 | 不做业务判断 |
| Protocol（`ap-core/protocol`） | 事件 schema、usage、宽松事件解析、行分帧 | 只依赖 `core:`；不含 IO、路径、agent 逻辑 |
| Platform（`ap-core/platform`） | 路径/project hash/session 发现、blob 读写、JSON/文本、平台原语、进程树、取消 token | 不依赖任何本地包，不含 UI、loop、provider、tools |
| Client（`ap-core/client`） | 前端 kit：定位 ap、拼 argv、spawn、逐行泵、取消、只读 session/blob 访问、历史展示辅助 | 不 import `ap-core/engine` 或 `apcore` 根包，不实现 agent |
| Engine（`ap-core/engine`） | Loop / Provider / Context / Skills / Tools / Transcript Store / Session 编排 | 不 import `apcore`、`ap-core/client`、`ap-tui`、`ap-web` |
| External frontends | `ap-tui`（终端）与 `ap-web`（浏览器）：每轮拉起 ap 子进程、解析 `stream-json`、渲染；`ap-web` 额外提供 HTTP/SSE | 只 import `ap-core/client` + `ap-core/protocol`，不 import `ap-core/engine`、`ap-core/platform`、`apcore` 根包或彼此，不实现 agent |

## 依赖方向

单向，违反即视为设计错误：

```
cmd/ap ──► apcore（CLI adapter）
             ├──► ap-core/engine ──► ap-core/platform
             │        └──────► ap-core/protocol
             └──► ap-core/platform, ap-core/protocol

ap-core/client ──► ap-core/platform, ap-core/protocol

cmd/ap-tui ──► ap-tui（package aptui）─┐
cmd/ap-web ──► ap-web（package apweb）─┴──► ap-core/client, ap-core/protocol
```

Engine 内部：

```
Session ──► Loop ──► Context ──► (纯计算)
              │
              ├────► Provider ──► vendor:curl ──► OpenAI API
              ├────► Tools ──► Subagent Runner ──► 子进程 ap
              └────► Transcript Store ──► *.jsonl + blobs/
```


1. `Provider`、`Skills` 互不依赖；`Transcript Store` 只提供事件/blob 的读写原语；`Tools` 不依赖 Provider，但 `task` 会通过 `blob_read` 读取子代理 `message_end` 中的 `text_ref`
2. `Context` 只读 transcript、配置和 blob，不写回、不发请求
3. `Tools` 不感知 Loop 的状态机；只接收 `(name, args, ctx)` 返回结构化结果
4. 子代理只能通过命令行 + stdout/stderr 协议交互，不允许依赖父进程内存结构
5. `ap-core/protocol` 只依赖 `core:`；`ap-core/platform` 只依赖 `core:`/`vendor:`。`ap-core/engine` 只依赖 `ap-core/platform` 与 `ap-core/protocol`；`ap-core/client` 只依赖这两者；前端只依赖 `ap-core/client` 与 `ap-core/protocol`
6. 子目录就是独立包：`ap-core/*.odin` 是 `package apcore`，`ap-core/engine/*.odin` 是 `package engine`。`cmd/*` 里只有 `main`，`odin build cmd/ap` 只链接需要的那部分

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
    agent: Agent_Def,
    model: string,
    config_dir, self_exe, bash_path, session_id: string,
    agent_depth, max_agent_depth, max_steps, max_tokens: int,
    cancel: ^platform.Cancel_Token,
    events: []Event,
    emitter: Emitter,
) -> Loop
loop_run_turn :: proc(l: ^Loop, prompt: string) -> Loop_Result

context_build :: proc(project: Project, events: []Event) -> (system_prompt: string, messages: []Chat_Message, err: Error)

discover_skills :: proc(cwd: string) -> []Skill
skills_prompt_block :: proc(skills: []Skill) -> string
skills_brief :: proc(skills: []Skill) -> string

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

Tool_Context :: struct { ... }

tool_execute :: proc(name: string, args: json.Value, ctx: ^Tool_Context) -> Tool_Result
tool_definitions :: proc(agent: Agent_Def, depth, max_depth: int) -> ([]Tool_Def, Error)
```

说明：

- `Stream_Sink` 是 `{user, on_event}`，所有 Provider 事件通过 `Provider_Event` union 回调：`Provider_Message_Start` / `Provider_Text_Delta` / `Provider_Reasoning_Delta` / `Provider_Tool_Start` / `Provider_Tool_Delta` / `Provider_Tool_End` / `Provider_Message_End` / `Provider_Error_Event`。Odin 没有 async/await，流式用回调 + 阻塞 IO 实现。
- `platform.Cancel_Token` 只有一个原子标志；信号处理器设置它，Provider 在 curl 的进度回调里轮询。没有关闭通知或额外的 `loop_cancel` 接口。
- `Tool_Result` 是工具结果结构，见 [tools.md](tools.md)。
- 启动子代理所需的信息直接放在 `Tool_Context` 里：`session_id`、`cwd`、`model`、`agent_name`、`agent_depth`、`config_dir`、`self_exe`、`bash_path` 等。
- `Skills` 只在组装新 session 的 system prompt 前运行一次，把清单交给 `Context`；`context_build` 本身不访问技能目录，只从 transcript 的 `session_start` 取冻结的 system prompt。
- 子代理没有独立的 `subagent_run` 接口；它由 `tool_task` 通过 `run_child` 拉起当前 ap 可执行文件实现。

## 契约要点

1. `context_build` 必须是纯函数：同一 transcript + 同一 project 得到同一 messages；否则重放不可信。它不做摘要、不压缩、不调 LLM。system prompt 取自 `session_start`（必要时读 blob），不重新扫描记忆文件或技能目录。
2. `provider_stream` 通过 sink 报告流式事件，同时把本次请求的失败作为 `Provider_Error` 返回。sink 里的 `Provider_Error_Event` 只是通知；Loop 以返回值为准。流结束后不得再回调。
3. `tool_execute` 必须尊重取消：取消时自己终止子进程树，并返回 `ok:false`。
4. `transcript_append_line` 成功返回即意味着该行已写入并 flush；进程崩溃最多丢失最后一行。blob 必须在引用它的事件之前写完并 fsync。
5. `transcript_read_all` 按文件行序读取；遇到未知事件类型跳过；遇到 `v` 大于支持版本、且类型已知时返回错误，避免误读。
6. 任何模块都不得绕过 Loop 直接写 transcript 事件（Transcript Store 只提供追加原语）。恢复时唯一允许的物理改动是截掉崩溃留下的不完整尾行，不写修复事件。

## 进程与生命周期

1. **单主进程**：ap 本体只有一个进程；工具串行执行，不需要工作线程池
2. **子进程只出现在两处**：`bash` 执行命令（Windows 上为 Git Bash），`task` 拉起子代理
3. 所有子进程在创建时尝试加入进程树管理：
   - Unix：不创建独立进程组；超时/取消时用 `os.process_list` + PPid 递归收集后代，先发 `SIGTERM`，2s 后对同一快照发 `SIGKILL`
   - Windows：每个子进程创建一个 Job Object 并加入；超时/取消时 `TerminateJobObject`，创建或分配失败时退化为 `taskkill /T /F`；正常返回的 Job 登记到运行期表，ap 退出时统一 `TerminateJobObject`
   - Unix 的递归扫描不是运行期登记表：正常返回后 ap 不会在退出时再次清理后台后代
4. 主进程正常退出、SIGTERM、SIGINT 走统一清理；panic 按运行时行为尽力清理，`kill -9` 与断电无法清理，可能留孤儿
5. 子进程 stdout/stderr 分流：子代理把 stream-json 事件写 stdout，人类可读日志写 stderr；父进程解析 stdout、转发/捕获 stderr
6. 启动顺序：解析参数 → 确定 `$AP_CONFIG` → 加载配置 → 解析 agent → 计算 project hash → （恢复）打开并读取 transcript，取最后一个 `session_start` / （新 session）发现技能并组装 system prompt → 打开/创建 transcript 用于追加 → 写 `session_start` → 进入 Loop
7. 退出顺序：停止循环 → 清理登记的 Job（仅 Windows；Unix 无登记）→ 写 `session_end` → 关闭 transcript 与 blob 文件
8. 中断顺序：设置取消标志 → 中止 HTTP 请求 → 终止工具/子代理进程树 → 写 `cancel` → 写未闭合的 `tool_execution_end` → `message_end(cancelled)`（若正在流式）→ `turn_end` → `session_end(reason=signal)` → 退出

## 状态归属

1. **transcript 是唯一事实来源**。内存里的消息列表、usage、agent 信息都是缓存，可随时从 transcript 重建
2. 不允许出现「只在内存里有、没进 transcript」的对话内容；流式增量是例外，它们只用于实时展示，不参与恢复
3. 配置与 agent 定义是外部输入，不进 transcript；但 `session_start` 冻结当次使用的 system prompt、model、provider、agent_name、agent_depth、cwd，保证恢复可解释
4. blob 是 transcript 的一部分（按引用计入），不是缓存；内容寻址、只读、用户负责清理

## 包布局与边界

```
cmd/ap/              package main：os.exit(apcore.run(os.args))
cmd/ap-tui/          package main：os.exit(aptui.run(os.args))
cmd/ap-web/          package main：os.exit(apweb.run(os.args))
ap-core/             package apcore：run / cli / output / app / signals
ap-core/protocol/    package protocol：事件 schema、parse、Line_Reader、usage
ap-core/platform/    package platform：paths / sessions / blob / json / text / 平台原语 / 进程树 / cancel
ap-core/engine/      package engine：errors / config / session / loop / provider / sse / skills / transcript / process / tools / prompts
ap-core/client/      package client：turn / spawn / store / history
ap-tui/              package aptui：args / render / agent
ap-web/              package apweb：server / api / sse / runner / assets / pickdir
```

允许的 import 边：

| 源 | 允许 | 禁止 |
| --- | --- | --- |
| `cmd/ap` | `apcore` | 其他一切 |
| `cmd/ap-tui` | `ap-tui` | 其他一切 |
| `cmd/ap-web` | `ap-web` | 其他一切 |
| `ap-web` / `ap-tui` | `ap-core/client`、`ap-core/protocol`、`core:`/`vendor:` | `ap-core/engine`、`ap-core/platform`、`apcore` 根包、彼此 |
| `ap-core/client` | `ap-core/platform`、`ap-core/protocol`、`core:`/`vendor:` | `ap-core/engine`、`apcore` 根包 |
| `apcore` | `ap-core/engine`、`ap-core/platform`、`ap-core/protocol`、`core:`/`vendor:` | `ap-web`、`ap-tui` |
| `ap-core/engine` | `ap-core/platform`、`ap-core/protocol`、`core:`/`vendor:` | `apcore`、`ap-core/client`、前端 |
| `ap-core/platform` | `core:`/`vendor:` | 所有本地包 |
| `ap-core/protocol` | `core:` | 所有本地包 |

Odin 没有 Go 的 `internal` 机制，边界由 `tools/check-deps.sh` / `.ps1` 在测试与构建前强制：扫描 import 行，并用 `-export-dependencies:json` 断言前端的编译文件清单里没有 `ap-core/engine/`。脚本带 `--self-test` 反向用例，确认禁止 import 会返回非 0。

## 外部消费者：ap-tui 与 ap-web

`ap-tui` 不属于 ap 进程内的模块，也不依赖 ap 的内存结构。它每轮启动一个新的 ap 子进程，通过 `--print0 --output-format stream-json` 交互，并直接读取 v1 transcript 做历史重放。修改 stream-json 事件或 transcript schema 时要同步检查 [tui.md](tui.md)。

`ap-web` 与 ap-tui 同构，只是把渲染器换成浏览器：每轮 spawn 一个 ap 子进程，逐行解析 `stream-json` 并经 SSE 转发；历史同样来自 transcript，额外用 `ap-core/client` 的 session/blob 原语做重放。它自带 HTTP/1.1 + SSE 服务器（`core:net`）和编译期内置的前端资源，不 import ap 或 ap-tui；运行态按 session 注册并记录各自的 working directory，同一 session 单飞、不同标签页/不同 project 可并发。协议、并发、取消和目录选择见 [web.md](web.md)。

## 实现约束（Odin）

以下是在 Odin `dev-2026-09-nightly` 上核实过的约束，实现前必须按此规划：

1. **HTTP/TLS**：`core:net` 只有 socket，没有 HTTP 客户端，也没有 TLS 包。统一走 `vendor:curl`：
   - Windows 使用随 Odin 分发的静态 `lib/libcurl.lib`（8.17.0，Schannel，系统 CA），可保持单 exe
   - Linux/macOS 的绑定链接系统 libcurl（`system:curl`），构建/运行依赖需写进发布说明
2. **进程树**：`core:os` 的 `process_kill` 只杀直接子进程，没有进程组/Job Object；`Process_Desc` 不暴露 `CREATE_NEW_PROCESS_GROUP`。实现没有自写 spawn 层：Unix 用 PPid 递归扫描，Windows 自己声明 Win32 Job Object 绑定，失败时退化 `taskkill /T /F`
3. **可执行文件定位**：优先 `os.get_executable_path()`；失败时把 `argv[0]` 转成绝对路径；再失败则直接使用原始 `argv[0]`。子进程用该路径启动，不经过 shell
4. **标准库可用**：`core:encoding/json`、`core:crypto/sha2`、`core:encoding/uuid`、`core:sync`、`core:thread`、`core:unicode/utf8`
5. **YAML frontmatter**：没有 stdlib，agent 定义的 5 个字段手写解析
6. **流式 UTF-8**：SSE 回调可能切断多字节字符；`Sse_Parser` 的行缓冲保留未完成的行，直到换行后再交给 JSON 解析，因此不需要额外的 UTF-8 解码器
7. **Windows 控制台**：输出中文前设置 UTF-8 code page；文件路径用宽字符 API（`core:sys/windows` 已封装）
8. **版本固定**：在构建脚本里 pin Odin 版本；nightly 的 stdlib 会变

## 验证

1. **重放一致性**：同一 transcript 重复 `context_build`，输出 messages 逐字节一致；这是核心回归用例
2. **崩溃恢复**：在 `message_end`、`tool_execution_end` 前后 kill 进程，恢复后消息列表合法，且不重复执行工具
3. **进程清理**：bash 启动多层子进程后取消，验证 Unix 递归后代扫描与 Windows Job 内全部退出
4. **跨平台路径**：Windows 大小写/分隔符变体落到同一 project hash；`-s` 跨目录失败并给出清晰错误
5. **blob**：超过阈值的工具结果/参数落 blob；删除 blob 后恢复明确失败

## 后续扩展

- handoff：新增事件与 session 链接，`context_build` 只需识别一个“摘要消息”来源
- 并行工具：事件已按 `tool_call_id` 关联，读取方不假设相邻即可
- 后台子代理：需要额外的进程注册表和结果取回协议
