# ReAct Loop 与 Transcript

## 循环

用户提交一条提示词，即开始一个 **turn**。ap 调用 LLM 并等待响应，一次「请求 → 响应」称为一个 **step**。收到响应后：

- `stop_reason = tool_use`：串行执行响应中的全部工具调用，全部结束后进入下一个 step
- 其它取值（`stop` / `max_tokens` / `max_steps` / `cancelled` / `context_too_long`）：turn 结束

只有 `tool_use` 会继续循环，其余取值都终结本轮。

```
idle ──提示词──► calling_llm ──tool_use──► running_tools ──► calling_llm
                      │                                        │
                      ├──stop / max_tokens / max_steps ───────► idle
                      ├──context_too_long ─────────────────────► idle
                      └──cancelled ────────────────────────────► idle
```

约束：

1. 工具串行执行，工具结果必须紧跟在要求它的 assistant 消息之后
2. **重试不增加 step**：`step` 是一次逻辑 LLM 调用；同一次调用的多次网络重试只写 `error(attempt)`，不写新的 `step_start`
3. `max_steps` 在发起下一次 LLM 调用前检查；当前响应里的所有 tool call 都会执行完再判定，不会留下执行到一半的 step
4. 一个 turn 内 assistant 消息、tool result、错误事件按 `seq` 排列；读取方按 `tool_call_id` 配对，不假设相邻

## Transcript

Transcript 是 session 的唯一事实来源，只追加，永不改写。

- 文件位置：`$AP_CONFIG/projects/<project_path_hash>/<session_id>.jsonl`（见 [cli-and-config.md](cli-and-config.md)）
- 一行一个 JSON 事件；写入后立即 flush
- 崩溃最多丢失正在写的那一行；读取时最后一行无法解析则丢弃
- `seq` 从 0 单调递增，作为排序与去重依据
- 未知事件类型跳过；已知类型但 `v` 大于支持版本时报错，避免误读
- 大块数据写入同目录的 `blobs/<sha256>`，事件只存引用；blob 必须先于引用事件写完并 fsync

事件分两类：

| 类别 | 落盘 | 用途 |
| --- | --- | --- |
| transcript event | 是 | 恢复、重放、审计 |
| stream event | 否 | 实时展示、子代理透传；只写 stdout |

## Transcript 事件

公共字段：

```js
{v: 1, seq: 0, ts: 1730000000000, type: 'session_start', ...}
```

| 字段 | 说明 |
| --- | --- |
| `v` | schema 版本，v1 固定为 1 |
| `seq` | 本 session 内单调递增，从 0 开始 |
| `ts` | unix 毫秒时间戳 |
| `type` | 事件类型；未知类型读取方必须跳过 |

### session_start

```js
{
  v: 1,
  seq: 0,
  ts: 1730000000000,
  type: 'session_start',
  session_id: '<uuid>',
  content: '<system prompt>',
  role: 'system',
  cwd: '<规范化绝对路径>',
  model: '<model_id>',
  provider: 'openai-chat-completions',
  agent_name: 'general',
  agent_depth: 0,
  parent_session_id: null,
  parent_tool_call_id: null,
  resumed_from: null
}
```

约定：

1. 新 session 的 `seq` 为 0；恢复时追加的 `session_start` 的 `seq` 继续递增
2. `content` 是**冻结**的 system prompt；恢复时不重新读取记忆文件、不重算时间
3. `parent_session_id` / `parent_tool_call_id` 只在子代理中非空
4. `resumed_from`：原地恢复指向自身 `session_id`；fork 指向源 `session_id`；新 session 为 null
5. system prompt 超过 `blob_threshold_bytes` 时，`content` 置空并写 `content_ref` / `content_bytes`；读取方从 blob 还原
6. 同一文件内允许多个 `session_start`（恢复、fork 后的追加），读取方以最后一个为准

### session_end

```js
{
  type: 'session_end',
  reason: 'exit',          // exit | signal | error
  usage: {input_tokens: 0, output_tokens: 0, cached_tokens: 0,
          reasoning_tokens: 0, total_tokens: 0}
}
```

