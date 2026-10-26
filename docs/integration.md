# 集成 ap.exe 指南

本文说明如何把 `ap` 当成黑盒 agent 进程接入一个新前端。仓库里的 `ap-tui`（终端）和 `ap-web`（浏览器）是两份参考实现：两者都**不实现** agent、provider、工具或 transcript 写入，只在每一轮启动一次 `ap` 子进程，消费 `stream-json`，再把事件渲染到各自的界面。本文按「进程契约 → turn 生命周期 → 事件协议 → session 管理 → 取消与并发」的顺序，把这两份实现共同遵循的规则抽出来，作为新增前端的集成规范。

```
前端（任意语言 / 任意 UI）
  │
  ├── spawn ──► ap --print0 --output-format stream-json [-s <id>] ...   （每个 turn 一次）
  │                 │
  │   stdin  ◄──────┘  整条提示词，写完后关闭
  │   stdout ───────►  每行一个 JSON 事件（transcript + stream）
  │   stderr ───────►  人类可读日志
  │
  └── read  ──►  $AP_CONFIG/projects/<hash>/<session_id>.jsonl         （历史重放）
```

## 1. 不可变契约

1. **ap 是一次性 CLI**：一条提示词进，一个 turn 出，进程退出。没有 REPL、没有交互命令、没有进程内 API。
2. **每个 turn 一个新进程**。不要复用上一条 turn 的进程；需要继续对话时用 `-s <session_id>` 恢复。
3. **transcript 是唯一事实来源**。实时增量只用于展示；刷新、重连、重启后一律从 transcript 重建画面。
4. **前端不 import ap，也不重复实现 agent 逻辑**。依赖方向见 [architecture.md](architecture.md)：`ap-web → internal`，`ap-web` 不 import `ap` / `ap-tui`。
5. **只通过参数、stdin、stdout、stderr 交互**。不读 ap 的内存、不改 transcript、不代写事件。
6. **传输层自由**：终端可以直接写 stdout；Web 可以把事件转成 SSE；编辑器插件可以转成自己的消息总线。事件 schema 不变。

同一份 `internal/` 提供路径规范化、project hash、session 发现、blob 读取、事件信封与平台原语。同仓库的新前端应直接引用；外部仓库的实现必须逐字节复刻第 5.5 节的路径规则，否则找不到 transcript。

## 2. 进程启动

### 2.1 查找可执行文件

推荐顺序（与 `ap-tui`、`ap-web` 完全一致）：

1. 用户显式配置的 `--agent-bin <path>`
2. 环境变量 `AP_AGENT_BIN`，其次 `AP_BIN`
3. 前端自身可执行文件同目录的 `ap.exe`（Unix 为 `ap`）
4. `PATH` 中的 `ap`

细节：

- `--agent-bin` 的值含路径分隔符时按路径解析并规范化；否则当作命令名查 `PATH`。显式路径必须存在。
- 查找时必须确认是**普通文件**：仓库里源码目录 `ap/` 与 Unix 二进制 `ap` 同名，只判断存在会把目录当成可执行文件。
- Windows 上候选名带 `.exe`，`PATH` 查找也先试无扩展名、再试 `.exe`。
- 找不到时前端自行报错并以非 0 退出（参考实现用退出码 2）；不要让 ap 在错误路径上启动。

### 2.2 命令行

```
ap --print0 --output-format stream-json [-s <session_id>] \
   [--model <id>] [--agent <name>] [--max-steps <n>] [--max-tokens <n>] \
   --config-dir <dir> [--verbose]
```

