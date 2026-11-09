# Provider：OpenAI Chat Completions

Provider 只支持 OpenAI chat completions 兼容接口。它把统一请求翻译成一次 HTTP 流式调用，把 SSE chunk 组装成统一事件，并把 HTTP 与协议失败翻译成 `Provider_Error`。它不重试，不决定取消，不做上下文管理。重试策略见 [errors-and-cancellation.md](errors-and-cancellation.md)，消息构造见 [context-management.md](context-management.md)。

## 接口

```odin
provider_stream :: proc(
	p:      ^Provider,
	req:    ^Chat_Message_Request,
	sink:   Stream_Sink,
	cancel: ^platform.Cancel_Token,
) -> Provider_Error
```

Odin 没有异步运行时。流式读取用阻塞 IO 加回调。

`sink` 是 `{user, on_event}`。`on_event` 接收 `Provider_Event` union：

- `Provider_Message_Start{model, message_id}`
- `Provider_Text_Delta{text}`
- `Provider_Reasoning_Delta{text}`
- `Provider_Tool_Start{index, id, name}`
- `Provider_Tool_Delta{index, args_delta}`
- `Provider_Tool_End{index}`
- `Provider_Message_End{message_id, stop_reason, usage, tool_calls, reasoning, text}`
- `Provider_Error_Event{err}`

`Provider_Error_Event` 只是即时通知。`provider_stream` 的返回值才是本次请求的最终结果。Loop 以返回值为准。

`Provider_Error` 包含 `kind`、`message`、`retryable`、`retry_after_ms`。`kind` 取 `auth`、`model_not_found`、`invalid_request`、`context_too_long`、`rate_limit`、`server_error`、`network`、`timeout`、`protocol`、`cancelled`、`internal` 或空。

## 请求

请求地址由 `base_url` 得到。先去掉尾部 `/`。已经以 `/chat/completions` 结尾时直接使用，否则追加 `/chat/completions`。

请求体字段：

| 字段 | 值 |
| --- | --- |
| `model` | 本次请求的模型 id |
| `messages` | system 消息加投影后的对话 |
| `tools` | 生效工具定义。没有工具时省略 |
| `tool_choice` | 有工具时为 `auto`，否则省略 |
| `parallel_tool_calls` | 固定 `false` |
| `max_tokens` | 单次响应上限，使用旧字段名。默认 `65536`（面向 64K 输出能力的模型） |
| `stream` | 固定 `true` |
| `stream_options` | `{"include_usage": true}`，仅当 `stream_include_usage` 为 true |

```json
{
  "model": "<model_id>",
  "messages": [
    {"role": "system", "content": "<system prompt>"},
    {"role": "user", "content": "..."},
    {"role": "assistant", "content": null, "reasoning_content": "...",
     "tool_calls": [
       {"id": "call_1", "type": "function",
        "function": {"name": "read_file", "arguments": "{\"file_path\":\"a.txt\"}"}}
     ]},
    {"role": "tool", "tool_call_id": "call_1", "content": "..."}
  ],
  "tools": [
    {"type": "function",
     "function": {"name": "read_file", "description": "...",
                  "parameters": {"type": "object", "properties": {}, "required": []}}}
  ],
  "tool_choice": "auto",
  "parallel_tool_calls": false,
  "max_tokens": 65536,
  "stream": true,
  "stream_options": {"include_usage": true}
}
```

消息约定：

1. system prompt 固定在 `messages[0]`，`role` 为 `system`。
2. assistant 消息没有文本时 `content` 为 `null`。有推理内容时带 `reasoning_content`。
3. 每个 tool result 是一条独立的 `role=tool` 消息，按 tool call 顺序排列。
4. tool call 的 `arguments` 是 JSON 字符串。参数对象由上下文投影生成。
5. 工具定义来自注册表，顺序与注册表声明顺序一致。
6. 没有工具时不发送 `tools` 与 `tool_choice`。`parallel_tool_calls` 仍为 `false`。

请求头固定为 `Content-Type: application/json`、`Accept: text/event-stream`、`User-Agent: ap/<VERSION>` 与 `Authorization: Bearer <api_key>`。API key 不写日志，不写 transcript。

## SSE 读取

响应必须是 SSE。非 200 响应的正文只用于生成错误信息，不进入 SSE 解析。

HTTP 头回调：

