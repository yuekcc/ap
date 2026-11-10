# 错误、重试与取消

本文件定义失败分类、LLM 重试边界、工具失败语义、信号取消、超时、落盘与退出码映射。完整事件 schema 见 [react-loop-and-session.md](react-loop-and-session.md)，provider 的状态码映射见 [provider.md](provider.md)，`context_too_long` 的终止流程见 [context-management.md](context-management.md)。诊断日志的路径、级别与格式见 [cli-and-config.md](cli-and-config.md)。

## 错误分层

引擎用两种错误类型。

- `Error_Kind`：`None`、`Usage`、`Internal`、`Provider`、`Tool`。它决定 turn 结果和退出码。
- `Provider_Error`：带 `kind`、`message`、`retryable`、`retry_after_ms`。它决定 LLM 是否重试，以及 `error.kind` 的文本。

工具失败走 `Tool_Result`。普通工具失败是给模型的输入，不终止循环。

| 类别 | 例子 | 处理 | 落盘 |
| --- | --- | --- | --- |
| 用法、配置或恢复输入 | 参数非法、模型或 api_key 缺失、`$AP_CONFIG` 不可写、找不到 bash、session 不存在、transcript 损坏 | 启动或打开 session 时退出 | stderr 与日志，无新 transcript 事件 |
| provider | 网络失败、超时、429、5xx、鉴权失败、协议错误 | 按 `retryable` 重试或终止 | `error(scope=llm)` |
| 上下文组装 | blob 缺失、blob 损坏、参数 JSON 非法 | 终止 turn | `error(scope=session)`，无 `turn_end` |
| 工具基础设施 | 无法 spawn shell、管道或 wait 失败、工具参数 blob 写入失败 | 终止 turn | `error(scope=tool)` 或 `error(scope=session)`，无 `turn_end` |
| 普通工具失败 | 路径不存在、edit 未匹配、bash 超时、输出超限 | 作为 tool result 返回 | `tool_execution_end(ok=false)` |
| transcript 写入 | 磁盘满、序列化失败、flush 失败 | 无法继续可靠落盘 | 尽力写 `error(scope=session)` |
| 信号 | SIGINT、SIGTERM、Ctrl+C | 取消当前 step 或 turn | `cancel`、`turn_end` 等后续事件 |

## LLM 重试

Loop 只看 `Provider_Error.retryable`，不重新按 kind 分类。Provider 把以下失败标为可重试：HTTP 429 的 `rate_limit`、`server_error`、`network`、`timeout`，以及 `[DONE]` 前的流提前结束。SSE 流内嵌的 `rate_limit` 与 `invalid_request` 不重试。鉴权失败、模型不存在、参数错误、`context_too_long`、协议错误与取消都不可重试。

1. `MAX_LLM_RETRIES` 为 5。首次调用算 attempt 1。`attempt` 为 1 到 5 时可再重试，最多共 6 次调用。
2. 退避延迟是 `1000 * 2^(attempt-1)` 毫秒，上限 16000 毫秒。再加 0 到 250 毫秒抖动。
3. HTTP 头带 `Retry-After` 时，直接用它覆盖延迟，不再加抖动，也不受 16000 毫秒上限约束。
4. 退避用阻塞 sleep。取消标志在 sleep 期间不会打断等待。sleep 结束后，下一次 provider 调用会立即看到取消。
5. 每次失败都写一条 `error(scope=llm)`。可重试失败在 `attempt` 为 1 到 5 时继续下一次，第 6 次失败后停止。最终那次的 `retryable` 仍可能为 true。
6. 重试不写新的 `step_start`，不增加 step，也不影响 `max_steps`。
7. 已经收到的文本在重试时作废。废弃的尝试不写 `message_end`，可能留下没有结束的 `message_start`，投影时忽略。stderr 会提示该段文本已作废。
8. 丢弃的文本不进入下一轮上下文。`last_text` 只在成功的 `message_end` 时更新。

重试耗尽或遇到不可重试错误时，Loop 返回 `.Provider`，不写 `turn_end`。`ap-cli` 写 `session_end(reason=error)`，退出 3。最后一次失败已在前一步落盘。

## 上下文超限

`context_too_long` 不进入上述重试循环。预算关闭（`context_window_tokens = 0`）、`--no-handoff` 或 `agent_depth > 0` 时行为不变：Loop 写专用 `error` 与 `turn_end(context_too_long)`，退出 3。

开启自动交接时有两级纠正：