| 参数 | 何时传 | 说明 |
| --- | --- | --- |
| `--print0` | 必传 | 从 fd 0 读取提示词直到 EOF；不要用 `--print` 传长提示词 |
| `--output-format stream-json` | 必传 | 每行一个事件 |
| `-s <session_id>` | 已有 session | 新会话第一轮**不要**传；之后每轮都传 |
| `--config-dir <dir>` | 建议总是传 | 让前端展示/重放的目录与 ap 实际读写的 `$AP_CONFIG` 一致 |
| `--model` / `--agent` / `--max-steps` / `--max-tokens` | 可选透传 | 前端只做白名单映射；恢复 session 时 model/agent 可能与冻结值冲突并被忽略（见 5.2） |
| `--verbose` | 可选 | 让 ap 把更多日志写到 stderr；`ap-tui` 用它实时展示，`ap-web` 不用 |
| `-c` | 启动时可选 | 让 ap 自己找当前项目最近的根 session；前端也可自行定位后改用 `-s` |
| `--fork-session` | 可选 | 必须与 `-s` / `-c` 连用；fork 的新 id 从 `session_start` 捕获 |

规则：

- 参数以**数组**传给 `process_start` / `execve`，不经过 shell，不拼接字符串。
- `session_key`、`cwd`、UI 状态等前端概念不传给 ap；ap 只认第 2.2 节的 CLI 参数。
- 提示词只走 stdin；`--print0` 是「0 = stdin」，不是 NUL 分隔。
- 恢复时 `-s` / `-c` 互斥；`--fork-session` 必须与其中之一连用。

### 2.3 工作目录

- 子进程的 `working_dir` 设为该 session 所属 project 的根目录（通常是启动目录或用户选择的工作目录）。
- ap 以**启动目录**识别 project：`-s` / `-c` 只在当前项目里查找 transcript。在另一个目录启动就找不到原 session。
- 每个 session 各自记住自己的 `cwd`；**不要**为了切换目录去改前端进程的 cwd，否则并发 session 会互相干扰。`ap-web` 的做法是 `Session_Runtime.cwd` + 启动子进程时传入。
- 目录必须是绝对路径；前端负责校验存在性，ap 也会在启动失败时给出错误。

### 2.4 三个流

| 流 | 方向 | 内容 | 前端处理 |
| --- | --- | --- | --- |
| stdin | 前端 → ap | 整条提示词（UTF-8） | 写完立即关闭写端，EOF 是「输入结束」信号 |
| stdout | ap → 前端 | 每行一个 JSON 事件 | 逐行解析，实时展示；**不要**重定向到 stderr |
| stderr | ap → 前端 | 人类可读日志、最终 `${exe} -s ${session_id}` 提示 | 正常退出可忽略；异常退出时缓存尾部用于展示 |

- **stdin 必须关闭**。OS 管道写端没关，ap 会一直等 EOF，turn 永远不开始。Windows 上还要清理句柄继承（见 2.6）。
- 提示词是一次性输入，不按行分帧；空提示词应在 UI 层拦截（ap 会把空内容视为用法错误）。
- stdout 只放事件，任何调试输出都会破坏行协议。
- stderr 建议保留**尾部窗口**（参考实现保留 64 KiB，超出时截到约 32 KiB 并对齐整行）；只在退出码非 0 时展示，避免正常运行时打扰用户。
- `--verbose` 时 stderr 可实时展示；非 verbose 时缓存即可。
- ap 在退出前会向 stderr 打一行 `<可执行文件> -s <session_id>`，便于日志里复制继续命令；前端可以选择展示或忽略。

### 2.5 退出码

| 码 | 含义 | 前端建议 |
| --- | --- | --- |
| 0 | 正常结束（含 `max_steps` / `max_tokens`，具体看 `stop_reason`） | 释放运行态 |
| 1 | 内部错误（transcript 写入、序列化失败等） | 展示 stderr 尾部 |
| 2 | 用法/配置错误、session 不存在、blob 损坏 | 展示错误，提示检查参数或目录 |
| 3 | provider 错误、重试耗尽、`context_too_long` | 展示错误；可提示重试或换模型 |
| 4 | 工具基础设施故障 | 展示错误 |
| 130 | SIGINT 中断 | 显示「已中断」 |
| 143 | SIGTERM 中断 | 显示「已中断」 |

