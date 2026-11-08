# Pi RPC 模式复刻报告

参考源文件（都在本仓库）：

| 文件 | 作用 |
|---|---|
| `packages/coding-agent/docs/rpc.md` | 概览、生命周期、错误、关闭 |
| `packages/coding-agent/docs/rpc-commands.md` | 命令级参考 |
| `packages/coding-agent/docs/json.md` | 事件流参考（与 `--mode json` 共用） |
| `packages/coding-agent/docs/rpc-extension-ui.md` | 扩展 UI 子协议 |
| `packages/coding-agent/docs/message-types.md` / `session-format.md` | 载荷里的消息/条目结构 |
| `packages/coding-agent/src/modes/rpc/rpc-mode.ts`（819 行） | 服务端实现（唯一权威） |
| `packages/coding-agent/src/modes/rpc/rpc-types.ts`（303 行） | 协议 TS 类型定义 |
| `packages/coding-agent/src/modes/rpc/jsonl.ts`（58 行） | 帧格式 |
| `packages/coding-agent/src/modes/rpc/rpc-client.ts`（617 行） | 官方客户端（可当参考实现） |
| `packages/coding-agent/src/modes/json-event.ts` | 事件裁剪（去累积快照） |
| `packages/coding-agent/src/core/output-guard.ts` | stdout 独占 + 背压 |

---

## 1. 进程模型

RPC 模式不是网络服务，而是 **子进程 + stdin/stdout 管道上的双向 JSONL**。

启动：

```bash
pi --mode rpc [普通 CLI 参数]
```

关键启动行为（`src/main.ts`）：

- `--mode rpc` 强制 `appMode = "rpc"`，与 `--print`、`--json` 并列。
- **stdin 不会被当作提示内容读取**（普通模式下会 read piped stdin），stdin 完全留给协议。
- `@file` 参数在 rpc 模式被拒绝：`Error: @file arguments are not supported in RPC mode`，`exit 1`。
- 若无可用模型（没有 model 解析成功），`exit 1` 并往 stderr 打错误。
- 进入 rpc 后后台异步刷新模型目录（15s 超时），失败静默。
- **stdout 被“接管”**（`takeOverStdout()`）：应用内所有 `process.stdout.write` 被重定向到 **stderr**，真正的 stdout 只由 `writeRawStdout` 写协议记录。这是复刻时必须复现的隔离保证——否则任何库的 `print` 都会污染流。
- 启动过程不输出任何协议记录。客户端在发送第一条命令之前**收不到任何东西**（没有握手、没有 session header——这点与 `--mode json` 不同）。

进程标题被设为 `pi-rpc`（`src/rpc-entry.ts`）。

---

## 2. 帧格式（最容易被复刻错的部分）

规则（`jsonl.ts` 注释与实现）：

1. 一条记录 = 一个完整 JSON 对象 + 单个 `\n`。UTF-8。
2. **只按 `\n` 切分**。`U+2028`/`U+2029` 是合法 JSON 字符串内容，不是记录边界。因此 **不能**用 Node `readline`、Python `text.splitlines()`、Java `BufferedReader.readLine()`、Go `bufio.Scanner` + `ScanLines`?（`bufio.ScanLines` 只按 `\n` 切并去掉尾部 `\r`，是安全的；`Scanner` 的默认 token 也是 ScanLines，可以用，但要注意 64KB 行限制）。危险的是任何把 Unicode 行分隔符也当换行的实现。
3. 读入时若行尾是 `\r`，剥掉一个（容忍 CRLF）。输出永远只用 `\n`。
4. 流结束时缓冲区里剩余的非空内容作为最后一行投递（即允许最后一条记录无 `\n`）。
5. 分块边界可以落在 UTF-8 多字节序列中间——必须用带状态的 UTF-8 解码器（Node 的 `StringDecoder`）。
6. **背压双向都要处理**：服务端在写 stdout 后等待 drain；客户端不读会被阻塞。客户端写 stdin 也要遵守背压。stdout 被 `writeRawStdout` 用一条 promise 链串行化，记录不会交错。

最小分帧伪代码：

