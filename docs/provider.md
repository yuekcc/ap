# LLM Provider

v1 只支持 **OpenAI chat completions 兼容接口**。Provider 的职责只有两件：

1. 把统一请求翻译成 `POST {base_url}/chat/completions`，并把 SSE 流解析成统一事件
2. 把 HTTP/API 错误翻译成统一错误类型

Provider **不做**：重试、退避、中断决策、上下文管理、token 计数。这些在循环层（见 [errors-and-cancellation.md](errors-and-cancellation.md)）。

## 接口

```
Provider :: struct { ... }

provider_stream :: proc(
    p:      ^Provider,
    req:    ^Request,
    sink:   Stream_Sink,
    cancel: ^Cancel_Token,
) -> Error
```

Odin 没有 async/await，流式用回调 + 阻塞 IO 实现。下面的事件是 **Provider 内部协议**；Loop 负责把它翻译成 transcript 事件，以及 `stream-json` 的 `message_update` / `tool_execution_update`。

`sink` 回调：

- `on_message_start(model)`
- `on_text_delta(text)`
- `on_reasoning_delta(text)`
- `on_tool_call_start(index, id, name)`
- `on_tool_call_delta(index, args_delta)`
- `on_tool_call_end(index)`
- `on_message_end(stop_reason, usage)`
- `on_error(kind, message, retryable, retry_after_ms)`

## 请求

```jsonc
{
  "model": "<model_id>",
  "messages": [
    {"role": "system", "content": "<system prompt>"},
    {"role": "user", "content": "..."},
    {"role": "assistant", "content": null,
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
  "max_tokens": 8192,
  "stream": true,
  "stream_options": {"include_usage": true}
}
```

约定：

1. system prompt 固定放在 `messages[0]`，`role=system`
2. `parallel_tool_calls` 固定 false：ap 串行执行工具，不希望模型一次返回大量调用
3. `stream_include_usage=true` 时才发送 `stream_options`；不支持的服务端可在配置里关掉
4. `max_tokens` 使用旧字段（兼容自建服务）；不发送 `max_completion_tokens`
5. `tools[].function.parameters` 是 JSON Schema，由 Tool Registry 生成
6. 每个 tool result 是一条独立的 `role=tool` 消息；多个结果按 tool call 顺序排列
7. `base_url` 去掉尾部 `/`；如果已经以 `/chat/completions` 结尾则直接使用，否则追加 `/chat/completions`

## 流式事件

| 事件 | 字段 | 说明 |
| --- | --- | --- |
| `message_start` | `model` | 收到首个有效 chunk 时发一次 |
| `text_delta` | `text` | `choices[0].delta.content` |
| `reasoning_delta` | `text` | `choices[0].delta.reasoning_content`（模型支持时） |
| `tool_call_start` | `index, id, name` | 一个 tool call 开始 |
| `tool_call_delta` | `index, args_delta` | 参数 JSON 片段，只拼接不解析 |
| `tool_call_end` | `index` | 参数收齐，此时解析 JSON |
| `message_end` | `stop_reason, usage` | 流结束 |
| `error` | `kind, message, retryable, retry_after_ms` | 出错终止 |

### tool call 组装

OpenAI 的流式 tool call 有三个坑，必须按下面的规则处理：

1. 后续 chunk 可能只有 `index`，没有 `id` / `name`；**按 `index` 建槽**，不要只按 id 累积
2. `id` 和 `name` 可能只在第一个片段出现；后续片段只追加 `function.arguments`
3. 收到 `finish_reason=tool_calls` 或流结束时，对每个槽解析参数 JSON；解析失败是协议错误（`retryable=false`）

缺少 `tool_call_end` 就断流 → 视为流中断，丢弃该 tool call。

### 其它规则

1. `message_end` 必须恰好一次；重复或缺失都算协议错误
2. `choices` 只取第一个；`n>1` 不支持
3. usage 可能出现在最后一个 `choices` 为空的 chunk 里；没有就写 null
4. `delta.content` 可能为 null；不要当成空字符串事件
5. 推理内容只用于展示和记录，不进入下一轮上下文

## stop_reason 归一化

| 统一值 | OpenAI `finish_reason` | 循环层处理 |
| --- | --- | --- |
| `stop` | `stop` / `content_filter` | 结束 turn；`content_filter` 额外在 stderr 警告 |
| `tool_use` | `tool_calls` | 执行工具，进入下一 step |
| `max_tokens` | `length` | 结束 turn，`stop_reason=max_tokens` |

`finish_reason` 缺失或未知 → 协议错误。

## usage

```js
{
  input_tokens: 0,       // prompt_tokens
  output_tokens: 0,      // completion_tokens
  cached_tokens: 0,      // prompt_tokens_details.cached_tokens
  reasoning_tokens: 0,   // completion_tokens_details.reasoning_tokens
  total_tokens: 0        // total_tokens
}
```