退出码 0 不代表「模型正常说完」：`max_steps` / `max_tokens` 也会以 0 退出，必须看 `turn_end.stop_reason`。更完整的错误分类见 [errors-and-cancellation.md](errors-and-cancellation.md)。

### 2.6 Windows：管道继承

Windows 上 `os.pipe` 两端默认都可继承。启动子进程前必须清掉**前端自己保留的那三端**的继承标志：

- stdin 管道的**写端**
- stdout 管道的**读端**
- stderr 管道的**读端**

否则 ap 会继承 stdin 写端，读 stdin 时永远等不到 EOF；或者前端读不到 EOF，turn 结束后仍然挂着。参考实现见 `ap-tui/agent.odin` / `ap-web/agent.odin` 中的 `mark_non_inheritable` 与 `platform_windows.odin`。外部语言实现要使用等价机制（`SetHandleInformation(HANDLE_FLAG_INHERIT)` 清除继承位，或显式 `bInheritHandles=false` + 只把子进程需要的三端设为可继承）。

## 3. 一轮 turn 的生命周期

1. **抢占该 session 的运行态**：同一 session 已有 turn 在跑时拒绝（HTTP 前端返回 409，终端前端提示忙），不同 session 可以并发。
2. **检查取消令牌**：若在 spawn 之前已取消，直接返回，不启动进程。
3. **创建三个管道并 spawn ap**：stdin/stdout/stderr；`working_dir` 为该 session 的 cwd。
4. **关闭子进程端**：父进程关闭 stdin 读端、stdout 写端、stderr 写端。
5. **写提示词并关闭 stdin 写端**：关闭即 EOF。
6. **同时泵 stdout 与 stderr**：非阻塞/短轮询读取，stdout 走行读取器，stderr 走日志缓存。不要先等 stdout 读完再读 stderr，两者都可能写满管道。
7. **逐行解析 stdout**：`session_start` 出现时记下真实 `session_id`，并把前端的临时 key（如 `web_new_1`）别名到它。
8. **等待直接子进程退出**：每轮检查 `process_wait`；收到取消令牌时终止整棵进程树。
9. **直接子进程退出后只排空当前可读数据**：不要等后台后代释放管道。`bash` 可能留下持有 stdout/stderr 写端的后台进程，等它们会永远不返回。
10. **发结束信封**：`exit_code`、`stop_reason`、`usage`、`stderr_preview`；释放运行态与取消令牌。
11. **保留 transcript**：下一轮用 `-s <真实 id>` 恢复。

伪代码：

```text
run_turn(prompt, session):
    if session.cancelled: return
    spawn ap(args, cwd=session.cwd, pipes)
    close_child_ends()
    write_all(stdin_w, prompt); close(stdin_w)

    while child_running or pipes_open:
        drain(stdout_r) -> line_reader -> parse_event -> on_event
        drain(stderr_r) -> log_tail
        if cancel_requested:
            kill_process_tree(child); wait <=3s; force_kill; wait <=3s
        else:
            wait(child, 10ms)
        if child_exited:
            drain_available_without_waiting_for_descendants()
            break
        sleep(5ms)

    flush(line_reader)
    on_turn_done(exit_code, last_stop_reason, usage, stderr_tail)
    release_session()
```

关键点：

- `session_id` 由 `session_start` 产生，**不能**在前端预先编造。新会话第一轮必须允许「还没有真实 id」的状态。
- 取消令牌在每轮开始时清零；否则「取消后立刻开新 turn」会继承旧状态。
- `turn_end` 不一定存在（provider 重试耗尽、工具基础设施故障、Windows 强杀等）。`stop_reason` 的回退顺序是：`turn_end.stop_reason` → `session_end.reason` → 主动取消时填 `cancelled` → null。
- 用户断开 UI（关闭页面、SSE 断线）**不应**取消 turn；turn 应继续跑完并写 transcript，客户端重连后从历史恢复。

