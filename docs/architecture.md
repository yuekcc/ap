# 模块边界与依赖

本文件定义 ap 的模块划分、依赖方向、关键接口和进程模型。目标是让「谁负责什么」「谁能调谁」没有歧义。

实现语言为 Odin。文中接口用接近 Odin 的伪代码描述，不绑定具体包名。

## 模块清单

| 模块 | 负责 | 明确不做 |
| --- | --- | --- |
| CLI | 参数解析、配置加载、退出码、信号安装 | 不组装消息，不碰 provider |
| Loop | turn/step 状态机、事件编排、重试决策、中断处理 | 不解析 SSE，不实现工具 |
| Context | transcript → messages 投影、system prompt 组装、blob 解析 | 不发请求，不写 transcript |
| Provider | 请求翻译、SSE 解析、usage 提取、错误归一 | 不重试，不做循环控制 |
| Tools | 工具注册、参数校验、执行、结果结构化、进程树管理 | 不改上下文，不做循环控制 |
| Subagent Runner | 拉起 `ap` 子进程、解析 stream-json、转换为 tool 结果 | 不直接调用父进程内存里的对象 |
| Transcript Store | 事件追加、读取、blob 读写、重放 | 不做业务判断 |

## 依赖方向

单向，违反即视为设计错误：

```
CLI ──► Loop ──► Context ──► (纯计算)
          │
          ├────► Provider ──► vendor:curl ──► OpenAI API
          ├────► Tools ──► Subagent Runner ──► 子进程 ap
          └────► Transcript Store ──► *.jsonl + blobs/
```

1. `Transcript Store`、`Provider`、`Tools` 互不依赖
2. `Context` 只读 transcript、配置和 blob，不写回、不发请求
3. `Tools` 不感知 Loop 的状态机；只接收 `(name, args, ctx)` 返回结构化结果
4. 子代理只能通过命令行 + stdout/stderr 协议交互，不允许依赖父进程内存结构

## 关键接口

```
Transcript_Store :: struct { ... }

transcript_append :: proc(ts: ^Transcript_Store, ev: ^Event) -> Error
transcript_read_all :: proc(ts: ^Transcript_Store, session_id: string, allocator: mem.Allocator) -> ([]Event, Error)
transcript_read_blob :: proc(ts: ^Transcript_Store, sha256: string, allocator: mem.Allocator) -> ([]byte, Error)
transcript_write_blob :: proc(ts: ^Transcript_Store, data: []byte) -> (sha256: string, err: Error)

Loop :: struct { ... }

loop_run_turn :: proc(l: ^Loop, prompt: string) -> Error
loop_cancel :: proc(l: ^Loop, scope: Cancel_Scope) -> Error

context_build :: proc(
    events:    []Event,
    cfg:       ^Config,
    blobs:     ^Blob_Reader,
    allocator: mem.Allocator,
) -> (system_prompt: string, messages: []Message, err: Error)

Provider :: struct { ... }

provider_stream :: proc(
    p:      ^Provider,
    req:    ^Request,
    sink:   Stream_Sink,
    cancel: ^Cancel_Token,
) -> Error

Tool :: struct { ... }

tool_execute :: proc(t: ^Tool, ctx: ^Tool_Context, args: json.Value) -> Result
tool_schema  :: proc(t: ^Tool) -> json.Value

Subagent_Runner :: struct { ... }

subagent_run :: proc(
    r:      ^Subagent_Runner,
    parent: ^Session_Info,
    agent:  string,
    prompt: string,
) -> (Result, Error)
```

说明：

- `Stream_Sink` 是回调集合：`on_text` / `on_reasoning` / `on_tool_call` / `on_message_end` / `on_error`。Odin 没有 async/await，流式用回调 + 阻塞 IO 实现。
- `Cancel_Token` 是原子布尔 + 关闭通知，Provider 在 curl 的进度回调里轮询。
- `Result` 是工具结果结构，见 [tools.md](tools.md)。
- `Session_Info` 包含 `session_id`、`cwd`、`model`、`agent_name`、`agent_depth`、`config_dir`，供子进程启动使用。

## 契约要点

1. `context_build` 必须是纯函数：同一 transcript + 同一配置得到同一 messages；否则重放不可信。它不做摘要、不压缩、不调 LLM。
2. `provider_stream` 通过 sink 报告事件；返回错误表示本次请求失败，最终状态由 `on_error` 或 `on_message_end` 表达。流结束后不得再回调。
3. `tool_execute` 必须尊重取消：取消时自己终止子进程树，并返回 `ok:false`。
4. `transcript_append` 成功返回即意味着该行已写入并 flush；进程崩溃最多丢失最后一行。blob 必须在引用它的事件之前写完并 fsync。
5. `transcript_read_all` 遇到未知事件类型跳过；遇到 `v` 大于支持版本、且类型已知时返回错误，避免误读。
6. 任何模块都不得绕过 Loop 直接写 transcript 事件（Transcript Store 只提供追加原语）。