流式拿不到 usage 时所有字段为 null，不要写 0。没有 token 预算，usage 只用于记录与展示。

## 错误映射

| HTTP / 情况 | 统一 kind | retryable |
| --- | --- | --- |
| 401 / 403 | `auth` | false |
| 404 模型不存在 | `model_not_found` | false |
| 400 参数错误 | `invalid_request` | false |
| 400 `context_length_exceeded` / 等价 message | `context_too_long` | false |
| 429 | `rate_limit` | true（带 `retry_after_ms`） |
| 500 / 502 / 503 / 504 | `server_error` | true |
| 连接失败 / 连接超时 | `network` | true |
| 读超时 / 首字节超时 | `timeout` | true |
| SSE 解析失败 / 结构非法 / 参数 JSON 非法 | `protocol` | false |

错误体按 `{"error":{"message","type","code"}}` 解析；`context_too_long` 靠 `code` 与 message 子串双重匹配。

## 传输层：vendor:curl

Odin 的 `core:net` 没有 HTTP/TLS 客户端，统一使用 `vendor:curl`。

### 平台差异

- **Windows**：链接随 Odin 分发的静态 `lib/libcurl.lib`（8.17.0，Schannel，系统 CA）。可保持单 exe
- **Linux / macOS**：绑定链接系统 libcurl（`system:curl`）。发布说明必须写清构建/运行依赖；若要单二进制，需要自带静态 libcurl

### 关键选项

| 选项 | 用途 |
| --- | --- |
| `CURLOPT_URL` | `{base_url}/chat/completions` |
| `CURLOPT_POST` / `CURLOPT_POSTFIELDS` | JSON 请求体 |
| `CURLOPT_HTTPHEADER` | `Authorization: Bearer <key>`、`Content-Type: application/json`、`Accept: text/event-stream` |
| `CURLOPT_WRITEFUNCTION` | 接收 SSE 字节流，写入行缓冲 |
| `CURLOPT_XFERINFOFUNCTION` | 轮询取消标志；返回非 0 中止请求 |
| `CURLOPT_NOSIGNAL` | 禁止 libcurl 安装信号处理器 |
| `CURLOPT_CONNECTTIMEOUT_MS` | 连接超时，默认 30s |
| `CURLOPT_TIMEOUT_MS` | 单次请求总超时，来自 `llm_timeout_ms` |
| `CURLOPT_LOW_SPEED_LIMIT` / `LOW_SPEED_TIME` | 首字节/低速超时：1 字节 / 120s |
| `CURLOPT_ACCEPT_ENCODING` | 设为 identity，避免 SSE 被压缩缓冲 |
| `CURLOPT_HTTP_VERSION` | 固定 HTTP/1.1，减少代理兼容问题 |

### SSE 解析

1. 按 `\n` 切行；去掉行尾 `\r`
2. 忽略空行和 `:` 开头的注释行
3. 只处理 `data:` 前缀；`data: [DONE]` 结束
4. 一个 chunk 可能包含多行，也可能一行被拆成多个 chunk；缓冲区必须跨回调保留
5. 增量文本按 UTF-8 解码时保留不完整的多字节序列
6. 连接关闭但没看到 `[DONE]` → `network` 或 `protocol`，由循环层按流中断处理

### 取消

`Cancel_Token` 是原子布尔。`XFERINFOFUNCTION` 每次回调检查：

- 已取消 → 返回非 0，libcurl 以 `CURLE_ABORTED_BY_CALLBACK` 退出
- 超过首字节时限 / 总时限 → 同样中止，映射成 `timeout`

不要在信号处理器里直接调用 curl；信号处理器只设置标志。

## 配置

```jsonc
{
  "model": "<model_id>",
  "base_url": "https://api.openai.com/v1",
  "api_key": "<api_key>",
  "max_tokens": 8192,
  "llm_timeout_ms": 600000,
  "stream_include_usage": true
}
```

1. `api_key` 可被 `AP_API_KEY` 覆盖；不写日志、不写 transcript
2. 鉴权头固定 `Authorization: Bearer`
3. 代理走 libcurl 的 `http_proxy` / `https_proxy` / `no_proxy`
4. 不硬编码官方域名，`base_url` 可指向 vLLM、one-api 等自建服务

## 不做的事

- 不重试、不实现退避（循环层负责）
- 不支持 Anthropic Messages API
- 不支持 prompt cache 的显式标记
- 不做 token 计数或 tokenizer 估算
- 不支持原生多模态输入
- 不提供 capabilities 协商；能力差异按“OpenAI 兼容”这一档处理