## 4. 事件协议

完整 schema 见 [react-loop-and-session.md](react-loop-and-session.md)。本节只列集成方必须实现的读取规则。

### 4.1 两类事件

| 类别 | 落盘 | 字段 | 用途 |
| --- | --- | --- | --- |
| transcript event | 是 | `v` / `seq` / `ts` / `type` + 业务字段 | 恢复、重放、审计 |
| stream event | 否 | `type` / `ts` + 业务字段，**没有 `seq`** | 实时展示（文本增量、工具增量） |

- `v` 固定为 1；未知 `type` 必须跳过；已知类型遇到更高的 `v` 应明确报错，不能猜测。
- 字段缺失与 `null` 等价（序列化会省略空字段）。
- `seq` 在单个 session 内从 0 单调递增，是排序与去重依据；stream 事件没有 `seq`，顺序由 stdout 行序保证。

### 4.2 行解析

```text
feed(bytes) -> append buffer -> while '\n' in buffer:
    line = buffer up to '\n'
    parse_event_line(line)     // 空行 / 非 JSON / 缺 type -> 静默跳过
at exit: flush remaining bytes as one last line
```

- 按字节切行，不要先做 UTF-8 解码；`\n` 一定落在 ASCII 边界，整行再交给 JSON 解析，多字节字符不会被切断。
- 行尾的 `\r` 去掉。
- JSON 解析要**忽略未知字段**，便于 ap 后续加字段时旧前端仍能工作。
- 如果要把事件原样转发给另一个消费者（例如 SSE），**保留原始行**，不要用结构体重新序列化：重新序列化会丢掉未知字段。`ap-web` 的 `Turn_Callbacks.on_event_line` 就是为此存在的。
- 行读取器每次消费后压实缓冲，避免长 turn 无界增长；进程退出时把最后没有换行结尾的残余也交给解析器。

### 4.3 渲染语义

| 事件 | 必须做的事 |
| --- | --- |
| `session_start` | 记录 `session_id`（新会话的关键）；历史模式下 `content_ref` 解析 blob，`content` 作为 system prompt，通常不展示 |
| `user_message` | 只在历史模式展示（实时模式下提示词由 UI 自己回显，避免重复） |
| `turn_start` | 标记 running，记录 `turn` |
| `message_start` | 重置该 `message_id` 的「已收到文本增量」标志 |
| `message_update` | `delta.text` 按 `message_id` 累积；`delta.reasoning` 可忽略（phase 1 不展示）；`delta.tool_call` 按 `index` 累积，`id` 可能只在第一个片段出现 |
| `message_end` | 仅当该消息**没有**收到过文本增量时，才用 `content` 里的 text 块补齐；历史模式总是取全文。`content` 里的 `text_ref` / `input_ref` 需解析 blob，缺失时退化为 `*_preview` |
| `tool_execution_start` | 建工具卡片：名称 + 参数；`args` 超阈值时为空，改用 `args_ref`（解析 blob）或 `args_preview`；参数展示建议截断到约 240 字符并压成单行 |
| `tool_execution_update` | 只在实时模式追加 `chunk`（典型是 `bash` 输出），不要截断 |
| `tool_execution_end` | 标记 ✓/✗、耗时、`exit_code`、`error`；`content_ref` 解析 blob，`content` 为空且只有引用时不能当空结果。非流式结果预览截断到 200 行 / 20000 字节，并提示完整内容在 transcript |
| `error` | `retryable=true` 显示为警告，否则为错误；`scope` 可用于分类 |
| `cancel` | 显示「已取消」；随后可能还有 `tool_execution_end(ok=false)`、`message_end(cancelled)`、`turn_end(cancelled)` |
| `turn_end` | 记录 `stop_reason`；除 `stop` 外可提示「turn ended: …」 |
| `session_end` | 记录 `reason` 与全 session 累计 usage；通常不直接展示 |
| `step_start` / `message_start` 等 | 不直接展示 |
| 未知类型 | 跳过 |