```
buf = ""
decode(chunk) -> buf += utf8decoder.write(chunk)
while (i = buf.indexOf('\n')) >= 0:
    line = buf[0:i]; buf = buf[i+1:]
    if line.endswith('\r'): line = line[:-1]
    dispatch(JSON.parse(line))
on eof:
    buf += utf8decoder.end()
    if buf != "": dispatch(buf)
```

注意：**空行**也会被投递到 `handleInputLine`，`JSON.parse("")` 抛错 → 返回一条 `command: "parse"` 的错误响应。复刻时建议显式跳过空行（更宽容），但要知道原实现不跳过。

---

## 3. 四类记录

| 方向 | 记录 | 判别 | 说明 |
|---|---|---|---|
| 客户端 → Pi | **命令** | 有 `type` 且不是 `extension_ui_response` | 33 种，见 §4 |
| Pi → 客户端 | **响应** | `type: "response"` | 每条命令 0 或 1 条 |
| Pi → 客户端 | **事件** | 其余 `type`（`agent_start`、`message_update`…） | 无 `id`（`bash_execution_update` 例外） |
| 双向 | **扩展 UI 记录** | `type: "extension_ui_request"` / `"extension_ui_response"` | 独立子协议 |

### 关联规则

- 命令可带可选字符串 `id`；响应原样回显。缺失时响应里 `id` 键**不出现**（JS 里 `undefined` 被 `JSON.stringify` 丢弃）。
- 命令处理是**并发异步**的：不要用“响应顺序 == 请求顺序”假设。必须按 `id` 关联。
- 事件通常**不带 `id`**；唯一例外 `bash_execution_update`，当触发它的 `bash` 命令带 `id` 时，事件也带同一 `id`。
- `extension_ui_response` 用请求方的 `id` 关联，**不产生** `response` 记录。

### 响应骨架

```json
{"id":"req-1","type":"response","command":"get_state","success":true,"data":{...}}
{"id":"req-2","type":"response","command":"set_model","success":false,"error":"Model not found: x/y"}
```

- 成功且无数据时**没有 `data` 键**（如 `abort`、`set_thinking_level`）。
- 有些成功响应 `data` 为 `null`（如 `cycle_model`、`cycle_thinking_level` 在无候选时）。
- 解析失败（无请求 id）：

```json
{"type":"response","command":"parse","success":false,"error":"Failed to parse command: ..."}
```

- 未知命令：`command` 字段等于请求里的 `type` 字符串，`error` 为 `Unknown command: <type>`，`id` 照常回显。

---

## 4. 命令全集（stdin）

`type` 值、参数、成功响应 `data`（`rpc-types.ts` + `rpc-mode.ts` 的 switch）。

### 4.1 提示输入

| type | 参数 | data | 备注 |
|---|---|---|---|
| `prompt` | `message: string`, `images?: ImageContent[]`, `streamingBehavior?: "steer" \| "followUp"` | `{disposition: "handled" \| "queued" \| "started"}` | 见 §6 |
| `steer` | `message`, `images?` | `{disposition: "handled" \| "queued"}` | 不允许扩展命令（`/cmd` 会报错） |
| `follow_up` | `message`, `images?` | 同上 | 同上 |
| `abort` | — | 无 | 等 `session.abort()` 完成后才响应 |
| `clear_queue` | — | `{steering: string[], followUp: string[]}` | 清空并返回文本 |
| `new_session` | `parentSession?: string` | `{cancelled: boolean}` | 扩展可取消 |

`ImageContent`：`{"type":"image","data":"<base64>","mimeType":"image/png"}`。Pi 会按模型限制重采样；失败图片被丢弃并以提示文本注入，不报错。

### 4.2 状态

| type | data |
|---|---|
| `get_state` | `RpcSessionState`（见下） |

```ts
interface RpcSessionState {
  model?: Model;                 // 完整 model 对象，无模型时省略
  thinkingLevel: "off"|"minimal"|"low"|"medium"|"high"|"xhigh"|"max";
  isStreaming: boolean;
  isCompacting: boolean;
  steeringMode: "all"|"one-at-a-time";
  followUpMode: "all"|"one-at-a-time";
  sessionFile?: string;
  sessionId: string;
  sessionName?: string;
  autoCompactionEnabled: boolean;
  messageCount: number;          // agent.state.messages.length
  pendingMessageCount: number;   // 队列中的 steer+followUp 数量
}
```