1. 第一次收到 `context_too_long`：把预算水位收紧到目标的一半，重新省略投影并重发同一个 step。不写 `error`、不增加 step、不写 `turn_end`，只在 stderr 写一行 `[context] provider rejected request as too long; recomputing with tighter budget`。
2. 第二次仍超限：生成交接文档，`turn_end.stop_reason` 为 `handoff`，退出 0。

交接调用本身失败（provider 错误、没有 `message_end`、正文为空）时退回第一段的行为：写 `error(scope=llm, kind=<原错误>, message="handoff failed: ...")`、`turn_end(context_too_long)`、退出 3。交接只尝试一次，不重试。

完整决策顺序、阈值与事件顺序见 [context-management.md](context-management.md)。

## 工具失败

普通失败写入 `tool_execution_end(ok=false)`，循环继续。包括参数错误、路径不存在、文件非 UTF-8、图片超过 `image_max_bytes`、edit 未匹配、bash 超时、输出超过 `max_capture_bytes` 与工具结果 blob 写入失败。各工具的具体文本与范围见 [tools.md](tools.md)。

`read_file` 请求超过 2000 行时截断并正常返回。bash 非 0 退出仍是 `ok=true`，`exit_code` 保留真实退出码。两者都不是失败。工具取消走信号取消路径，见下文。

以下情况是 fatal，会终止 turn：

1. `bash` 无法启动子进程。
2. `bash` 的管道读取或 wait 失败。
3. `task` 无法启动子代理，或子代理进程的管道与 wait 失败。
4. 工具参数需要写 blob 但写入失败。

前三种由工具结果带 `fatal=true`。Loop 写本工具的 `tool_execution_end`，再写 `error(scope=tool)`，然后返回 `.Tool`。同一 step 中尚未执行的 tool call 被跳过，没有 start 与 end。该路径不写 `turn_end`，`ap-cli` 写 `session_end(reason=error)`，退出 4。

工具参数 blob 写入失败发生在 `tool_execution_start` 之前。Loop 写 `error(scope=session)`，跳过本次及本 step 剩余工具，返回 `.Tool`。

工具结果 blob 写入失败不是 fatal。`tool_execution_end` 写 `ok=false` 与 `error="failed to persist output blob"`，循环继续。图片 blob 写入失败同理，错误为 `failed to persist image blob`。

bash 超时与输出超限会先终止整棵进程树，再返回 `ok=false`。没有“连续失败 N 次熔断”，收敛依靠 `max_steps` 与模型自身判断。

## 信号与取消

`ap` 没有交互式取消入口，取消只来自信号。Unix 注册 SIGINT 与 SIGTERM。Windows 注册 Ctrl+C 与 Ctrl+Break。信号处理器只写原子取消标志和退出码，不调用普通过程，也不直接操作 curl。

| 输入 | 行为 |
| --- | --- |
| 第一次 SIGINT 或 Ctrl+C | 置取消标志，记录 130 |
| 第一次 SIGTERM | 置取消标志，记录 143 |
| 1 秒内第二次 SIGINT | 直接退出，退出码 130，不再写事件 |
| 1 秒内第二次 SIGTERM | 直接退出，退出码 143 |
| `kill -9`、`TerminateProcess`、断电 | 无法捕获，按异常退出处理 |

取消通过 `Cancel_Token` 传播。

1. `provider_stream` 的进度回调看到标志后返回非 0，libcurl 中止请求。
2. `run_child` 的轮询看到标志后终止进程树。bash 与 task 共用这条路径。
3. 子代理是独立 `ap` 进程。父进程终止它的进程树，不等待它自己写完 `session_end`。
4. Unix 先按 PPid 递归收集后代，发送 SIGTERM，2 秒后对同一快照发送 SIGKILL。Windows 优先 `TerminateJobObject`，失败时 `taskkill /T /F`。
5. 已经产生的副作用不回滚。写了一半的文件、执行过的命令、残留的 blob 临时文件都按实际状态保留。

取消的事件顺序取决于发生位置：

- LLM 调用中：`cancel(scope=step)`，若已有消息则写 `message_end(stop_reason=cancelled)`，再写 `turn_end(cancelled)`。
- 工具执行中：`cancel(scope=step)`，再写 `tool_execution_end(ok=false, error="cancelled", content=null)`，再写 `turn_end(cancelled)`。已收到的工具部分输出丢弃。
- step 之间：`cancel(scope=turn)`，必要时写 `message_end(cancelled)`，再写 `turn_end(cancelled)`。
- turn 已经结束、`session_end` 尚未写入时：保留原 `turn_end`，把结果标为取消，`session_end(reason=signal)`，按信号码退出。

