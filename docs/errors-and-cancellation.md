# 错误、重试与中断

无审批设计下，中断是用户唯一的止损手段，所以这一章的核心是：**每个失败点都必须有明确出口，且必须落盘。**

## 错误分类

| 类别 | 例子 | 处理 | 落盘 |
| --- | --- | --- | --- |
| 配置错误 | 未配置 api_key、模型 id 为空、`$AP_CONFIG` 不可写、agent 定义非法 | 启动即退出 | 无（stderr + exit 2） |
| provider 网络 | 连接失败、连接超时、读超时、429、5xx | 退避重试 | `error`（retryable=true） |
| provider 协议 | 非法 JSON、tool_call 参数不是合法 JSON、未知 `finish_reason` | 不重试，终止当前 turn | `error`（retryable=false） |
| 上下文超限 | `context_too_long` | 不重试，终止当前 turn | `error` + `turn_end(context_too_long)` |
| 流中断 | 已收到部分 delta 后连接断开 | 丢弃半截消息，重试同一 step | `error` |
| 工具错误 | 路径不存在、编辑未匹配、参数非法、bash 超时 | 作为 tool result 返回，循环继续 | `tool_execution_end(ok=false)` |
| 工具基础设施故障 | 无法 spawn shell、工具参数/system prompt 的 blob 写入失败 | 终止 turn | `error`（scope=tool/session） |
| transcript 写入失败 | 磁盘满、flush 失败、事件序列化失败 | 无法再可靠落盘，直接退出 | 尽力写 `error(scope=session)`；通常只能靠 stderr |
| 用户中断 | SIGINT / SIGTERM | 见下 | `cancel` |

原则：**工具的错误是给模型的输入，不是给程序的异常**；provider、配置、基础设施的错误才是程序异常。

## LLM 侧重试

1. 可重试：连接失败、超时、429、5xx（>=500）、流中断
2. 不可重试：400 参数错误、401/403 鉴权、404 模型不存在、`context_too_long`、协议错误
3. 退避：指数 + 抖动，基准 1s，最多 5 次（1s / 2s / 4s / 8s / 16s）；429 优先用 `Retry-After`
4. 退避用阻塞 sleep 实现。信号只会设置取消标志，当前退避 sleep 结束后才检查取消；若 `Retry-After` 很大，退出也会相应延后
5. **重试边界**：尚未收到任何 delta 时直接重发；收到部分 delta 后断流，丢弃半截消息，**重试同一个 step**，不把半截内容放进上下文；如果这段文本已经展示给用户，stderr 明确提示「该段已作废」
6. **重试不增加 step**：`step_start` 只写一次，重试只写 `error(attempt)`；`max_steps` 不受重试影响
7. 丢弃的半截消息不写 `message_end`；如果已经写了 `message_start`，重放时按无 end 的消息忽略
8. 重试对用户可见：每次写 `error` 事件，并在 stderr 输出一行
9. 重试耗尽 → 终止当前 turn，写 `session_end(reason=error)`，退出码 3；这条路径没有 `turn_end`（`error` 已逐次落盘）

重试事件只在 transcript 里，不进入下一轮上下文；模型不需要知道网络抖动。

## 工具侧失败

| 情况 | tool result |
| --- | --- |
| 参数校验失败 | `ok:false`，指明哪个参数、期望什么 |
| 路径不存在 / 无权限 | `ok:false`，附规范化后的绝对路径 |
| 文件非 UTF-8 | `ok:false`，建议改用 bash |
| edit 未匹配 / 多处匹配 | `ok:false`，附匹配次数与建议 |
| read_file 超出单次范围 | 截到 2000 行，附 `start_line` 继续提示 |
| bash 非 0 退出 | `ok:true`，带 `exit_code` 与合并输出 |
| bash 超出 2000 行 | 返回前 2000 行，附完整输出 `.txt` 路径与 `read_file` 续读提示 |
| bash 超时 | `ok:false`，`error: "timeout after Nms"`，进程树已终止 |
| 输出超过 `max_capture_bytes` | `ok:false`，`error: "output exceeded <max_capture_bytes> bytes"`，进程树已终止 |
| 工具结果的 blob 写入失败 | `ok:false`，`error: "failed to persist output blob"`，循环继续 |
| 工具被取消 | `ok:false`，`error: "cancelled"` |

不做「同一工具连续失败 N 次熔断」；v1 由 `max_steps` 与模型自身收敛。后续可加。

## 用户中断

v1 没有交互模式，没有 Esc。中断只来自信号。

### 信号语义