### 4.3 模型

| type | 参数 | data |
|---|---|---|
| `set_model` | `provider`, `modelId` | 完整 `Model` 对象；找不到则 `success:false` |
| `cycle_model` | — | `{model, thinkingLevel, isScoped} \| null` |
| `get_available_models` | — | `{models: Model[]}` |

`Model` 结构（`packages/ai/src/types.ts`，输出去掉 `headers` 等内部字段前请核对）：

```json
{"id":"claude-sonnet-4-20250514","name":"Claude Sonnet 4","api":"anthropic-messages",
 "provider":"anthropic","baseUrl":"https://api.anthropic.com","reasoning":true,
 "input":["text","image"],"contextWindow":200000,"maxTokens":16384,
 "cost":{"input":3.0,"output":15.0,"cacheRead":0.3,"cacheWrite":3.75}}
```

### 4.4 思考级别

| type | 参数 | data |
|---|---|---|
| `set_thinking_level` | `level` | 无（**不校验**，非法值也会被存下） |
| `cycle_thinking_level` | — | `{level} \| null` |
| `get_available_thinking_levels` | — | `{levels: ThinkingLevel[]}`，不支持推理的模型返回 `["off"]` |

### 4.5 队列模式

| type | 参数 | data |
|---|---|---|
| `set_steering_mode` | `mode: "all"\|"one-at-a-time"` | 无 |
| `set_follow_up_mode` | 同上 | 无 |

### 4.6 压缩 / 重试

| type | 参数 | data |
|---|---|---|
| `compact` | `customInstructions?: string` | `CompactionResult`（见下） |
| `set_auto_compaction` | `enabled: boolean` | 无 |
| `set_auto_retry` | `enabled: boolean` | 无 |
| `abort_retry` | — | 无 |

```ts
CompactionResult = {
  summary: string;
  firstKeptEntryId: string;
  tokensBefore: number;
  estimatedTokensAfter?: number;
  usage?: Usage;
  details?: unknown;
}
```

### 4.7 Bash

| type | 参数 | data |
|---|---|---|
| `bash` | `command: string`, `excludeFromContext?: boolean` | `BashResult` |
| `abort_bash` | — | 无 |

```ts
BashResult = {
  output: string;
  exitCode: number | undefined;
  cancelled: boolean;
  truncated: boolean;
  fullOutputPath?: string;
}
```

语义要点：命令**立即执行**并进入会话历史（`BashExecutionMessage`）；若 `excludeFromContext` 不为 true，下一次 `prompt` 时它会被转成 user 文本 `Ran \`cmd\`\n\`\`\`\n<output>\n\`\`\`` 发给模型。输出分片通过 `bash_execution_update` 事件实时流式输出（带命令 `id`）。扩展可以通过 `user_bash` 事件接管执行。

### 4.8 会话

| type | 参数 | data |
|---|---|---|
| `get_session_stats` | — | `SessionStats` |
| `export_html` | `outputPath?: string` | `{path}` |
| `switch_session` | `sessionPath` | `{cancelled}` |
| `fork` | `entryId` | `{text, cancelled}`（`text` 是被 fork 的用户消息文本；取消时可能只有 `cancelled`） |
| `clone` | — | `{cancelled}`；当前 leaf 为空时 `success:false` |
| `get_fork_messages` | — | `{messages: [{entryId, text}]}` |
| `get_entries` | `since?: string` | `{entries: SessionEntry[], leafId: string\|null}` |
| `get_tree` | — | `{tree: SessionTreeNode[], leafId}` |
| `get_last_assistant_text` | — | `{text: string\|null}` |
| `set_session_name` | `name` | 无；空字符串 → `success:false` |

`SessionStats`：

```json
{"sessionFile":"...","sessionId":"...","userMessages":5,"assistantMessages":5,
 "toolCalls":12,"toolResults":12,"totalMessages":22,
 "tokens":{"input":50000,"output":10000,"cacheRead":40000,"cacheWrite":5000,"total":105000},
 "cost":0.45,
 "contextUsage":{"tokens":60000,"contextWindow":200000,"percent":30}}
```

