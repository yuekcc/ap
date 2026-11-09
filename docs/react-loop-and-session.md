# ReAct 循环与 Session 记录

本文件定义 turn 与 step 的状态机、transcript 事件 schema、恢复与 fork。Provider 的请求与 SSE 解析见 [provider.md](provider.md)，system prompt 与消息投影见 [context-management.md](context-management.md)，错误与取消见 [errors-and-cancellation.md](errors-and-cancellation.md)。

## turn 与 step

一次 `ap` 运行处理一条提示词，构成一个 turn。一个 turn 包含一到多个 step。step 是一次逻辑 LLM 调用，同一次调用的网络重试仍属于同一个 step。

```text
user_message
  turn_start
    step_start -> LLM 调用 -> message_end
      stop_reason=tool_use -> 串行执行工具 -> 下一个 step
      stop_reason=stop 或 max_tokens -> turn_end
    max_steps 或取消 -> turn_end
```

- `user_message` 先写，随后写 `turn_start`。
- 每个 step 先写 `step_start`，再构建上下文、发起 provider 请求。
- provider 返回 `tool_use` 时，按响应顺序串行执行全部 tool call。全部 `tool_execution_end` 写完后进入下一个 step。
- provider 返回 `stop` 或 `max_tokens` 时写 `turn_end`，turn 结束。
- `max_steps` 在发起下一次 step 前检查。当前 step 已返回的 tool call 会先执行完，再写 `turn_end(max_steps)`。
- `step` 在每个 turn 内从 1 开始，turn 之间重置。`turn` 从 1 开始，在同一 transcript 内继续递增。
- 重试不写新的 `step_start`，只写 `error.attempt` 增加的 `error` 事件。
- 取消在每个 step 顶部、每个工具执行前检查。取消路径见 [errors-and-cancellation.md](errors-and-cancellation.md)。

`turn_end.stop_reason` 只有六个取值：`stop`、`max_tokens`、`max_steps`、`cancelled`、`context_too_long`、`handoff`。`handoff` 不是失败：本轮正常结束，交接文档已写入 `handoff` 事件，由 CLI 创建承载它的新 session。assistant 的 `message_end.stop_reason` 取 `stop`、`tool_use`、`max_tokens`、`cancelled`。

以下路径不写 `turn_end`：provider 最终失败、上下文组装失败、工具 schema 解析失败、工具 fatal 故障、transcript 写入失败。它们以 `session_end(reason=error)` 结束。transcript 写入失败时可能连 `session_end` 也无法落盘。

## transcript 规则

- 每个 session 一个只追加的 JSONL 文件，一行一个完整事件。目录布局见 [cli-and-config.md](cli-and-config.md)。
- 每个事件写入后立即 flush。完整事件永不改写。
- 恢复前唯一允许的物理改动是截掉崩溃留下的不完整尾行。该尾行没有换行结尾，从未成为完整事件。
- 文件行序就是读取顺序。`seq` 由写入方从 0 开始递增。恢复时新事件取已有最大 `seq` + 1。读取方不校验连续性，也不按 `seq` 重排。
- `v` 是 schema 版本，当前为 1。已知事件类型的 `v` 大于 1 时恢复失败。未知 `type` 跳过。
- 非最后一条非空行无法解析为 JSON 对象或缺 `type` 时，恢复失败。最后一条非空行损坏时忽略并 warning，不截掉该行。
- 超过 `blob_threshold_bytes` 的文本、工具参数、工具结果和 system prompt 写入 blob。事件保存 sha256 引用与字节数。blob 必须先落盘并 fsync，再追加引用它的事件。blob 的布局与读取见 [tools.md](tools.md)。
- transcript 是唯一事实来源。只在内存里的对话内容不允许存在。流式增量只用于展示，不进入恢复。

## 事件信封

所有 transcript 事件把公共字段平铺在顶层。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `v` | int | schema 版本，当前为 1 |
| `seq` | int | 本 session 内递增，新 session 从 0 开始 |
| `ts` | int | unix 毫秒时间戳 |
| `type` | string | 事件类型 |

带 `omitempty` 的可选字段（各类 `*_ref`、`*_bytes`、`*_preview`、`args`、`input`）缺失时不出现。其余可选字段写 `null`。读取方把缺失与 `null` 按同一种缺省处理。

事件名、`stop_reason`、`scope`、`session_end.reason`、角色与块类型的权威常量在 `ap-core/protocol/names.odin`。新增或改名事件类型时同步该文件与本文。

## usage

`usage` 对象在 transcript 与 stream 事件中结构相同。

