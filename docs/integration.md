# 把 ap 接入一个新前端

这份指南说明如何用进程边界把 `ap` 接进一个终端、网页或编辑器前端。读完后你应当能启动一轮 turn、消费事件、恢复 session 并取消运行。CLI 参数细节见 [cli-and-config.md](cli-and-config.md)，事件 schema 见 [react-loop-and-session.md](react-loop-and-session.md)，错误与取消的分类见 [errors-and-cancellation.md](errors-and-cancellation.md)。

`ap` 是一次性 CLI。每轮启动一个新进程，写一条提示词，读一个 turn 的事件，然后进程退出。下面是整条链路：

```text
前端 ──spawn──► ap --print0 --output-format stream-json [-s <id>] ...
         │
         ├── stdin  ◄── 整条提示词，写完关闭
         ├── stdout ──► 每行一个 JSON 事件
         └── stderr ──► 人类可读日志

前端 ──read───► <config-dir>/projects/<project_path_hash>/<session_id>.jsonl
```

进程内 SDK 不是本文的契约。同仓库的 Odin 宿主请参考 [architecture.md](architecture.md)。

## 1. 找到 ap 可执行文件

按下面的顺序查找，命中即停：

1. 用户显式配置的 `--agent-bin <path>`。
2. 环境变量 `AP_AGENT_BIN`，然后是 `AP_BIN`。
3. 前端自身可执行文件同目录的 `ap.exe`。Unix 上是 `ap`。
4. `PATH` 中的 `ap`。

查找时遵循下面的规则：

- 显式值含路径分隔符时按路径解析，规范化后必须存在。
- 显式值不含路径分隔符时当作命令名，到 `PATH` 里找。
- 候选必须是普通文件。只判断“存在”会把同名的源码目录当成可执行文件。
- Windows 的 `PATH` 查找先试无扩展名，再试 `.exe`。
- 找不到时由前端报错并以非 0 退出。参考实现用退出码 2。

**结果**：你得到一个可启动的普通文件路径。不要在这个阶段启动 `ap`。

## 2. 拼出命令行

最小命令是：

```sh
ap --print0 --output-format stream-json --config-dir <dir>
```

完整形式如下。

```sh
ap --print0 --output-format stream-json \
   [-s <session_id>] [--fork-session] \
   [--model <id>] [--agent <name>] [--max-steps <n>] [--max-tokens <n>] \
   --config-dir <dir> [--verbose]
```

1. 总是传 `--print0`。它表示从 fd 0 读到 EOF，不是 NUL 分隔。`ap` 不会隐式读取 stdin。
2. 总是传 `--output-format stream-json`。stdout 每行一个事件。
3. 新 session 的第一轮不要传 `-s`。之后每轮都传 `-s <session_id>`。
4. 总是传 `--config-dir <dir>`，让前端读写 transcript 的目录与 `ap` 一致。优先级是 `--config-dir`、`AP_CONFIG`、`~/.ap`。
5. 需要时透传 `--model`、`--agent`、`--max-steps`、`--max-tokens`。`--verbose` 只增加 stderr 日志。新 session 还可以透传 `--no-agents-md` 或 `--no-skills`。恢复时这些上下文开关不改变冻结值。
6. 需要 fork 时加 `--fork-session`。它必须和 `-s` 或 `-c` 连用。
7. `-s` 和 `-c` 互斥。`-c` 让 `ap` 自己选当前项目最近的根 session。
8. 参数用数组传给 `process_start` 或 `execve`。不要拼 shell 字符串。
9. 前端概念（session key、UI 状态、标签页编号）不要传给 `ap`。

**结果**：命令能启动，`ap` 等 stdin，stdout 只输出 JSON 事件，stderr 输出人类日志。长提示词只走 stdin。不要用 `--print` 传长提示词。

## 3. 设好工作目录

1. 选定 session 所属 project 的根目录。
2. 把目录解析成绝对路径，并确认它存在。
3. 启动子进程时把这个目录设为 `working_dir`。
4. 每个 session 记录自己的 `cwd`。切换 session 时只换启动目录，不改前端进程的 `cwd`。