- 解析 `HTTP/` 状态行，只接受 200 到 599。
- 解析 `Retry-After`，只接受整数秒，换算成毫秒。
- 收到 200 时，把此前缓存的正文送入 SSE 解析器。

正文回调：

- 状态为 200 时把字节送入 SSE 解析器。
- 状态不是 200 时缓存正文，上限约 1MB。
- 每个回调都更新收到数据的标记，供首字节超时判断。

SSE 解析规则：

1. 按 `\n` 切行，去掉行尾 `\r`。
2. 忽略空行与 `:` 开头的注释行。
3. 只收集 `data:` 开头的行。冒号后的一个前导空格会去掉。多行 `data:` 用 `\n` 连接。
4. 有累积 `data` 的空行触发一次回调，把累积内容作为 JSON 文本交给组装器。
5. 数据恰好为 `[DONE]` 时结束流，不再回调。
6. 单行上限 16MB。超过时返回协议错误。
7. 连接关闭时处理最后一行，并冲刷仍未派发的 `data`。
8. 跨 chunk 的字节保留在行缓冲里。被切断的多字节 UTF-8 字符不会丢失。
9. 流结束前没有出现 `[DONE]` 时返回 `network`，`retryable=true`。

## chunk 与 tool call 组装

组装器读取每个 chunk 的 `id`、`model`、`choices`、`usage` 与 `error`。

- 首个有效 chunk 发一次 `Provider_Message_Start`。`message_id` 可能为空。`model` 缺失时用请求的模型 id。
- `choices[].delta.content` 非空时追加到全文并发出 `Provider_Text_Delta`。
- `choices[].delta.reasoning_content` 非空时追加到推理并发出 `Provider_Reasoning_Delta`。
- 每个 `choices[].delta.tool_calls[]` 按 `index` 建槽。槽第一次出现时发 `Provider_Tool_Start`。
- `id` 与 `name` 可能只在第一个片段出现。出现时更新槽。后续片段通常只带 `function.arguments`。
- 参数片段只追加，不即时解析。非空片段发 `Provider_Tool_Delta`。
- `finish_reason` 取最后一个非空值。
- `usage` 取最后一个带 usage 的 chunk。多个 chunk 的 usage 不累加。
- chunk 自带的 `error` 对象直接终止本次流，映射见下文。

收到 `[DONE]` 后调用一次组装收尾：

1. 没有发出过 `Provider_Message_Start` 时报协议错误 `empty response from provider`。
2. 没有 `finish_reason` 时报协议错误 `stream ended without finish_reason`。
3. `finish_reason` 无法归一化时报协议错误。
4. 槽按 `index` 升序排序。
5. 每个槽必须有非空 `id` 与 `name`。缺失时报协议错误。
6. 参数为空时按 `{}` 解析。JSON 解析失败时报协议错误。
7. 每个槽发一次 `Provider_Tool_End`。
8. `stop_reason` 不是 `tool_use` 却带 tool call，或 `tool_use` 却没有 tool call，都是协议错误。
9. 发出 `Provider_Message_End`，带上全文、推理、usage 与组装好的 tool call。

tool call 的顺序按 `index` 升序，不按 chunk 顺序或 map 遍历顺序。

## stop_reason 归一化

| 统一值 | OpenAI `finish_reason` | 循环层处理 |
| --- | --- | --- |
| `stop` | `stop`、`content_filter` | 结束 turn。`content_filter` 额外写 warning |
| `tool_use` | `tool_calls` | 执行工具，进入下一个 step |
| `max_tokens` | `length` | 结束 turn，`stop_reason=max_tokens` |

缺失或未知的 `finish_reason` 是协议错误，`retryable=false`。

## usage

| 统一字段 | OpenAI 字段 |
| --- | --- |
| `input_tokens` | `prompt_tokens` |
| `output_tokens` | `completion_tokens` |
| `cached_tokens` | `prompt_tokens_details.cached_tokens` |
| `reasoning_tokens` | `completion_tokens_details.reasoning_tokens` |
| `total_tokens` | `total_tokens` |

缺失的字段保留 `null`。没有 usage 的响应写全 `null`，不写 0。

## 错误映射

HTTP 错误正文按 `{"error":{"message","type","code"}}` 解析。`message` 缺失时用去掉首尾空白的正文。正文为空时写 `HTTP <status>`。消息截断到 2000 字节。