| 字段 | 说明 |
| --- | --- |
| `input_tokens` | 输入 token |
| `output_tokens` | 输出 token |
| `cached_tokens` | 命中缓存的输入 token |
| `reasoning_tokens` | 推理 token |
| `total_tokens` | 总 token |

五个字段都可为 `null`。`null` 表示 provider 没有报告，不能用 0 冒充。累加时忽略 `null`，只对出现的字段求和。全部缺失时结果仍为 `null`。

- `message_end.usage`：本次响应的 usage，可能为 `null`。
- `turn_end.usage`：本 turn 内各 step 的累加。
- `session_end.usage`：整个 session 的累加，按所有 `turn_end.usage` 与 `handoff.usage` 求和，包含此前多次恢复运行。

## session_start

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `session_id` | string | session 标识 |
| `content` | string | 冻结的 system prompt。写入 blob 时为空串 |
| `content_ref` | string | system prompt 的 blob 引用，可选 |
| `content_bytes` | int | system prompt 字节数，可选 |
| `role` | string | 固定为 `system` |
| `cwd` | string | 创建时的规范化项目根 |
| `model` | string | 冻结的模型 id |
| `provider` | string | 固定为 `openai-chat-completions` |
| `agent_name` | string | agent 标签 |
| `agent_depth` | int | 子代理深度 |
| `parent_session_id` | string 或 null | 父 session，仅子代理非空 |
| `parent_tool_call_id` | string 或 null | 父进程中的 `task` 调用，仅子代理非空 |
| `resumed_from` | string 或 null | 新 session 为 null，恢复指向自身，fork 指向源 |
| `tools` | array 或 null | 冻结的生效工具列表 |

约定：

1. 新 session 的第一个事件是 `seq=0` 的 `session_start`。恢复与 fork 会追加新的 `session_start`，读取方以最后一个为准。
2. `content`、`content_ref`、`content_bytes` 共同承载 system prompt。超过阈值时只写引用。
3. `tools` 是最终生效列表，agent 白名单与深度规则已在建 session 前应用。零工具写空数组 `[]`，不能省略。
4. 旧 transcript 没有 `tools` 字段或该字段为 `null` 时，恢复使用当前注册表的全部工具并 warning。
5. `resumed_from` 只描述来源，不改变其它冻结字段。

## session_end

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `reason` | string | `exit`、`signal` 或 `error` |
| `usage` | usage | 整个 session 的累加 |

`ap-cli` 在正常结束时写 `exit`，信号取消写 `signal`，错误终止写 `error`。SDK 调用方可传其它值，session 层在空值时按取消状态填 `exit` 或 `signal`。

进程被强制杀死或断电时没有 `session_end`。恢复时据此判断上次是异常退出。

## user_message

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `content` | string | 用户提示词 |

一次运行写一条。恢复运行会在同一 transcript 追加新的 `user_message`，因此一个文件可以有多条。

## turn_start 与 turn_end

| 事件 | 字段 | 说明 |
| --- | --- | --- |
| `turn_start` | `turn` | 从 1 开始，session 内继续递增 |
| `turn_end` | `turn`、`stop_reason`、`usage`、`context` | 结束本 turn |

`turn_end.turn` 与对应的 `turn_start.turn` 相同。`stop_reason` 取六个终止值之一。

`context` 是可选字段：开启预算时记录本 turn 最后一次 step 决策后的快照，`context_window_tokens` 为 0 时为 `null`。

```json
"context": {
  "estimated_tokens": 121340,
  "limit_tokens": 950272,
  "elided_results": 4,
  "elided_bytes": 183422,
  "calibration_percent": 103
}
```

这些字段只用于观测，不进 transcript 以外的任何地方，也不进入 messages。旧版本读新 transcript 时忽略整个字段。计算规则见 [context-management.md](context-management.md)。

## handoff

把即将结束的对话压缩成交接文档的那一次模型调用的产物。它只追加，不改写任何历史事件。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `reason` | string | `budget_exhausted`、`context_too_long` 或 `manual` |
| `content` | string | 交接文档正文；写入 blob 时为空串 |
| `content_ref`、`content_bytes`、`content_preview` | 可选 | blob 引用、字节数与预览，规则与其它内容字段一致 |
| `usage` | usage | 这次交接调用本身的用量；未调用时为全 `null` |
| `source_events` | int | 参与投影的 transcript 事件数，仅诊断用 |