`ap` 用启动目录识别 project。`-s` 和 `-c` 只在当前 project 里查找 transcript。在另一个目录启动，就找不到原 session。

**结果**：transcript 落在 `<config-dir>/projects/<project_path_hash>/` 下。目录不对时 `ap` 以退出码 2 结束，并在 stderr 打印期望路径。

## 4. 处理三个流

1. 把整条提示词写到 stdin，然后立即关闭写端。关闭就是 EOF 信号。空提示词在 UI 层拦截。
2. 逐行读取 stdout，边读边处理。每个完整行是一个 JSON 事件。不要等进程退出后再集中显示。
3. 收集 stderr 的尾部窗口。参考实现保留 64 KiB，超出时保留最近约 32 KiB 并对齐整行。正常退出可以不展示，非 0 退出时展示。
4. 传了 `--verbose` 时可以实时展示 stderr，并把每行加 `[ap]` 之类的前缀。
5. 不要把 stderr 合并进 stdout。任何普通日志混入 stdout 都会损坏行协议。
6. `ap` 退出前可能向 stderr 打一行续聊提示，内容包含 `<可执行文件> -s <session_id>`。展示或忽略都可以。

**结果**：`ap` 读到 stdin EOF 后开始 turn。stdout 的行可以直接交给事件解析器。异常退出时你有足够的 stderr 诊断信息。

Windows 还要清理管道继承标志。启动子进程前，对前端自己保留的三端清除继承位：

- stdin 管道的写端。
- stdout 管道的读端。
- stderr 管道的读端。

否则子进程会继承 stdin 写端，读 stdin 时永远等不到 EOF。参考实现见 `ap-core/platform/process_windows.odin` 的 `mark_non_inheritable` 与 `ap-core/client/turn.odin` 的调用点。

**结果**：子进程能读到 stdin EOF，前端也能在 turn 结束后读到 stdout 和 stderr 的 EOF。

## 5. 跟完一轮 turn

1. 抢占该 session 的运行态。同一 session 已有 turn 时拒绝新请求，不同 session 可以并行。
2. 检查取消令牌。若在 spawn 前已经取消，直接返回，不启动进程。
3. 创建 stdin、stdout、stderr 三个管道并 spawn `ap`，工作目录用该 session 的 `cwd`。
4. 父进程关闭 stdin 读端、stdout 写端、stderr 写端。
5. 把提示词写入 stdin，关闭 stdin 写端。
6. 同时泵 stdout 和 stderr。stdout 走行读取器，stderr 走日志缓存。不要先读完 stdout 再读 stderr，两边都可能写满管道。
7. 解析 stdout。收到 `session_start` 时记下真实 `session_id`。新会话还要把前端的临时 key 别名到这个 id。
8. 等待直接子进程退出。等待期间检查取消令牌。收到取消时终止整棵进程树。
9. 直接子进程退出后，只排空当前已经可读的数据。不要等后台后代释放管道。`bash` 可能留下持有写端的后台进程。
10. 生成结束信封，至少包含 `exit_code`、`stop_reason`、`usage`、`stderr_preview`。
11. 释放运行态和取消令牌，保留 transcript 供下一轮 `-s` 使用。

**结果**：一轮结束后，前端同时拿到退出码、stop reason 和 usage。下一轮可以继续同一个 session。

结束时要判断下面几件事：

- `session_id` 只能来自 `session_start`。新会话第一轮必须允许“还没有真实 id”的状态。
- `turn_end` 不一定存在。provider 重试耗尽、工具基础设施故障或 Windows 强杀都可能没有它。
- `stop_reason` 的回退顺序是 `turn_end.stop_reason`、`session_end.reason`、主动取消时填 `cancelled`、都没有时为 null。`session_end.reason` 的取值是 `exit`、`signal`、`error`，不要当成正常 stop reason。
- 退出码按 [cli-and-config.md](cli-and-config.md) 的退出码表处理。退出码 0 不代表模型正常说完，`max_steps` 和 `max_tokens` 也会以 0 退出。
- 每轮开始时清空取消令牌。否则“取消后立刻开新 turn”会继承旧状态。
- UI 断开、页面关闭或 SSE 断线不应取消 turn。turn 应当继续跑完并写 transcript。