其他约定：

- tool result 不单独成消息；工具卡片从 `tool_execution_end` 收尾，消息从 `message_end` 收尾。
- `tool_execution_start` 与 `tool_execution_end` 按 `tool_call_id` 配对，**不要假设相邻**。
- `bash` 非 0 退出仍是 `ok: true`（带 `exit_code`）；只有无法执行、超时、取消、超硬上限才是 `ok: false`。
- assistant 文本可以走 Markdown；用户输入与工具输出必须转义（`textContent` 或等价机制），不要注入 HTML。
- 实时与历史重叠时按 `seq` 去重（只对带 `seq` 的事件）。`seq = 0` 的 `session_start` 特殊：要么把 `session_start` 做成幂等（以最后一个为准），要么单独处理，不能简单用 `seq <= lastSeq` 一刀切。

### 4.4 stop_reason 与 usage

`turn_end.stop_reason`：`stop` / `max_tokens` / `max_steps` / `cancelled` / `context_too_long`。

`usage` 的五个字段都可能缺失：

```js
{input_tokens, output_tokens, cached_tokens, reasoning_tokens, total_tokens}
```

- 缺失表示未知，**不要用 0 冒充**。
- `message_end.usage` 是单次响应；`turn_end.usage` 是本 turn 累加；`session_end.usage` 是整个 session 的累计。
- 取消、provider 最终失败等路径可能拿到全 null 的 usage。

## 5. Session 管理

### 5.1 新 session

- 第一轮**不传 `-s`**；ap 创建新 session。
- 从本轮 `session_start.session_id` 捕获真实 id，后续轮次都带 `-s`。
- 如果前端需要在本轮开始前就有一个可订阅/可取消的稳定标识，先分配一个临时 slot key（`ap-web` 用 `web_new_<n>`），收到 `session_start` 后把 slot key 别名到真实 id；订阅两者都应命中。
- `/new`（ap-tui）或「新会话」按钮（ap-web）只是丢弃当前 id；旧 transcript 仍留在磁盘。

### 5.2 恢复

- `-s <id>`：恢复当前项目内的指定 session；找不到时 ap 退出 2 并打印期望路径。
- 恢复以 transcript 为准，`session_start` 中冻结的 system prompt、model、provider、agent_name、agent_depth、cwd **不重算**。
- 以下参数与冻结值冲突时，ap 在 stderr 打 warning 并忽略（退出码不受影响）：`--model`、`--agent`、`--append-system-prompt`、父子关联参数。
- 以下参数恢复时照常生效：`--max-steps`、`--max-tokens`、`--output-format`、`--verbose`、提示词来源、`--fork-session`、`--config-dir`。
- 前端切换 session 时**不要**因为另一个 session 正在跑而拒绝；单飞约束只在同一 session 上。

### 5.3 继续

- `-c`：让 ap 在当前项目内选择最近修改的根 session（最后一个 `session_start` 的 `parent_session_id` 为 null）。
- 前端也可以在启动时自己定位最近根 session，再用显式 `-s`；`ap-tui` 和 `ap-web` 都这样做（`find_latest_root_session`）。
- 子代理 session 的 `parent_session_id` 非空，不参与 `-c`。

### 5.4 fork

- `--fork-session` 必须与 `-s` / `-c` 连用：生成新 session id，复制全部事件到同项目目录的新文件，追加一条新的 `session_start`（`resumed_from` 指向源），blob 按 sha256 共享。
- 前端必须从本轮 `session_start` 捕获**新** id；不要继续使用源 id。
- `ap-tui` / `ap-web` 目前没有 fork 入口；新增前端可自行暴露。

### 5.5 历史重放

历史只读 transcript，不重新调用模型、不重新执行工具：