- 写入顺序遵循 blob 先写后引用：先写 blob 并 fsync，再追加事件。
- `handoff` 同时登记进 `event_type_known` 与 `event_type_canonical`，恢复时不会当未知事件丢掉。
- 同一 session 可以有多条 `handoff`，恢复时全部保留。投影忽略它：它不是 message。
- `handoff.usage` 计入 `session_end.usage`。manual handoff 没有 turn，用量只能挂在事件上。

## step_start

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `step` | int | 当前 turn 内的逻辑 LLM 调用序号 |

`step` 从 1 开始，每个 turn 重置。一个 step 只写一次 `step_start`，重试不重复写。

## message_start 与 message_end

assistant 消息只在开始与结束时落盘。流式增量只用于展示，不落盘。

| 事件 | 字段 | 说明 |
| --- | --- | --- |
| `message_start` | `message_id`、`role`、`model` | `role` 固定为 `assistant` |
| `message_end` | `message_id`、`role`、`content`、`stop_reason`、`usage`、`reasoning` | `usage` 与 `reasoning` 可为 `null` |

`content` 是内容块数组。文本块在前，`tool_use` 块按 provider 响应顺序在后。

| 块类型 | 字段 | 说明 |
| --- | --- | --- |
| `text` | `text` | 完整文本。写入 blob 时该字段缺失 |
| `text` | `text_ref`、`text_bytes`、`text_preview` | blob 引用、字节数、预览 |
| `tool_use` | `id`、`name`、`input` | 工具调用标识、名字、参数对象 |
| `tool_use` | `input_ref`、`input_bytes`、`input_preview` | 参数写入 blob 时的替代字段 |

约定：

1. `message_id` 优先使用 provider 返回的 id。缺失时由 Loop 生成 UUID。
2. `reasoning` 保存 provider 返回的推理内容。下一轮作为 assistant 消息的 `reasoning_content` 回传。
3. 被取消的消息仍写 `message_end`，`stop_reason` 为 `cancelled`，内容只包含本次尝试已收到的文本，`usage` 与 `reasoning` 为 `null`。该消息不进入下一轮上下文。
4. 重试丢弃的尝试不写 `message_end`。它可能留下只有 `message_start` 的消息，投影时忽略。
5. tool result 不建 message 事件，从 `tool_execution_end` 投影。

## tool_execution_start 与 tool_execution_end

| 事件 | 字段 | 说明 |
| --- | --- | --- |
| `tool_execution_start` | `tool_call_id`、`name`、`args` | `args` 是参数对象，写入 blob 时缺失 |
| `tool_execution_start` | `args_ref`、`args_bytes`、`args_preview` | 参数 blob 引用、字节数、预览 |
| `tool_execution_end` | `tool_call_id`、`ok`、`content`、`error` | 结果或错误，二者按 `ok` 取一 |
| `tool_execution_end` | `content_ref`、`content_bytes`、`content_preview` | 结果 blob 引用、字节数、预览 |
| `tool_execution_end` | `duration_ms`、`exit_code`、`metadata` | 耗时、退出码、工具附加信息 |

约定：

1. 每个实际开始执行的 tool call 各有一条 start 与一条 end，按 `tool_call_id` 配对。未开始的 call 没有事件。
2. `exit_code` 只有 `bash` 写。非 0 退出仍是 `ok: true`。
3. `metadata` 由工具决定。`task` 写入 `child_session_id`、`stop_reason`、`usage`、`duration_ms`。其它工具为 `null`。
4. 工具结果 blob 写入失败时写 `ok: false`、`content: null`、`error: "failed to persist output blob"`，循环继续。
5. 取消时写 `ok: false`、`error: "cancelled"`、`content: null`。
6. 工具执行返回 fatal 故障时，写本工具的 end 与一条 `error(scope=tool)`，随后终止 turn。同一 step 剩余的 tool call 不执行，也没有 end。

## error

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `scope` | string | `llm`、`tool` 或 `session` |
| `kind` | string 或 null | provider 错误 kind，`session` 与 `tool` 域通常为 null |
| `message` | string | 可读错误 |
| `retryable` | bool | 本次失败是否可重试 |
| `attempt` | int | 从 1 开始的尝试序号 |

`scope=llm` 记录 provider 的每次失败尝试，包括最终不再重试的那次。`scope=session` 用于上下文组装失败、工具注册表查询失败、transcript 写入失败、工具参数 blob 写入失败。`scope=tool` 只用于工具的 fatal 故障。配置错误发生在 transcript 创建前，不产生事件。

`error` 是诊断事件，不进入下一轮上下文。

## cancel

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `scope` | string | `step` 或 `turn` |
| `target_id` | string 或 null | 当前消息或工具调用 id，可能为 null |