`cancel.target_id` 取当前记录的消息或工具调用 id，可能为 null。取消路径结束时，`ap-cli` 写 `session_end(reason=signal)`。如果 `session_end` 也写不进去，退出码改为 1。

取消标志不能打断重试 sleep。`Retry-After` 很大时，退出会相应延后。第二次信号的 1 秒强退是这条延迟路径的兜底。

## 超时

| 对象 | 默认值 | 配置 | 触发后 |
| --- | --- | --- | --- |
| LLM 总请求 | 600000ms | `llm_timeout_ms` | 按 `timeout` 重试 |
| LLM 建立连接 | 30000ms | 固定 | 按 curl 错误映射，通常为 `timeout` 或 `network` |
| LLM 首字节 | 120000ms | 固定 | `timeout`，可重试 |
| LLM 低速 | 1 字节每秒，持续 120s | 固定 | `timeout`，可重试 |
| 单个 bash | `min(tool_timeout_ms, 600000)`，默认 120000ms | `tool_timeout_ms`、调用参数 `timeout_ms` | 终止进程树，返回 `ok=false` |
| bash 超时参数上限 | 600000ms | 固定 | 超过上限按参数错误返回 |
| 单个 task | 无 | 无 | 子代理自己的 LLM 与 bash 超时生效 |
| 单个 turn | 无墙钟上限 | `max_steps` 控制步数 | 达到上限写 `turn_end(max_steps)` |

bash 的 `timeout_ms` 必须为正数，且不超过 600000。超时不是 fatal，作为 tool result 返回。

## 落盘与恢复

1. transcript 每个事件追加后立即 flush。完整事件永不改写。
2. 写入失败返回 `.Internal`，`ap-cli` 退出 1。Loop 可能在失败路径上补写 `error(scope=session)`，该补写也可能失败。
3. 恢复前截掉没有换行结尾的尾行。读取时最后一条非空行损坏会忽略并 warning。中间行损坏直接失败，退出 2。
4. 缺少 `session_end` 表示上次异常退出。恢复时追加 warning，不补写修复事件。
5. 未闭合的 tool call 在投影时删除。不写修复事件，不改 transcript。
6. blob 缺失或 sha256 不匹配时恢复失败。system prompt blob 在打开 session 时失败。其它 blob 在第一个 step 失败。两种情况都退出 2。
7. 恢复不重新执行工具，不重试 provider 请求，不重新调用 LLM 生成摘要。
8. `error` 事件必须带 `scope`、`kind`、`message`、`retryable`、`attempt`。配置错误发生在 transcript 创建前，只有 stderr 与日志。
9. 取消发生在 blob 写入中时，临时文件可能残留。只要引用事件没有写，恢复不受影响。

## 退出码映射

`ap-cli` 把引擎的 `Error_Kind` 映射成退出码。SDK 与工具只返回错误值，不调用 `os.exit`。

- `None` → 0。包括 `max_steps` 与 `max_tokens` 正常终止。
- `Internal` → 1。transcript 写入失败、工具 schema 解析失败、session 关闭失败。
- `Usage` → 2。参数与配置错误、session 不存在、transcript 损坏、blob 缺失、上下文组装失败。
- `Provider` → 3。重试耗尽、不可重试的 provider 错误、`context_too_long`。
- `Tool` → 4。工具 fatal 故障、工具参数 blob 写入失败、建 session 时 system prompt blob 写入失败。
- 信号 → 130 或 143。SIGINT、Ctrl+C 与 Ctrl+Break 为 130，SIGTERM 为 143。

退出码 0 不代表模型正常说完。`max_steps` 与 `max_tokens` 也返回 0，调用方应读 `turn_end.stop_reason` 或 `json` 输出的 `stop_reason`。

取消路径优先于错误映射。`result.cancelled` 为 true 时优先使用信号码，没有记录信号时用 130。用户可见的完整退出码表见 [cli-and-config.md](cli-and-config.md#退出码)。

## 相关文档

- [react-loop-and-session.md](react-loop-and-session.md)：事件 schema 与恢复
- [provider.md](provider.md)：HTTP、SSE 与错误 kind
- [context-management.md](context-management.md)：`context_too_long`
- [tools.md](tools.md)：单个工具的错误文本与上限
- [cli-and-config.md](cli-and-config.md)：用户可见的退出码表、诊断日志与配置字段