## 6. 解析事件

1. 按字节切 `\n`。不要先做 UTF-8 解码，多字节字符可能跨读取块。
2. 去掉行尾的 `\r`。使用 `ap-core/protocol` 的 `Line_Reader` 时已统一处理；自行分帧的集成方仍需自己去。空行、非 JSON、缺少 `type` 的行静默跳过。
3. JSON 解析要忽略未知字段，遇到未知 `type` 跳过。
4. 保留原始行用于转发。用结构体重新序列化会丢掉 `ap` 新增的字段。
5. 区分两类事件。transcript 事件带 `v`、`seq`、`ts`、`type`。stream 事件只有 `type`、`ts` 和业务字段，没有 `seq`。
6. `v` 当前固定为 1。`seq` 在单个 session 内从 0 单调递增，用来排序和去重。stream 事件的顺序只由 stdout 行序保证。
7. 进程退出时，把最后没有换行结尾的残余也交给解析器。

**结果**：事件流可以被实时渲染，也可以原样转发给 SSE 或消息总线。

下表只列集成方必须读取的字段。完整 schema 见 [react-loop-and-session.md](react-loop-and-session.md)。

| 事件 | 必须读取 | 期望处理 |
| --- | --- | --- |
| `session_start` | `session_id`、`content`、`content_ref`、`tools` | 新会话记下真实 id。历史模式用 `content` 恢复 system prompt。`tools` 是冻结工具集，只做审计，不重算。 |
| `user_message` | `content` | 只在历史模式回显。实时模式的提示词由 UI 自己显示。 |
| `turn_start` | `turn` | 置为运行中，记录 turn 号。 |
| `message_start` | `message_id` | 清掉该消息的“已收到文本增量”标记。 |
| `message_update` | `message_id`、`delta.text`、`delta.tool_call.index`、`id`、`name`、`args_delta` | 文本按 `message_id` 累积。工具参数按 `index` 累积。`delta.reasoning` 可以不展示。 |
| `message_end` | `message_id`、`content` 的 `text`、`text_ref`、`text_preview` | 没收到文本增量时才用全文补齐。历史模式总用全文。 |
| `tool_execution_start` | `tool_call_id`、`name`、`args`、`args_ref`、`args_preview` | 建工具卡片。参数压成单行并截到约 240 字节。 |
| `tool_execution_update` | `tool_call_id`、`chunk` | 只在实时模式追加，典型是 `bash` 输出。不要截断。 |
| `tool_execution_end` | `tool_call_id`、`ok`、`content`、`content_ref`、`content_preview`、`error`、`duration_ms`、`exit_code` | 收尾工具卡片。结果预览截到 200 行或 20000 字节，并提示完整内容在 transcript。 |
| `error` | `scope`、`message`、`retryable` | 可重试显示为警告，否则显示为错误。 |
| `cancel` | `scope` | 显示“已取消”。后面可能还有收尾事件。 |
| `turn_end` | `stop_reason`、`usage` | 记录本 turn 的 stop reason。`stop_reason` 可能是 `stop`、`max_tokens`、`max_steps`、`cancelled`、`context_too_long`。`tool_use` 只出现在 `message_end`，不会出现在 `turn_end`。 |
| `session_end` | `reason`、`usage` | 记录 session 级结果。通常不直接展示。 |

解析事件时还有下面几条规则：