进程被 `kill -9` / 断电时没有 `session_end`，恢复时据此判断上次是异常退出。

### user_message

```js
{type: 'user_message', content: '<用户提示词>'}
```

提示词来源见 [cli-and-config.md](cli-and-config.md)。一次运行最多一条；恢复运行会追加新的 `user_message`，因此同一 transcript 可以有多条。

### turn_start / turn_end

```js
{type: 'turn_start', turn: 1}

{type: 'turn_end', turn: 1, stop_reason: 'stop',
 usage: {input_tokens: 0, output_tokens: 0, cached_tokens: 0,
         reasoning_tokens: 0, total_tokens: 0}}
```

`turn_end.stop_reason` 取值：`stop` / `max_tokens` / `max_steps` / `cancelled` / `context_too_long`。

### step_start

```js
{type: 'step_start', step: 1}
```

约定：

1. `turn` 从 1 开始，按 session 内用户 turn 单调递增；恢复后继续递增，不重置
2. `step` 从 1 开始，每个 turn 内重新计数；它表示逻辑 LLM 调用，不表示网络尝试
3. 一个 step 只写一次 `step_start`；重试不重复写

### message_start / message_end

assistant 消息只在开始时和结束时落盘，流式增量走 stdout，不落盘。

```js
{type: 'message_start', message_id: '<id>', role: 'assistant', model: '<model_id>'}

{
  type: 'message_end',
  message_id: '<id>',
  role: 'assistant',
  content: [
    {type: 'text', text: '...'},
    {type: 'tool_use', id: 'call_1', name: 'read_file', input: {file_path: 'a.txt'}}
  ],
  stop_reason: 'tool_use',
  usage: {...},
  reasoning: null
}
```

内容块：

- `{type: 'text', text}`；超大时改为 `{type: 'text', text_ref, text_bytes, text_preview}`
- `{type: 'tool_use', id, name, input}`；`input` 序列化后超过阈值时改为
  `{type: 'tool_use', id, name, input_ref, input_bytes, input_preview}`
- `reasoning`：provider 返回推理内容时可选记录，**不进入上下文**；没有则为 null

约定：

1. `message_id` 优先用 provider 响应 id，缺失时生成 UUID
2. 被中断的消息仍写 `message_end`，`stop_reason` 为 `cancelled`，且不进入下一轮上下文
3. tool result 不单独建 message 事件，从 `tool_execution_end` 投影
4. 重试导致的废弃响应不写 `message_end`；只写 `error(attempt)`
5. 流式过程中崩溃时可能只有 `message_start`；重放时忽略没有 `message_end` 的消息

### tool_execution_start / tool_execution_end

```js
{
  type: 'tool_execution_start',
  tool_call_id: 'call_1',
  name: 'bash',
  args: {command: 'ls'},
  args_ref: null, args_bytes: null, args_preview: null
}

{
  type: 'tool_execution_end',
  tool_call_id: 'call_1',
  ok: true,
  content: '<完整结果；超过阈值时为空，改用 content_ref>',
  content_ref: null,
  content_bytes: null,
  content_preview: null,
  error: null,
  duration_ms: 12,
  exit_code: 0,
  metadata: null
}
```

约定：

1. `args` 超过 `blob_threshold_bytes` 时置空，写 `args_ref` / `args_bytes` / `args_preview`
2. `content` 超过阈值时置空，写 `content_ref` / `content_bytes` / `content_preview`
3. `content_ref` 是 blob 的 sha256；读取方在 transcript 同目录的 `blobs/` 下解析
4. `exit_code` 仅 `bash` 有；其它工具为 null
5. `metadata` 供工具附加结构化信息；`task` 写 `{child_session_id, stop_reason, usage}`
6. 非 0 退出码的 bash 仍是 `ok: true`；只有无法执行、超时、取消、输出超过硬上限才是 `ok: false`
7. 被取消时写 `ok: false, error: "cancelled"`

### error

```js
{
  type: 'error',
  scope: 'llm',            // llm | tool | config | session
  kind: 'rate_limit',      // provider 错误 kind，可空
  message: '<可读错误>',
  retryable: true,
  attempt: 1
}
```