| 输入 | 行为 |
| --- | --- |
| SIGINT（第一次） | 取消当前 step：中止 HTTP 请求、终止工具/子代理进程树，写事件后退出 130 |
| SIGINT（1s 内第二次） | 直接退出 130，不再写事件 |
| SIGTERM | 与第一次 SIGINT 相同，但退出码 143 |
| 空闲时收到信号 | 写 `session_end(reason=signal)`，退出 130 / 143 |

Windows 没有 Unix 信号：Ctrl+C 走 console handler；`TerminateProcess` 无法被捕获，视为异常退出。Odin 侧用 `core:sys/windows.SetConsoleCtrlHandler` 注册。

### 取消传播

1. 设置取消标志（原子布尔）
2. 中止 HTTP 请求：curl 的进度回调返回非 0
3. 正在执行的工具：终止整棵进程树
   - Unix：通过 PPid 递归收集后代；先 `SIGTERM`，2s 后对同一快照 `SIGKILL`。不依赖进程组
   - Windows：`TerminateJobObject` 或 `taskkill /T /F`
   - 子代理：先递归终止其子进程树
4. 已产生的副作用不回滚（写了一半的文件、已执行的命令），如实落盘
5. 事件顺序：`cancel` → `tool_execution_end(ok=false, error="cancelled")`（若有）→ `message_end(stop_reason="cancelled")`（若正在流式）→ `turn_end(stop_reason="cancelled")` → `session_end(reason=signal)`
6. 被取消的 assistant 消息保留在 transcript 里供人查看，但**不进入下一轮上下文**

### 中断时的竞态

- 工具已执行完但 `tool_execution_end` 未写入时被 kill：恢复时该 tool call 没有 end，投影时删除对应 `tool_use` 块，不补修复事件
- provider 流中断（非用户取消）：丢弃已收到内容，不写 `message_end`；如果已经写了 `message_start`，重放时忽略。用户主动取消时按上面的顺序写 `message_end(cancelled)`
- 中断发生在 blob 写入过程中：临时文件可能残留；最终 blob 不存在，引用事件也没有写，恢复不受影响
- 中断发生在 `session_end` 写入前：恢复时按异常退出处理

## 超时

| 对象 | 默认 | 配置项 | 触发后 |
| --- | --- | --- | --- |
| 单次 LLM 请求 | 600s | `llm_timeout_ms` | 按可重试网络错误处理 |
| LLM 首字节 | 120s | 固定 | 同上（连接已建立但无响应视为卡死） |
| 单个 bash | 120s | `tool_timeout_ms` / `timeout_ms` | 终止进程树，返回 `ok:false` |
| bash 上限 | 600s | 参数上限 | 参数超过上限 → `ok:false` 参数错误 |
| 单个 task | 无超时 | — | 子代理自己的 LLM / bash 超时生效 |
| 单个 turn | 无硬上限 | `max_steps` 控制步数 | 达到上限正常结束，`stop_reason=max_steps` |

超时不是程序异常：bash 超时作为 `ok:false` 的 tool result 返回，LLM 超时按网络错误重试。

## 上下文超限

1. provider 返回 `context_too_long`
2. 不重试、不压缩
3. 写 `error(scope=llm, kind=context_too_long, retryable=false)`
4. 写 `turn_end(stop_reason=context_too_long)`
5. 写 `session_end(reason=error)`，退出 3
6. 错误消息进入 `error` 事件和 JSON 输出；不单独打印 stderr 提示。用户可据此开新 session 或缩小输入

这是 v1 唯一的超限出口。后续 handoff 会替代它。

## 落盘与恢复

1. 进程异常退出（kill -9、断电）时没有 `session_end`。恢复时以此判断上次是异常退出，在 stderr 提示
2. 恢复不重放工具，不重试 provider 请求；只重建上下文，等新提示词
3. 未闭合的 tool call 在投影时忽略（删除 tool_use 块），不写修复事件
4. 完整事件只追加；恢复时只截掉崩溃留下的不完整尾行
5. blob 缺失或 hash 不匹配 → 恢复失败，退出 2
6. `error` 事件必须包含 `scope`、`kind`（可空）、`message`、`retryable`、`attempt`，便于事后统计失败分布
7. 配置错误发生在 transcript 创建前时，只有 stderr，没有 transcript

## 退出码

与 [cli-and-config.md](cli-and-config.md) 一致：

| 码 | 含义 |
| --- | --- |
| 0 | 正常结束 |
| 1 | 内部错误 |
| 2 | 用法 / 配置 / session 不存在 / blob 损坏 |
| 3 | provider 错误 / 重试耗尽 / `context_too_long` |
| 4 | 工具基础设施故障 |
| 130 | SIGINT |
| 143 | SIGTERM |