```text
$AP_CONFIG/projects/<project_path_hash>/
  path.txt
  blobs/<sha256>
  <session_id>.jsonl
```

project 识别规则（必须与 ap 完全一致）：

1. 以启动目录为项目根，解析为绝对路径
2. `os.clean_path` 清理 `.` / `..`
3. 解析符号链接 / junction（ap 写 transcript 时用真实路径）
4. 反斜杠统一成 `/`
5. 去掉尾部分隔符（保留 Windows 盘符根与 POSIX 根）
6. Windows 上整条路径转小写
7. `project_path_hash = fnv32a(规范化路径)`，取 8 位小写 hex
8. 目录下的 `path.txt` 存规范化路径；内容与当前路径不一致视为冲突

读取：

- 逐行读 JSONL，按文件行序（正常写入下即 `seq` 递增）。
- 同一个文件可能有多个 `session_start`（每次恢复追加一条），渲染以**最后一个**为准。
- 不完整尾行可能来自崩溃；解析失败直接跳过（ap 下次启动会截掉）。
- 大字段按引用解析：
  - `session_start.content_ref` → system prompt
  - `message_end` 文本块的 `text_ref`、`tool_use` 的 `input_ref`
  - `tool_execution_start.args_ref`
  - `tool_execution_end.content_ref`
  - 缺失 blob 时退化为对应的 `*_preview`，并在 UI 上标记；不要静默当空。
- 工具结果展示截断到 200 行 / 20000 字节（与实时结束事件一致），完整内容仍在 transcript。
- 未闭合的 tool call（有 `tool_execution_start` 没有 `tool_execution_end`）在展示时可以保留「运行中/中断」状态；不要伪造结果。

`ap-web` 的 `GET /api/history` 会逐行读 transcript，并把上述引用解析成前端可直接渲染的字段；`ap-tui` 的 `replay_session` 直接复用同一套 `Event` 结构和渲染器。

### 5.6 多 session

- 每个 session 一条运行态记录：`key`（临时 slot 或真实 id）、`session_id`、`cwd`、`running`、`turn`、取消令牌。
- 列表/切换只用 `running` 阻止**同一 session** 重复发送；不同 session 可以同时跑。
- UI 刷新后：优先按持久化的 `{session_id, cwd}` 恢复；临时 slot key 在进程重启后无意义。
- 侧栏按 cwd 分组时，枚举 `$AP_CONFIG/projects/*/path.txt`，忽略 `path.txt` 与目录 hash 对不上的条目。

## 6. 取消、并发与生命周期

### 6.1 取消

- 取消是**异步令牌 + 终止进程树**，不是「向后端发一个 cancel 协议」。ap 没有进程内控制通道（除了信号）。
- Unix：向整棵进程树发送 `SIGTERM`，等待约 2 秒后对同一快照发 `SIGKILL`。ap 收到 SIGTERM 后会自己写 `cancel` → `tool_execution_end(ok=false)`（若有）→ `message_end(cancelled)`（若正在流式）→ `turn_end(cancelled)` → `session_end(reason=signal)`，退出码 143。
- Windows：用 Job Object 的 `TerminateJobObject` 整树终止。这会让 ap 来不及写收尾事件，transcript 可能停在 `tool_execution_start`；前端应把「用户主动取消但没有 `turn_end`」合成为 `stop_reason = cancelled`，而不是当成失败。
- 取消只作用于一个 session；不要因为某个标签页取消就终止其他 session 的 turn。
- 前端进程退出时：标记 shutting down，取消所有运行中的 turn，最多等待约 5 秒，再清理线程/资源。关停期间新 turn 应被拒绝（`ap-web` 返回 503）。
- 终端前端（`ap-tui` phase 1）不拦截 Ctrl+C：信号同时发给 TUI 与 ap，TUI 退出，ap 自行取消并写 `session_end`，下次 `-c` 恢复。