`contextUsage` 可缺失；`contextUsage.tokens/percent` 可为 `null`（刚压缩完、还没有新的 assistant usage）。

`get_entries` 的 `since` 是**排他游标**：`entries.slice(index(since)+1)`；`since` 找不到 → `success:false` + `Entry not found: <id>`。

### 4.9 消息与命令发现

| type | data |
|---|---|
| `get_messages` | `{messages: AgentMessage[]}` |
| `get_commands` | `{commands: RpcSlashCommand[]}` |

```ts
RpcSlashCommand = {
  name: string;                 // 不带前导 /
  description?: string;
  source: "extension" | "prompt" | "skill";
  sourceInfo: { path, source, scope, origin, baseDir? };
}
```

技能命令的 `name` 形如 `skill:foo`。内置 TUI 命令（`/settings` 等）不在此列。

---

## 5. 事件流（stdout）

事件是 `AgentSessionEvent`（`src/core/agent-session.ts:209`）的子集，经 `toJsonEvent()`（`src/modes/json-event.ts`）**只改 `message_update`** 一种，其余原样输出。

### 5.1 载荷裁剪规则（必须复刻）

- 丢弃 `message_update.message`（累积的 assistant 快照）。
- 丢弃 `assistantMessageEvent.partial`（每种 delta 事件都带的累积快照）。
- 保留 `message_update.usage`（最新累计 usage，体积恒定）。
- `toolcall_start` 额外补 `id`、`toolName`（从 `partial.content[contentIndex]` 提取）；若该索引不是 toolCall，服务端**抛错**。

因此线上 `message_update` 形状固定为：

```json
{"type":"message_update",
 "usage":{"input":100,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":101,
          "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},
 "assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hello "}}
```

`assistantMessageEvent` 的 `type` 取值及字段：

| type | 额外字段 |
|---|---|
| `start` | —（`partial` 被剥掉） |
| `text_start` / `thinking_start` | `contentIndex` |
| `text_delta` / `thinking_delta` | `contentIndex`, `delta` |
| `text_end` / `thinking_end` | `contentIndex`, `content`（权威全文） |
| `toolcall_start` | `contentIndex`, `id`, `toolName` |
| `toolcall_delta` | `contentIndex`, `delta`（序列化后的参数片段） |
| `toolcall_end` | `contentIndex`, `toolCall`（完整 ToolCall） |
| `done` | `reason`, `message` |
| `error` | `reason`, `error`（AssistantMessage） |

实践中 agent 循环会把 provider 的 `start/done/error` 翻译成 `message_start`/`message_end`，所以通常看到的前 9 种。复刻客户端时仍应容忍 `done`/`error` 出现在 `message_update` 里（导出类型允许）。

### 5.2 全部会话事件

Agent / turn：

| type | 字段 |
|---|---|
| `agent_start` | — |
| `agent_end` | `messages: AgentMessage[]`, `willRetry: boolean` |
| `agent_settled` | `aborted: boolean` |
| `turn_start` | — |
| `turn_end` | `message`, `toolResults: ToolResultMessage[]` |

消息：

| type | 字段 |
|---|---|
| `message_start` | `message` |
| `message_update` | `usage`, `assistantMessageEvent`（见上） |
| `message_end` | `message`（权威终态） |

工具执行（嵌套调用会多一个 `parentToolCallId`）：

| type | 字段 |
|---|---|
| `tool_execution_start` | `toolCallId`, `toolName`, `args`, `parentToolCallId?` |
| `tool_execution_update` | `toolCallId`, `toolName`, `args`, `partialResult`, `parentToolCallId?` |
| `tool_execution_end` | `toolCallId`, `toolName`, `result`, `isError`, `durationMs?`, `parentToolCallId?` |

队列与状态：

| type | 字段 |
|---|---|
| `queue_update` | `steering: string[]`, `followUp: string[]`（全量快照） |
| `entry_appended` | `entry: SessionEntry` |
| `session_info_changed` | `name?: string` |
| `thinking_level_changed` | `level` |

压缩：