## 进程与生命周期

1. **单主进程**：ap 本体只有一个进程；工具串行执行，不需要工作线程池
2. **子进程只出现在两处**：`bash` 执行命令（Windows 上为 Git Bash），`task` 拉起子代理
3. 所有子进程登记在运行期注册表里：
   - Unix：`setpgid(0, 0)` 建独立进程组，超时/取消/退出时 `killpg`
   - Windows：为每个会话建 Job Object，`bash` / `task` 进程加入；退出时 `TerminateJobObject`。Odin 的 `core:os` 不暴露 Job Object 与创建标志，需要自己声明 Win32 绑定或退化为 `taskkill /T /F`
4. 主进程正常退出、SIGTERM、SIGINT 走统一清理；panic 按运行时行为尽力清理，`kill -9` 与断电无法清理，可能留孤儿
5. 子进程 stdout/stderr 分流：子代理把 stream-json 事件写 stdout，人类可读日志写 stderr；父进程解析 stdout、转发/捕获 stderr
6. 启动顺序：解析参数 → 确定 `$AP_CONFIG` → 加载配置 → 解析 agent → 计算 project hash → （恢复）打开并读取 transcript，取最后一个 `session_start` / （新 session）组装 system prompt → 打开/创建 transcript 用于追加 → 写 `session_start` → 进入 Loop
7. 退出顺序：停止循环 → 终止登记的进程树（带超时）→ 写 `session_end` → 关闭 transcript 与 blob 文件
8. 中断顺序：设置取消标志 → 中止 HTTP 请求 → 终止工具/子代理进程树 → 写 `cancel` → 写未闭合的 `tool_execution_end` → `message_end(cancelled)`（若正在流式）→ `turn_end` → `session_end(reason=signal)` → 退出

## 状态归属

1. **transcript 是唯一事实来源**。内存里的消息列表、usage、agent 信息都是缓存，可随时从 transcript 重建
2. 不允许出现「只在内存里有、没进 transcript」的对话内容；流式增量是例外，它们只用于实时展示，不参与恢复
3. 配置与 agent 定义是外部输入，不进 transcript；但 `session_start` 冻结当次使用的 system prompt、model、provider、agent_name、agent_depth、cwd，保证恢复可解释
4. blob 是 transcript 的一部分（按引用计入），不是缓存；内容寻址、只读、用户负责清理

## 实现约束（Odin）

以下是在 Odin `dev-2026-09-nightly` 上核实过的约束，实现前必须按此规划：

1. **HTTP/TLS**：`core:net` 只有 socket，没有 HTTP 客户端，也没有 TLS 包。统一走 `vendor:curl`：
   - Windows 使用随 Odin 分发的静态 `lib/libcurl.lib`（8.17.0，Schannel，系统 CA），可保持单 exe
   - Linux/macOS 的绑定链接系统 libcurl（`system:curl`），构建/运行依赖需写进发布说明
2. **进程树**：`core:os` 的 `process_kill` 只杀直接子进程，没有进程组/Job Object；`Process_Desc` 不暴露 `CREATE_NEW_PROCESS_GROUP`。需要自写 spawn 层，或 Windows 上退化为 `taskkill /T /F`
3. **可执行文件定位**：以 `argv[0]` 为准；若它只是裸名字（没有路径分隔符），在 PATH 中解析，或在平台允许时退化为 `os.get_executable_path()`；子进程用绝对路径启动，不经过 shell
4. **标准库可用**：`core:encoding/json`、`core:crypto/sha2`、`core:encoding/uuid`、`core:sync`、`core:thread`、`core:unicode/utf8`
5. **YAML frontmatter**：没有 stdlib，agent 定义的 5 个字段手写解析
6. **流式 UTF-8**：SSE 回调可能切断多字节字符，必须自己做增量解码缓冲
7. **Windows 控制台**：输出中文前设置 UTF-8 code page；文件路径用宽字符 API（`core:sys/windows` 已封装）
8. **版本固定**：在构建脚本里 pin Odin 版本；nightly 的 stdlib 会变

## 验证

1. **重放一致性**：同一 transcript 重复 `context_build`，输出 messages 逐字节一致；这是核心回归用例
2. **崩溃恢复**：在 `message_end`、`tool_execution_end` 前后 kill 进程，恢复后消息列表合法，且不重复执行工具
3. **进程清理**：bash 启动多层子进程后取消，验证进程组/Job 内全部退出
4. **跨平台路径**：Windows 大小写/分隔符变体落到同一 project hash；`-s` 跨目录失败并给出清晰错误
5. **blob**：超过阈值的工具结果/参数落 blob；删除 blob 后恢复明确失败

## 后续扩展

- handoff：新增事件与 session 链接，`context_build` 只需识别一个“摘要消息”来源
- 并行工具：事件已按 `tool_call_id` 关联，读取方不假设相邻即可
- 后台子代理：需要额外的进程注册表和结果取回协议