### 6.2 并发

- **单 session 单飞**：同一 session 同一时刻只允许一个 ap 子进程。用锁原子地「检查 running → 置 running」；重复请求返回 409 / 提示忙。
- **跨 session 并发**：不同 session 可以同时跑；每个运行态记录自己的 `cwd`，spawn 时使用它。
- **session key 别名**：新会话在 `session_start` 之前只有 slot key；`session_start` 后同时接受 slot key 与真实 id，保证已订阅的客户端继续收到事件。
- **锁粒度**：不要用全局锁包住整个 turn。注册表/取消令牌用短临界区保护，turn 本体在独立线程或异步任务里跑。
- **SSE/连接断开不取消 turn**；客户端重连后走 history + 重新订阅，按 `seq` 去重补齐。
- **不要复用进程**：即使只是再问一句，也要重新 spawn 并带 `-s`。ap 的契约是一进程一 turn。

## 7. 参考实现映射

| 关注点 | ap-tui | ap-web |
| --- | --- | --- |
| 可执行文件查找 | `agent.odin` `resolve_agent_bin` | `agent.odin` `resolve_agent_bin` |
| 命令行构造 | `agent.odin` `build_agent_command` | `agent.odin` `build_agent_command` |
| 管道 + 行读取 + 事件泵 | `agent.odin` `run_agent_turn` | `agent.odin` `pump_agent` |
| 事件结构与解析 | `events.odin` `parse_event_line` | `events.odin` `parse_event_line` |
| 渲染 | `render.odin` | `frontend/render.js` + `frontend/store.js` |
| 历史重放 | `agent.odin` `replay_session` + `render.odin` `.History` | `api.odin` `api_history` + `frontend/store.js` `ingestHistory` |
| 路径 / project / blob | `project.odin` 转发 `internal` | `project.odin` 转发 `internal` |
| session 指针 | `main.odin` `App.session_id` | `runner.odin` `Session_Runtime` |
| 传输层 | 直接写 stdout | `server.odin` + `sse.odin` + `api.odin` |
| 取消 | 依赖终端 Ctrl+C | `runner_cancel` + `DELETE /api/turn` + `process_platform_*` |
| 单飞 / 并发 | 单活动 session，天然串行 | `runner.odin` 按 session 锁 |
| 工作目录选择 | 启动目录 | `pickdir.odin`（Windows IFileDialog，Unix 501） |

如果要做 HTTP/SSE 前端，直接参照 [web.md](web.md) 的 API 表：

- `POST /api/turn` → spawn 一轮；`session_key` 定位运行态，`cwd` 定位 project
- `GET /api/events?session_key=<key>` → SSE 直转发 ap 的原始事件行（`event: ap`），另发 `turn_done` 信封与 `ping`
- `GET /api/history?session_id=<id>&cwd=<dir>` → transcript 重放并解析 blob
- `DELETE /api/turn?session_key=<key>` → 置取消令牌并终止进程树
- `POST /api/session/new` / `POST /api/session/resume` → 分配 slot / 注册已有 session，不启动进程

## 8. 非 Odin 实现的注意事项

外部语言没有 `internal/` 可用，以下规则必须自己复刻：

1. **路径**：绝对化 → 清理 → 解析链接 → 反斜杠转 `/` → 去尾斜杠 → Windows 小写 → FNV-1a 32 位 hex。任何一步不同都会落到不同 project 目录。
2. **配置目录**：`--config-dir` 优先，其次 `AP_CONFIG`，最后 `~/.ap`；只用于定位 transcript，前端不需要读 `settings.json`。
3. **进程创建**：参数数组、`cwd`、三个管道；不经过 shell。
4. **Windows**：清理管道继承标志；用 Job Object 终止进程树；路径用宽字符 API；控制台输出前设置 UTF-8 code page。
5. **事件 JSON**：宽松解析、保留原始行、未知字段不报错、未知类型跳过。
6. **密钥**：不要把 `AP_API_KEY` 写进日志、transcript 或前端可下载的静态资源；ap 自己在执行 `bash` 时会剔除它。
7. **版本**：固定 Odin/二进制版本；事件 schema 以 `v` 为准，不要依赖未写入文档的字段。