| type | 字段 |
|---|---|
| `compaction_start` | `reason: "manual"\|"threshold"\|"overflow"` |
| `compaction_end` | `reason`, `result?: CompactionResult`, `aborted`, `willRetry`, `errorMessage?` |

重试：

| type | 字段 |
|---|---|
| `auto_retry_start` | `attempt`, `maxAttempts`, `delayMs`, `errorMessage` |
| `auto_retry_end` | `success`, `attempt`, `finalError?` |
| `summarization_retry_scheduled` | `attempt`, `maxAttempts`, `delayMs`, `errorMessage` |
| `summarization_retry_attempt_start` | `source: "compaction"\|"branchSummary"`（compaction 时还有 `reason`） |
| `summarization_retry_finished` | — |

RPC 专有：

| type | 字段 |
|---|---|
| `bash_execution_update` | `id?: string`, `delta: string` |
| `extension_error` | `extensionPath`, `event`, `error` |

`extension_error` 不来自 session 事件，而是 `bindExtensions({onError})` 回调里直接输出。

### 5.3 一次典型运行（记录顺序）

```json
{"type":"agent_start"}
{"type":"turn_start"}
{"type":"message_start","message":{"role":"user","content":"hi","timestamp":1733234401000}}
{"type":"message_end","message":{"role":"user", ...}}
{"type":"message_start","message":{"role":"assistant","content":[],"stopReason":"pending", ...}}
{"type":"message_update","usage":{...},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hello"}}
{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Hello"}],"stopReason":"stop", ...}}
{"type":"turn_end","message":{...},"toolResults":[]}
{"type":"agent_end","messages":[...],"willRetry":false}
{"type":"agent_settled","aborted":false}
```

工具调用轮次里，`tool_execution_*` 出现在 assistant 消息结束与下一轮 `message_start` 之间，`turn_end` 的 `toolResults` 收纳本轮结果。

---

## 6. 运行生命周期与状态机（复刻关键）

### `prompt` 的响应时机与语义

`prompt` 在 switch 里**不返回响应**（`return undefined`），而是异步启动 `session.prompt(...)` 并通过 `preflightResult` 回调在“预检点”输出响应：

```
preflightResult("handled")  ← 扩展命令命中，或 input handler 消费了输入
preflightResult("queued")   ← 运行中且有 streamingBehavior，已入队
preflightResult("started")  ← 模型/鉴权校验通过，运行即将开始
```

失败的三种情况：
- 运行中却未给 `streamingBehavior` → `success:false`，`error` 为 `"Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message."`
- 压缩进行中 → `"Cannot submit a prompt while compaction is in progress. ..."`
- 无模型 / 无凭据 → 相应错误文本

**`success:true` 只代表被接受**。之后的所有失败都走事件/消息流，不会再有第二条响应。

顺序陷阱：`queued` 的响应是在 `_queueSteer/_queueFollowUp`（会先发 `queue_update`）之后才输出，所以客户端可能先看到 `queue_update` 再看到 `response`。已入队后 `steer`/`follow_up` 同理。

### `agent_end` vs `agent_settled`

- `agent_end`：一次底层 agent run 结束。之后仍可能有自动重试、溢出恢复、压缩重试、steering、follow-up。
- `agent_settled`：Pi 不会再有自动后续工作。**客户端判断“跑完了”必须等这个**，它在扩展的 `agent_settled` 钩子之后发出，`aborted` 表示因 abort 结束。
- `RpcClient.waitForIdle()` / `collectEvents()` / `promptAndWait()` 都以 `agent_settled` 为准。

订阅必须在 `prompt` **之前**建立，否则可能错过快速完成的事件。

### abort

`abort` 会 `await session.abort()` 再响应；`agent_settled` 带 `aborted: true`。要模拟 Esc 行为：先 `clear_queue`（拿回被排队文本以便回填编辑器），再 `abort`。

### 关闭

| 触发 | 行为 |
|---|---|
| stdin EOF / close | `shutdown(0)`：dispose runtime、解绑监听、flush stdout、`exit 0` |
| `SIGTERM` | 杀子进程组内 tracked detached children，`exit 143`（不 flush，因为信号路径要快） |
| `SIGHUP`（非 Windows） | 同上，`exit 129` |
| 扩展 `ctx.shutdown()` | 置标志位；在当前命令处理完或当前 run 发出 `agent_settled` 后关闭 |