- 工具结果不单独成消息。工具卡片从 `tool_execution_end` 收尾，assistant 消息从 `message_end` 收尾。
- `tool_execution_start` 与 `tool_execution_end` 按 `tool_call_id` 配对。不要假设它们相邻。
- `bash` 非 0 退出仍是 `ok: true`，退出码放在 `exit_code`。只有无法执行、超时、取消或超硬上限才是 `ok: false`。
- usage 的五个字段是 `input_tokens`、`output_tokens`、`cached_tokens`、`reasoning_tokens`、`total_tokens`。字段缺失表示未知，不要用 0 冒充。
- `message_end.usage` 是单次响应，`turn_end.usage` 是本 turn 累加，`session_end.usage` 是整个 session 累加。
- 实时与历史重叠时按 `seq` 去重。`seq = 0` 的 `session_start` 要单独处理，不能只用 `seq <= lastSeq` 一刀切。
- assistant 文本可以走 Markdown。用户输入和工具输出必须转义，不要注入 HTML。

## 7. 管理 session 与历史

### 7.1 新建 session

1. 第一轮不传 `-s`。
2. 从本轮 `session_start.session_id` 捕获真实 id。
3. 后续轮次都带 `-s <真实 id>`。
4. 需要稳定标识时，先分配临时 slot key。收到 `session_start` 后把 slot key 别名到真实 id。订阅两者都应命中。

**结果**：新 session 落盘，下一轮能继续。旧 transcript 始终保留。

### 7.2 恢复 session

1. 传 `-s <id>`。`ap` 只在当前 project 内查找，找不到时退出 2 并打印期望路径。
2. 恢复以 transcript 为准。system prompt、model、provider、agent、cwd 和工具集来自冻结的 `session_start`。
3. 不要给恢复轮次传会与冻结值冲突的 `--model` 或 `--agent`。`ap` 会 warning 后忽略。
4. `--max-steps`、`--max-tokens`、`--output-format`、`--verbose` 和 `--config-dir` 恢复时照常生效。
5. 工具集以 `session_start.tools` 为准。冻结工具在当前注册表不存在时跳过并 warning。

**结果**：恢复轮次沿用原 session 的身份和上下文，只追加新事件。

### 7.3 继续最近的 session

1. 传 `-c`，让 `ap` 在当前 project 内选择最近修改的根 session。
2. 前端也可以自己定位最近根 session，再改用显式 `-s`。参考实现用 `find_latest_root_session`。
3. 子代理 session 的 `parent_session_id` 非空，不参与 `-c`。

**结果**：拿到最新根 session 的真实 id。

### 7.4 fork

1. 同时传 `--fork-session` 和 `-s` 或 `-c`。
2. 从本轮 `session_start` 捕获新 id。
3. 不要继续使用源 id。
4. blob 按 sha256 共享，事件复制到新 transcript。

**结果**：新 session 可独立追加，源 session 不受影响。

### 7.5 重放历史

历史只读 transcript，不重新调用模型，也不重新执行工具。目录布局是：

```text
<config-dir>/projects/<project_path_hash>/
  path.txt
  blobs/<sha256>
  <session_id>.jsonl
```

计算 `project_path_hash` 时逐项复刻下面的规则：

1. 把启动目录解析成绝对路径。
2. 清理 `.` 和 `..`。
3. 解析符号链接和 junction。
4. 把反斜杠统一成 `/`。
5. 去掉尾部分隔符，保留 Windows 盘符根和 POSIX 根。
6. Windows 上把整条路径转小写。
7. 对整个规范化路径做 FNV-1a 32 位 hash，输出 8 位小写 hex。
8. 检查 `path.txt` 中的规范化路径与当前路径一致。不一致视为冲突。

读取 JSONL 时遵守下面的规则：

1. 按文件行序读取。
2. 同一文件可能有多个 `session_start`，渲染以最后一个为准。
3. 解析失败的尾行直接跳过。崩溃留下的不完整行由 `ap` 下次启动时截掉。
4. `session_start.content_ref`、文本块的 `text_ref`、`tool_use` 的 `input_ref`、`tool_execution_start.args_ref`、`tool_execution_end.content_ref` 都要读对应的 blob。
5. 展示层缺少 blob 时可以退化为对应的 `*_preview`，并在 UI 标记，不要静默当成空内容。这是前端重放的降级规则。`ap` 自己恢复上下文时不做这种降级，blob 缺失直接退出 2。
6. 工具结果只展示 200 行或 20000 字节。完整内容仍在 transcript。
7. 有 `tool_execution_start` 没有 `tool_execution_end` 的工具调用可以保留“运行中”或“已中断”状态。不要伪造结果。