`scope=tool` 只用于工具基础设施故障（无法 spawn shell、工具参数/system prompt 的 blob 写入失败）；普通工具错误（包括工具结果的 blob 写入失败）走 `tool_execution_end(ok=false)`，不作为 `error` 事件。

### cancel

```js
{type: 'cancel', scope: 'step', target_id: '<message_id 或 tool_call_id>'}
```

- `scope=step`：取消进行中的 LLM 请求或工具
- `scope=turn`：放弃整轮；此时 `target_id` 为当前 message id 或 null
- 事件顺序：`cancel` → `tool_execution_end(ok=false)`（若有）→ `message_end(cancelled)`（若正在流式）→ `turn_end(cancelled)`

### usage

所有 usage 字段均可为 null；不要用 0 冒充缺失值。

```js
{
  input_tokens: 0,
  output_tokens: 0,
  cached_tokens: 0,
  reasoning_tokens: 0,
  total_tokens: 0
}
```

- `message_end.usage`：本次响应的 usage，来自 provider
- `turn_end.usage`：本 turn 内所有 step 的累加
- `session_end.usage`：整个 session 的累加（含此前多次恢复运行的 turn；按 `turn_end.usage` 求和，null 不计）

## Stream 事件（不落盘）

`--output-format stream-json` 时，以下事件只写 stdout，不写 transcript：

```js
{
  type: 'message_update',
  ts: 1730000000000,
  message_id: '<id>',
  delta: {text: '片段'}
}

{
  type: 'message_update',
  ts: 1730000000000,
  message_id: '<id>',
  delta: {reasoning: '片段'}
}

{
  type: 'message_update',
  ts: 1730000000000,
  message_id: '<id>',
  delta: {tool_call: {index: 0, id: 'call_1', name: 'read_file', args_delta: '{"file'}}
}

{
  type: 'tool_execution_update',
  ts: 1730000000000,
  tool_call_id: 'call_1',
  chunk: '增量输出'
}
```

约定：

1. stream 事件没有 `seq`，因为它们不进入 transcript；顺序由 stdout 行序保证
2. `tool_call_delta` 按 `index` 累积；`id` 可能只在第一个片段出现
3. `message_update` 的文本按 `message_id` 拼接；读取方自行处理 UTF-8 边界
4. 子代理的父进程消费这些事件做实时展示；不写父 transcript
5. `--output-format text/json` 时不输出 stream 事件，日志与进度仍走 stderr

## 恢复与重放

1. `-s <id>`：只在当前项目内查找 `projects/<hash>/<id>.jsonl`；找不到退出 2
2. 按 `seq` 顺序读取，最后一个 `session_start` 决定 system prompt、model、provider、agent_name、agent_depth、cwd
3. 不重新调用 LLM、不重新执行工具、不重新读记忆文件
4. blob 按引用解析；blob 缺失时恢复失败（退出 2），不静默降级
5. 未闭合的 tool call：投影时删除没有 `tool_execution_end` 的 `tool_use` 块；若整条 assistant 消息只剩这个块，整条不提交；同一消息里的 text 保留
6. 不写任何修复事件；transcript 保持原样
7. 恢复后追加新的 `session_start`，然后开始新 turn；新事件的 `seq` 继续递增
8. 子代理 session 同样可以 `-s` 打开；`parent_session_id` 用于展示层级

## fork

`--fork-session` 与 `-s` / `-c` 连用：

1. 生成新 `session_id`
2. 复制全部事件到同项目目录的新文件
3. 追加新的 `session_start`：新 id、`resumed_from=源 id`、`parent_session_id=null`、`parent_tool_call_id=null`、`agent_depth=0`，其余字段沿用源
4. `seq` 从源最大值 + 1 继续
5. blob 不复制，按 sha256 共享
6. 原文件不动

## 未来

- handoff：在上下文将满时创建新 session 并写一条链接事件；不改变现有事件语义
- 并行工具：事件已按 `tool_call_id` 关联，读取方不假设相邻即可；`seq` 仍单调
- 事件 schema 升级：`v` 递增，读取方遇到更高版本时明确报错