客户端应把“stdin 关闭”当作有序关闭请求，但仍要处理进程被信号杀死、崩溃、提前 exit 的情况（`RpcClient` 把这些映射为 pending 请求的 rejection）。

---

## 7. 扩展 UI 子协议

用于扩展的 `ctx.ui.*`。在 rpc 模式下 `ctx.mode === "rpc"` 且 `ctx.hasUI === true`（因为有这个子协议）。

### 请求（Pi → 客户端），都带 `type: "extension_ui_request"`、唯一 `id`、`method`

阻塞型（需要响应）：

| method | 字段 | 期望响应 |
|---|---|---|
| `select` | `title`, `options: string[]`, `timeout?` | `{value: string}` 或 `{cancelled:true}` |
| `confirm` | `title`, `message`, `timeout?` | `{confirmed: boolean}` 或 `{cancelled:true}` |
| `input` | `title`, `placeholder?`, `timeout?` | `{value: string}` 或 `{cancelled:true}` |
| `editor` | `title`, `prefill?` | `{value: string}` 或 `{cancelled:true}` |

单向（不需要、也不应期待响应）：

| method | 字段 |
|---|---|
| `notify` | `message`, `notifyType?: "info"\|"warning"\|"error"`（缺省 info） |
| `setStatus` | `statusKey`, `statusText: string \| undefined`（undefined/缺失=清除） |
| `setWidget` | `widgetKey`, `widgetLines: string[] \| undefined`, `widgetPlacement?: "aboveEditor"\|"belowEditor"` |
| `setTitle` | `title` |
| `set_editor_text` | `text` |

### 响应（客户端 → Pi）

```json
{"type":"extension_ui_response","id":"uuid-1","value":"Allow"}
{"type":"extension_ui_response","id":"uuid-2","confirmed":true}
{"type":"extension_ui_response","id":"uuid-3","cancelled":true}
```

服务端行为：

- 用 `id` 在 `pendingExtensionRequests` 里查；**未知 id 静默忽略**（不回错误）。
- `select` 的 `value` **不做校验**，原样交给扩展（客户端应回传选项字符串）。
- `cancelled:true` → extension 收到 `undefined`（select/input/editor）或 `false`（confirm）。
- 超时/中止在 **Pi 侧**处理：`timeout` 到期或 AbortSignal 触发时以默认值（`undefined`/`false`）resolve，客户端无需自己计时。
- `editor` 是特例：**不支持 timeout/abort**（走的是裸 promise 路径），请求里也没有 `timeout` 字段。

### RPC 下受限/降级的 UI 方法

`custom()`→`undefined`；`onTerminalInput()`→空 no-op；`setWorkingMessage/setWorkingVisible/setWorkingIndicator/setHiddenThinkingLabel/setFooter/setHeader/addAutocompleteProvider/setEditorComponent/setToolsExpanded` 全 no-op；`getEditorText()`→`""`；`getToolsExpanded()`→`false`；`pasteToEditor()`→转 `set_editor_text`；`getAllThemes()`→`[]`；`getTheme()`→`undefined`；`setTheme()`→`{success:false,...}`；`setWidget()` 只支持 `string[]`，工厂函数被忽略。

---

## 8. 复刻时的坑清单