| 情况 | kind | retryable |
| --- | --- | --- |
| 401、403 | `auth` | false |
| 404 | `model_not_found` | false |
| 400，code 或 message 匹配上下文超限 | `context_too_long` | false |
| 400，其它 | `invalid_request` | false |
| 429 | `rate_limit` | true |
| 500 及以上 | `server_error` | true |
| 其它 4xx | `invalid_request` | false |
| 其它非 200 | `server_error` | true |
| 连接失败、其它 curl 错误 | `network` | true |
| curl 超时类错误 | `timeout` | true |
| 首字节超过 120s | `timeout` | true |
| SSE 解析失败、行超长、参数 JSON 非法、结构非法 | `protocol` | false |
| 用户取消 | `cancelled` | false |
| 流在 `[DONE]` 前结束 | `network` | true |

上下文超限的匹配不区分大小写，检查 `context_length_exceeded`、`context_too_long`、`maximum context length`、`context length exceeded`、`too many tokens`。

`context_too_long` 不重试。Loop 第一次收到它时收紧预算重算并重发同一个 step；第二次仍收到就交由上下文管理流程处理（交接或现行退出路径）。引擎不在 provider 层做这些决策，这里只负责如实分类。纠正顺序见 [errors-and-cancellation.md](errors-and-cancellation.md)。

### usage 的用途

`usage.input_tokens` 除了展示与累加，还用于校准本地估算：transcript 只追加，所以上一次请求的 messages 是下一次请求 messages 的严格前缀，`input_tokens` 因此是一段真实测量的前缀长度。校准规则见 [context-management.md](context-management.md)。`cached_tokens` 按「已含在 `input_tokens` 内」处理，校准只取 `input_tokens`。

流内 `error` 对象不重试。先检查 `code` 或 `message` 是否匹配上下文超限，再检查限流 `code`，都不匹配时落到 `invalid_request`。流内错误没有 `Retry-After`。

HTTP 头的 `Retry-After` 写入 `retry_after_ms`。循环层决定是否使用，见 [errors-and-cancellation.md](errors-and-cancellation.md)。

## curl 传输

HTTP 与 TLS 统一走 `vendor:curl`。Windows 链接 Odin 随附的静态 libcurl。Linux 与 macOS 链接系统 libcurl，需要开发包。

| 选项 | 值或用途 |
| --- | --- |
| `CURLOPT_URL` | 拼好的 `/chat/completions` 地址 |
| `CURLOPT_POST`、`POSTFIELDS`、`POSTFIELDSIZE` | JSON 请求体 |
| `CURLOPT_HTTPHEADER` | 鉴权、内容类型、SSE 接受头 |
| `CURLOPT_WRITEFUNCTION` | 接收 SSE 或错误正文 |
| `CURLOPT_HEADERFUNCTION` | 解析状态码与 `Retry-After` |
| `CURLOPT_XFERINFOFUNCTION` | 轮询取消与首字节超时 |
| `CURLOPT_NOSIGNAL` | 禁止 libcurl 安装信号处理器 |
| `CURLOPT_ACCEPT_ENCODING` | `identity`，避免 SSE 被压缩缓冲 |
| `CURLOPT_HTTP_VERSION` | 固定 HTTP/1.1 |
| `CURLOPT_CONNECTTIMEOUT_MS` | 30000 |
| `CURLOPT_TIMEOUT_MS` | `llm_timeout_ms` |
| `CURLOPT_LOW_SPEED_LIMIT` | 1 字节 |
| `CURLOPT_LOW_SPEED_TIME` | 120 秒 |

进度回调在取消标志置位时返回非 0，中止请求。没有收到任何正文且超过 120 秒时也中止，并归类为 `timeout`。

libcurl 的全局初始化不是线程安全的。首次调用用互斥锁串行完成初始化。

## 非目标

- 不重试，不退避。循环层负责。
- 不支持 Anthropic Messages API。
- 不支持非流式 JSON 响应。
- 不计算 token 或运行 tokenizer。
- 不发送多模态内容。
- 不支持 prompt cache 的显式标记。

## 相关文档

- [errors-and-cancellation.md](errors-and-cancellation.md)：重试、取消与超时
- [context-management.md](context-management.md)：messages 与工具段的来源
- [react-loop-and-session.md](react-loop-and-session.md)：事件与 usage 的落盘
- [cli-and-config.md](cli-and-config.md)：`settings.json(c)` 中的 provider 字段