**结果**：重启或刷新后能从 transcript 重建与实时渲染一致的消息、工具卡片和错误提示。

## 8. 取消与并发

1. 同一 session 同一时刻只允许一个 turn。用锁原子地完成“检查 running、置 running”。重复请求返回 409 或提示忙。
2. 不同 session 可以同时运行。切换或恢复其他 session 不受正在运行的 session 影响。每个运行态记录自己的 `cwd` 和取消令牌。
3. 新会话在 `session_start` 之前只有 slot key。之后同时接受 slot key 和真实 id。
4. UI 刷新后按持久化的 `{session_id, cwd}` 恢复。临时 slot key 在进程重启后没有意义。
5. 取消是“设置令牌、终止进程树”，不是进程内控制协议。
6. Unix 上先向整棵进程树发 `SIGTERM`，约 2 秒后对同一快照发 `SIGKILL`。`ap` 收到信号后会尝试写完 `cancel`、`tool_execution_end(ok=false)`、`message_end(cancelled)`、`turn_end(cancelled)` 和 `session_end(reason=signal)`，然后以 143 退出。
7. Windows 上用 Job Object 的 `TerminateJobObject` 整树终止。`ap` 可能来不及写收尾事件。用户主动取消且没有 `turn_end` 时，前端填 `stop_reason = cancelled`，不要当成失败。
8. 取消只作用于目标 session。不要因为一个标签页取消就终止其他 session。
9. 不要用全局锁包住整个 turn。注册表和取消令牌用短临界区保护，turn 本体在独立线程或异步任务里跑。
10. 前端进程退出时，先标记 shutting down，拒绝新 turn，取消所有运行中的 turn，最多等待约 5 秒。
11. 不要复用进程。即使只再问一句，也要重新 spawn 并带 `-s`。

**结果**：取消一个 session 后，它的进程树消失，其他 session 继续运行。前端刷新后仍能从 transcript 恢复画面。

## 9. 验收清单

最小实现完成后，逐项跑下面的检查：

1. **假 agent**：用只输出固定 stream-json 的测试程序验证 spawn、参数、stdin EOF、逐行解析、退出码和 stderr 缓存。
2. **新会话**：第一轮不带 `-s`，从 `session_start` 捕获 id。第二轮带 `-s`，事件追加到同一个 transcript。
3. **单飞与并发**：同一 session 的第二个请求被拒。不同 session 能同时跑。取消只影响目标 session。
4. **取消**：Unix 上收尾事件齐全。Windows 上进程树被杀，前端合成 `cancelled`。
5. **历史**：重启后能从 transcript 重建消息、工具卡片和 blob 引用。重叠事件按 `seq` 去重。
6. **异常退出**：非 0 退出时展示 stderr 尾部。缺少 `turn_end` 时 `stop_reason` 回退正确。
7. **路径**：Windows 的大小写和分隔符变体落到同一个 project hash。跨目录使用 `-s` 失败并给出清晰提示。
8. **真实链路**：用本地 OpenAI 兼容端点跑一轮，确认文本增量、工具调用、`turn_end`、`session_end` 和 usage 都能落地。

**结果**：八项全部通过后，新前端满足进程边界的集成契约。

## 相关文档

- [cli-and-config.md](cli-and-config.md)：参数、配置、输出格式、退出码、存储布局
- [react-loop-and-session.md](react-loop-and-session.md)：完整事件 schema、turn 与 step、恢复与 fork
- [errors-and-cancellation.md](errors-and-cancellation.md)：错误分类、重试、取消与超时
- [tui.md](tui.md)：终端前端的进程模型与渲染
- [web.md](web.md)：HTTP/SSE 前端的 API 与并发
- [architecture.md](architecture.md)：模块职责、依赖方向、进程内 SDK