取消时的事件顺序见 [errors-and-cancellation.md](errors-and-cancellation.md)。

## Stream 事件

`--output-format stream-json` 时，以下事件只写 stdout，不写 transcript。

```json
{"type":"message_update","ts":1730000000000,"message_id":"...","delta":{"text":"片段"}}
{"type":"message_update","ts":1730000000000,"message_id":"...","delta":{"reasoning":"片段"}}
{"type":"message_update","ts":1730000000000,"delta":{"tool_call":{"index":0,"id":"call_1","name":"read_file","args_delta":"{\"file"}}}
{"type":"tool_execution_update","ts":1730000000000,"tool_call_id":"call_1","chunk":"增量输出"}
```

- stream 事件没有 `v` 与 `seq`。顺序由 stdout 行序保证。
- `message_update.delta` 一次只带 `text`、`reasoning`、`tool_call` 之一。
- `tool_call` 的 `index` 与 `args_delta` 总是存在。`id` 与 `name` 只在非空时出现。
- 读取方按 `message_id` 拼接文本与推理，按 `index` 拼接工具参数。UTF-8 字符可能被拆到两个片段。
- `tool_execution_update` 的 `chunk` 已经过 UTF-8 清洗。
- stream-json 的 stdout 同时包含 transcript 事件。transcript 事件带 `v`、`seq`、`ts`、`type`，流式事件不带。
- `text` 与 `json` 格式不输出 stream 事件。日志与进度始终走 stderr。

## 恢复

1. `-s <id>` 在当前项目内查找指定 session。`-c` 选择最近修改的根 session。`--fork-session` 必须与 `-s` 或 `-c` 连用。参数细节见 [cli-and-config.md](cli-and-config.md)。
2. 找不到文件时按用法错误退出 2。上级目录不在当前项目时同样找不到。
3. 读取前截掉没有换行结尾的尾行。随后按文件行序读取全部事件。
4. 若最后一条事件不是 `session_end`，追加一条 warning，提示上次异常退出。
5. 最后一个 `session_start` 决定冻结值：system prompt、`model`、`provider`、`agent_name`、`agent_depth`、`cwd`、`tools`。恢复不重新读取 `$AP_CONFIG/SYSTEM.md`，不重新解析 agent 文件，不重新扫描技能与记忆。
6. `--model` 或 `--agent` 与冻结值不同时 warning 并忽略。SDK 传入的 base prompt、prompt sections、工具集覆盖、父链参数同样只 warning。
7. `max_steps` 与 `max_tokens` 不在 `session_start` 中冻结。恢复时取本次配置或命令行值。
8. 冻结工具在当前注册表中不存在时跳过并 warning，不终止 session。
9. system prompt 的 blob 缺失或损坏时，session 打开失败并退出 2。消息、参数或工具结果的 blob 缺失时，第一个 step 的上下文组装失败，写 `error(scope=session)` 与 `session_end(reason=error)`，退出 2。
10. 未闭合的 tool call 在投影时删除，不写修复事件。投影规则见 [context-management.md](context-management.md)。
11. 恢复以追加方式继续写同一文件。新 `session_start` 的 `session_id` 不变，`resumed_from` 指向自身，父链与深度沿用冻结值，`seq` 继续递增。随后才开始新 turn。
12. 子代理 session 与根 session 一样可以用 `-s` 打开。`parent_session_id` 与 `parent_tool_call_id` 用于展示层级，不改变恢复规则。
13. 恢复不会重新调用 LLM，不会重新执行工具，也不会生成摘要。

## fork

1. 新建 `session_id`。
2. 先按读取规则校验源 transcript，再把最后一个换行之前的内容复制到同项目目录的新文件。末尾没有换行的半行不进入 fork。
3. 追加新的 `session_start`：新 `session_id`，`resumed_from` 为源 id，`parent_session_id` 与 `parent_tool_call_id` 为 null，`agent_depth` 为 0。
4. `content`、`model`、`provider`、`agent_name`、`cwd`、`tools` 沿用源 `session_start`。
5. `seq` 从源文件最大 `seq` + 1 继续。
6. blob 不复制，按 sha256 共享。源 transcript 保持不变。

## 相关文档

- [context-management.md](context-management.md)：system prompt 与 transcript 到 messages 的投影
- [provider.md](provider.md)：请求、SSE、stop_reason 与 usage
- [errors-and-cancellation.md](errors-and-cancellation.md)：重试、取消、超时与退出码
- [cli-and-config.md](cli-and-config.md)：存储布局、恢复参数与输出格式