1. **分帧**：只用 `\n`；剥一个尾部 `\r`；带状态 UTF-8 解码；EOF 时 flush 残余。
2. **stdout 纯净**：自己进程内任何日志都要走 stderr；协议写出要串行化（单写者 + 队列），并处理 ENOBUFS/EAGAIN 重试与 drain。原实现在 `writeRawStdout` 里对 `ENOBUFS/EAGAIN/EWOULDBLOCK` 做 10ms 重试。
3. **背压**：写 stdout 后等待可写；事件密集时（`text_delta`）也不能无界缓冲。
4. **不要假设响应顺序**：命令处理是 async 并发的（`prompt` 甚至是 fire-and-forget）。按 `id` 关联，`id` 缺失的响应只可能是 `parse` 错误（或迟到事件）。
5. **`id` 省略语义**：序列化时 `undefined` 字段必须消失，不要输出 `"id":null`。
6. **事件不带 `id`**（除 `bash_execution_update`）；`extension_ui_request` 的 `id` 是 UUID，与命令 `id` 空间无关。
7. **等 `agent_settled` 而不是 `agent_end`**；`disposition === "handled"` 时根本不会有 run，不要等。
8. **订阅早于 prompt**，否则可能丢事件。
9. **容忍未知事件/未知字段**：扩展可注入自定义消息角色（declaration merging），`entry_appended` 的 entry 类型是开放集合（`usage`、`context_edit`、`custom` 等）。遇到未知 `kind`/`type` 按普通数据保留，不要丢弃整个会话。
10. **不要解析 stderr**：stderr 是诊断/启动计时/警告（`printTimings` 只写 stderr），不是协议。
11. **错误边界**（原实现的边界，不必照抄）：把 JSON 字面量 `null` 写到 stdin 会走 `handleCommand(null)`，catch 分支再取 `command.id` 二次抛错 → 未捕获 rejection，Node 默认会终止进程。复刻实现应当把非对象输入统一回一条 `parse` 错误响应，更稳。
12. **空行**会被当成 JSON 解析失败而产生一条 `parse` 错误响应（原实现如此），客户端不应发送空行。
13. **`set_thinking_level` 不校验值**，`select` 的 `value` 不校验；别指望服务端兜错。
14. **bash 的 `id` 回显**：只有在命令里带了 `id`，`bash_execution_update` 才带 `id`。
15. **`get_entries since` 是排他游标**，适合做跨重启的增量同步；`get_tree` 可能返回多个根（导航/断链）。
16. **进程启动无握手**：不要等 banner；第一条命令可直接发。启动失败（无模型、`@file`）以 stderr + 非零退出码体现。

---

## 9. 复刻建议的最小骨架

**客户端（任意语言）**

```
spawn(pi, ["--mode", "rpc", ...args])           # stdin/stdout = pipe, stderr = 日志
reader: 严格 LF 分帧 -> JSON 解析
  -> type == "response" && id in pending: 完成对应 future/回调
  -> type == "extension_ui_request": 交给 UI 层，按 method 决定是否回 extension_ui_response
  -> else: 派发给事件监听器（按 type 分发）
writer: 命令 = 分配 id（如 req_N），序列化 JSON + "\n"，尊重背压；pending[id] 带超时

promptAndWait(text):
    先注册 "agent_settled" 监听
    disposition = prompt(text)          # "handled" 时立即返回
    若 disposition != "handled": 等 agent_settled（带超时）
```

**服务端（若你要用别的语言重写 Pi 本身）** 只需复现：JSONL 框架 + 33 个命令的语义映射 + 事件发射点（agent/turn/message/tool/queue/compaction/retry）+ 扩展 UI 请求/响应表 + 关闭流程。真正的复杂度不在协议，而在被包装的 agent 循环：`prompt` 的 disposition 三分支、`agent_end` / `agent_settled` 的区分、steering/follow-up 队列与模式、压缩与重试状态机。

---

## 10. 校验过的行为细节（代码级）

- `get_state.messageCount = session.messages.length`（= `agent.state.messages`，含 system/bashExecution/custom 等所有角色）。
- `pendingMessageCount = _steeringMessages.length + _followUpMessages.length`。
- `queue_update` 每次队列变化都发全量快照。
- `tool_execution_end.durationMs` 用单调时钟测量 `execute()` 耗时，工具没跑时缺失。
- `bash` 若扩展的 `user_bash` 事件返回了结果，则由扩展结果直接 `recordBashResult` 并响应，不执行真实命令。
- 流式期间 `recordBashResult` 会把 `BashExecutionMessage` 延后到 `agent_end` 才写入，避免破坏 tool_use/tool_result 顺序。
- `new_session` / `switch_session` / `fork` / `clone` 成功后都会重新 `rebindSession()`：解绑旧事件订阅、绑定新 session、重建扩展 UI 上下文。客户端视角是“事件来源变了”，无需重连。
- `get_last_assistant_text` 返回 `null` 表示没有 assistant 文本。