## 9. 常见错误

1. 用 `--print` 传长提示词，撞上命令行长度/编码限制；正确做法是 `--print0` + stdin。
2. 写完提示词不关 stdin 写端，ap 等不到 EOF。
3. 把 stderr 合并进 stdout，或让 ap 的普通日志混进事件流。
4. 按行解析前就做 UTF-8 解码，跨块切断多字节字符。
5. 等 stdout 读到 EOF 才开始展示；正确做法是逐行实时处理。
6. 直接子进程退出后继续等后台后代释放管道，turn 永远不结束。
7. 后续轮次忘记带 `-s`，每轮都新建 session。
8. 在第一轮 `session_start` 之前就假设真实 `session_id` 存在。
9. 用错误的 cwd 恢复 session，或者从子目录启动。
10. 自己重新序列化 JSON 再转发，丢掉 ap 新增字段。
11. 把 `bash` 的非 0 退出当成工具失败（它是 `ok: true` + `exit_code`）。
12. 把缺失的 usage 当成 0。
13. 用 `seq` 给 stream 事件排序/去重（它们没有 `seq`）。
14. `message_end` 无条件覆盖已流式累积的文本，界面重复。
15. 只杀 ap 进程，不杀进程树，留下工具子进程。
16. 同一 session 并发起两个 turn。
17. 浏览器断开 / UI 关闭时取消 turn，导致 transcript 半截。
18. 假设每个 turn 都有 `turn_end` 或每个进程都有 `session_end`（Windows 强杀、provider 失败都可能没有）。
19. 假设 `tool_execution_start` 与 `tool_execution_end` 相邻。
20. 在 Windows 上没清管道继承标志，进程挂死。

## 10. 验收清单

最小实现完成后，至少覆盖以下测试：

1. **假 agent**：写一个只按提示词输出固定 stream-json 的测试可执行文件（参考 `ap-web/testdata/fake_agent/main.odin`），验证 spawn、参数、stdin/EOF、逐行解析、退出码、stderr 缓存。
2. **新会话**：第一轮无 `-s`，从 `session_start` 捕获 id，第二轮带 `-s` 且落到同一 transcript。
3. **单飞与并发**：同一 session 第二个请求被拒；不同 session 同时跑；取消只影响目标 session。
4. **取消**：Unix 验证收尾事件齐全；Windows 验证进程树被杀、前端合成 `cancelled`。
5. **历史**：重启后能从 transcript 重建消息、工具卡片、blob 引用与截断提示；重叠事件按 `seq` 去重。
6. **异常退出**：非 0 退出时展示 stderr 尾部；`turn_end` 缺失时 stop_reason 回退正确。
7. **路径**：Windows 大小写/分隔符变体落到同一 project hash；跨目录 `-s` 失败并给出清晰提示。
8. **真模型 e2e**：用本地 OpenAI 兼容端点跑一轮，确认文本增量、工具调用、`turn_end`、`session_end` 与 usage 都能落地。

## 11. 相关文档

- [cli-and-config.md](cli-and-config.md)：CLI 参数、输出格式、退出码、配置、工作区布局、项目识别
- [react-loop-and-session.md](react-loop-and-session.md)：事件 schema、stream 事件、恢复与 fork
- [tui.md](tui.md)：终端前端的进程模型、历史重放、渲染
- [web.md](web.md)：HTTP/SSE 前端的 API、SSE、并发、目录选择
- [architecture.md](architecture.md)：依赖方向、`internal/` 边界、平台原语
- [errors-and-cancellation.md](errors-and-cancellation.md)：中断、超时、错误分类
