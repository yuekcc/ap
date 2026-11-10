# 上下文组装

本文件定义 system prompt 的组成、`$AP_CONFIG/SYSTEM.md` 与 `AGENTS.md` 的读取、技能清单位置，以及 transcript 到 provider messages 的投影。事件 schema 见 [react-loop-and-session.md](react-loop-and-session.md)，blob 的存储格式见 [tools.md](tools.md)，provider 请求字段见 [provider.md](provider.md)。

## system prompt 的三段

`build_system_prompt` 按固定顺序拼接三段：

1. **base**：SDK 内置的 `ap-core/engine/prompts/system.md` 文本。编译期由 `#load` 内嵌，运行时不读取该文件。
2. **工具段**：`## 工具` 标题加注册表生成的工具说明。
3. **应用层 sections**：`ap-cli` 按顺序传入的原始 Markdown 块。

拼接规则：

- 先写 base。base 不以 `\n` 结尾时补一个。
- 写 `\n## 工具\n`，再写工具段，再写一个 `\n`。
- 每个非空 section 前写一个 `\n`。section 不以 `\n` 结尾时补一个。
- 空字符串 section 跳过。

SDK 不解析应用层 section，不给它加标题，不合并空白，也不改写它的内容。

## $AP_CONFIG/SYSTEM.md

文件存在时，`ap-cli` 用它替换 base，工具段与应用层 sections 照常拼接。

1. 文件由 `ap-cli` 读取。SDK 只接收规范化后的文本。
2. 规范化规则：CRLF 与单独 CR 转成 LF，去掉首尾空白，结尾恰好一个 `\n`。内部空行与缩进保留。
3. 文件不可读、不是合法 UTF-8 或规范化后为空时，退出 2。
4. 只影响新 session。恢复与 fork 使用冻结值。
5. 没有清空全部提示词的模式。环境、工具说明等小节始终保留。

`--print-system-prompt` 打印完整组装结果，不创建 session，不调用模型。与 `-s` 或 `-c` 连用时打印冻结的 prompt。行为见 [cli-and-config.md](cli-and-config.md)。

## 应用层 sections

默认顺序由 `ap-cli/prompt.odin` 的 `build_prompt_sections` 决定。

| 顺序 | 标题 | 内容来源 | 条件 |
| --- | --- | --- | --- |
| 1 | `## 环境` | OS、cwd、当前时间、是否在 git 仓库 | 总是出现 |
| 2 | `## 可用技能` | 技能清单块 | 有技能且未传 `--no-skills` |
| 3 | `## 全局记忆 (AGENTS.md)` | `~/.agents/AGENTS.md` | 未传 `--no-agents-md`，文件存在 |
| 4 | `## 项目记忆 (<file>)` | 每个项目 `AGENTS.md` | 未传 `--no-agents-md`，文件存在 |
| 5 | `## Agent 定义 (<name>)` | agent 文件的正文 | 正文非空 |
| 6 | `## 追加指令` | `Prompt_Options.append_prompt` | 非空。当前 CLI 不设置该字段 |

环境段逐行写 `OS`、`cwd`、`当前时间`、`git 仓库`。时间取新 session 组装时的时刻，之后随 system prompt 冻结。

记忆文件按文件原文注入，内容外包一层 `<global_agent_md>` 或 `<project_agent_md>` 标签，标题后和标签前后各留一个空行，便于模型区分记忆边界。agent 正文去掉开头换行后注入。两者都不做 CRLF 规范化，不截断，不做 `@import`。只有 `SYSTEM.md` 经过规范化。

## AGENTS.md 发现

全局记忆固定为 `~/.agents/AGENTS.md`。不存在时跳过。它与全局技能共用 `~/.agents`。

项目记忆从启动目录向上查找 `AGENTS.md`：

1. 目录链从 cwd 开始，包含 cwd。
2. 当前目录或其祖先存在 `.git` 时，链到该目录为止并包含它。否则一直到文件系统根。
3. 目录名以 `.` 开头的层级不读取其中的 `AGENTS.md`。
4. 只接受名为 `AGENTS.md` 的普通文件。不读取子目录。
5. 收集顺序是近到远。按规范化后的物理路径去重，保留更近的那份。最终反转为远到近注入。

同一个物理文件只出现一次。符号链接与 junction 在去重前解析。

注入顺序是远到近，近的文件排在后面。约定冲突时以更近的文件为准。记忆与固定指令冲突时以固定指令为准。这两条是提示词层约定，代码不强制。

`--no-agents-md` 同时关闭全局与项目记忆，system prompt 中不出现这两个小节，也不产生相关 warning。它不改变磁盘上的文件，不是沙箱。

## 技能清单

技能清单只放元数据，正文不进入 system prompt。

- 位置：`~/.agents/skills/<name>/SKILL.md` 与 `<启动目录>/.agents/skills/<name>/SKILL.md`。同名时项目级覆盖全局级。
- 清单块由一段读取说明加 `<available_skills>` 组成。每个条目只有 `name`、`description`、`location`。
- `disable-model-invocation: true` 的技能不进入清单。
- 没有任何可用技能，或传了 `--no-skills` 时，整个小节省略。
- 技能发现、`SKILL.md` 格式与 `--list-skills` 见 [skills.md](skills.md)。

清单块整体放进 `## 可用技能`。模型按 `location` 用 `read_file` 或 `bash` 读取正文。

## Agent 定义段

agent 文件的正文以 `## Agent 定义 (<name>)` 追加。正文只补充指令，不替换 base、工具段、环境或记忆。agent 的 `tools:`、`model`、`max_steps` 不进入这一段。定义解析与工具白名单见 [subagents.md](subagents.md)。

## 工具段

工具段与 provider 请求里的 `tools` 使用同一个生效工具集。

- 顺序按注册表声明顺序，不按名字排序。
- 每个工具写 `### <name>`、描述、`参数 JSON Schema: <json>`。
- 生效工具为零时，工具段只有 `（本次没有可用工具）`。provider 请求省略 `tools` 字段。
- 工具定义的结构见 [tools.md](tools.md)。

## 冻结与预览

新 session 只组装一次 system prompt。结果写入 `session_start.content`。超过 `blob_threshold_bytes` 时改写 `content_ref` 与 `content_bytes`。

`context_build` 每个 step 从 transcript 读取最后一个 `session_start`，不重新读取 `SYSTEM.md`、agent 文件、记忆文件或技能目录。恢复与 fork 因此得到同一份冻结 prompt。

`--print-system-prompt` 与新 session 共用同一条组装路径，但不写 transcript，不调用模型。恢复时它读取冻结值。

## transcript 到 messages

`context_build` 是纯函数。同一 transcript 与同一 project 必须得到逐字节相同的 messages。它不调用 LLM，不压缩，不写 transcript，不重新扫描记忆或技能。

带预算的投影是 `(transcript, budget)` 的纯函数：`context_build_budgeted` 额外接收工具定义估算值与两个显式参数，不读环境、不读时钟、不做 IO 决策。详见下文「token 预算」与「工具结果省略」。

Provider 请求中的 messages 由一条 `role=system` 消息加投影结果组成。system 消息的内容来自最后一个 `session_start`。

| 事件 | 投影 |
| --- | --- |
| `user_message` | 一条 `role=user` 消息 |
| `message_end`，`stop_reason` 不是 `cancelled` | 一条 `role=assistant` 消息 |
| `tool_execution_end` | 一条 `role=tool` 消息，跟在要求它的 assistant 消息后 |
| `session_start` | 不进入 messages，只提供 system prompt |
| `handoff` | 不进入 messages，只提供交接文档 |
| `message_start`、`step_start`、`turn_start`、`turn_end`、`error`、`cancel`、`session_end` | 忽略 |

assistant 消息的构造规则：

1. 遍历 `content` 块。`text` 块按出现顺序收集，非空文本用 `\n` 连接为 `content`。
2. `tool_use` 块必须有非空 `id` 与 `name`，并且存在同 id 的 `tool_execution_end`。否则丢弃该块。
3. 没有任何可用文本与 `tool_use` 的 assistant 消息不提交。
4. 有 `reasoning` 时写入 `reasoning_content`。
5. `tool_calls` 按 `tool_use` 块在消息内的顺序排列。`arguments` 是参数对象的 JSON 字符串。
6. 每个保留的 `tool_call` 后立即追加一条 `role=tool` 消息，顺序与 `tool_calls` 相同。

## blob 解析

投影前从 project 的 blob 目录解析引用。预览永不进入上下文。

- `text_ref`：读出完整文本，作为 `text` 块。
- `input_ref`：读出后按 JSON 解析，作为工具参数。解析失败视为上下文错误。
- `content_ref`：读出完整内容，作为 tool result。
- `session_start.content` 为空时，用 `content_ref` 还原 system prompt。

blob 缺失、sha256 不匹配或读取失败时，组装返回 `.Usage` 错误，不静默降级。system prompt 的 blob 在打开 session 时失败。其它 blob 在第一个 step 失败。两者都退出 2。

## 配对与合并

1. 先按 `tool_call_id` 收集全部 `tool_execution_end`。重复 id 以后出现者为准。
2. 每个 `tool_use` 只与同 id 的结果配对。没有结果的 `tool_use` 删除。
3. 孤立的结果不被使用。它不会产生 tool 消息，也不会写修复事件。
4. `stop_reason=cancelled` 的 assistant 消息整体跳过。它的 tool result 因此成为孤立结果。
5. 连续的 `user` 消息合并。两边都有内容时用 `\n` 连接，否则保留有内容的一条。
6. 连续的 `assistant` 消息合并。两边都有非空文本时用 `\n` 连接。左边没有内容时取右边。`reasoning_content` 同理。`tool_calls` 依次追加。
7. `tool` 消息不合并，也不与其它角色合并。
8. 合并只发生在投影结果里，不修改 transcript。

## tool result 内容

- `ok: true`：使用 `content` 或 `content_ref` 的完整内容。空内容就是空字符串。
- `ok: false`：使用 `error`。`error` 缺失时写 `tool failed`。存在部分输出时，在错误文本后用 `\n` 拼接内容。
- `metadata`、`duration_ms`、`exit_code` 不进入 messages。

## token 预算

ap 面向 1M 上下文、64K 单次输出的模型。预算默认开启，`context_window_tokens` 默认 `1048576`。

### 目标计算

```
target  = context_window_tokens - max_tokens - reserve
reserve = context_window_tokens * context_reserve_percent / 100
```

- `max_tokens` 取本次请求的值，每个 turn 可能不同。
- `reserve` 是预算的安全垫，`context_reserve_percent` 是它占**窗口**的百分比，默认 `5`，取值 `0`–`100`。`0` 表示不留余量。
- 基准是窗口而不是 `max_tokens`：`max_tokens` 已经是输出的硬上限，输出不可能超过它，不再需要额外余量；真正会漂移的是输入侧的本地 token 估算，它的偏差正比于输入规模。所以余量跟着窗口走，`--max-tokens` 变化不影响余量。
- `handoff_max_tokens` 是生成交接文档那次调用的输出上限，默认 `16384`。它是绝对的 token 数，必须为正，与 `--max-tokens` 无关。
- 按默认值算：`reserve = 1048576 * 5 / 100 = 52428`，`target = 1048576 - 65536 - 52428 = 930412`。
- 把 `max_tokens` 改成 `8192` 时余量不变，`target = 1048576 - 8192 - 52428`。
- 窄窗口也能开预算：窗口 `70000`、`max_tokens` `65536`、5% 余量时 `reserve = 3500`，`target = 964`。
- `context_window_tokens = 0` 表示关闭预算，`target` 不参与任何决策，行为回到不计算 token 的版本。
- 预算开启而 `target <= 0` 是配置错误。配置文件（`settings.jsonc` 优先）的静态冲突（窗口不大于 `max_tokens` 或 `handoff_max_tokens`、`max_tokens + reserve` 吃掉整个窗口）在启动时退出 2；运行期算出的 `target <= 0` 写 `error(scope=session)` 并以 `.Usage` 结束。

估算对象是**整个请求**：system prompt + 全部 messages + 工具定义 JSON。三者都计入 `input_tokens`，分开算会漏。

### 本地估算

```
estimate_tokens(s) = ceil(ascii_bytes(s) / 4) + ceil(non_ascii_bytes(s) / 3)
```

逐字节统计类别，再对每条消息加固定结构开销（每条消息 4 token，每个 tool call 8 token）。工具定义按名字、描述与参数 JSON 估算。函数是纯的、无状态的，可单测。估算只用于「接近预算时怎么决策」，不追求绝对值准确。

### usage 校准

transcript 只追加，所以第 N 步发出的 messages 一定是第 N+1 步 messages 的前缀。上一次调用的 `input_tokens` 因此是一段真实测量的前缀长度。

1. Loop 记录 `last_request_estimate`（上次发请求前的本地估算）与 `last_observed_input`（上次 `message_end.usage.input_tokens`）。
2. `ratio_percent = last_observed_input * 100 / last_request_estimate`，钳制到 `[CALIBRATION_MIN_PERCENT, CALIBRATION_MAX_PERCENT]`，即 `[50, 200]`。
3. `estimated = estimate_tokens(当前请求) * ratio_percent / 100`。
4. 没有任何观测值时 `ratio_percent = 100`。两个观测值每个 turn 开始时清零，因为新 turn 的第一份 messages 与上一 turn 的请求已经不再是前缀关系。

校准值属于 Loop 运行态，不进 transcript。它只影响传入的估算结果，不影响投影规则本身，因此 `context_build_budgeted` 仍然可复现。校准结果写入 `turn_end.context.calibration_percent`。

### 触发决策

每个 step 计算一次，顺序固定：

1. 用不省略的投影估算 `estimated`。
2. `estimated * 100 < target * HANDOFF_TRIGGER_PERCENT`（90%）→ 直接发请求。
3. 否则先省略工具结果（见下节），把 `estimated'` 压向 `target * CONTEXT_ELIDE_TARGET_PERCENT`（80%）。省略是廉价尝试：不调模型、不新建 session。
4. `estimated' * 100 < target * 90%` → 用省略后的投影发请求，stderr 写一行 `[context] elided N tool results, ~M tokens saved`。
5. 仍 `>= target * 90%` → 进入交接流程。

90% 是唯一的决策阈值。80% 只是省略的收敛目标，决定一次省略把水位压到多低。

### 观测

`turn_end` 的可选字段 `context` 记录本 turn 最后一次 step 决策后的值。`context_window_tokens = 0` 时整个字段为 `null`。字段定义见 [react-loop-and-session.md](react-loop-and-session.md)。

## 工具结果省略

在没有对话压缩的前提下，最早占满窗口的一定是工具输出。省略把较早的工具输出在**投影层**替换成固定桩文本，对话文本不动。

### 候选与排除

省略在 `tool_result_content_in` 之后、写入 message 之前生效。候选是 `role=tool` 消息，按消息列表顺序遍历，依次应用：

1. `tool_execution_end.ok == false` 的结果不省略。错误文本是模型纠错的主要依据，且通常很短。
2. 解析后内容字节数 `< ELIDE_MIN_BYTES`（`2048`）的结果不省略。
3. 从末尾倒数的 `ELIDE_KEEP_RECENT_RESULTS`（`6`）个候选不省略。
4. 其余按**从旧到新**顺序逐个省略，直到估算落到目标以内或候选耗尽。

字节数按解析后的内容长度计算，与 `content` / `content_ref` 无关：两种存储形式必须得到同样的判定，否则阈值边界上会出现不确定行为。

### 桩文本

```
[tool output elided: <tool_name>, <bytes> bytes. Re-run the tool or re-read the file if you need it again.]
```

`tool_name` 来自配对成功的 assistant `tool_calls`，`bytes` 是解析后的内容字节数。不含时间、不含 `seq`、不含「第几步」，因此同一 transcript 在任何精度下都算出同一段文本。

### 不变式

- **确定性**：同一 `(events, tools_tokens, limit_tokens, calibration_percent)` 必须产出逐字节相同的 messages。候选遍历用消息列表顺序，不用 map 迭代顺序。
- **单调**：省略集合只随 events 增长而变大。最旧优先、target 固定的算法天然满足。
- **成对结构不变**：只改 tool 消息的 `content`，不动 assistant 的 `tool_calls`、消息条数与顺序。
- **校验不变**：省略前仍按现有规则解析 blob、校验 sha256，失败照样返回 `.Usage`。省略不跳过任何校验。
- **不省略时等价**：`limit_tokens <= 0` 时 `context_build_budgeted` 的 messages 与 `context_build` 逐字节相同。

### prompt cache 代价

省略会让被省略位置之后的整个前缀失效，provider 的 `cached_tokens` 会明显下降。缓解方式是阈值设计本身：90% 触发、一次性压到 80%，把「每增长 1% 就重排」摊成大约每消耗 10% 窗口才动一次；省略从最旧开始，让尾部连续区域一次性重新预热。成本可观测：`turn_end.context.elided_bytes` 配合 `usage.cached_tokens` 直接看。

不采用「优先省略最新结果」的变体：最新结果恰好是模型最可能在用的，语义损失大于成本收益。

## handoff

上下文真的不够用时，用一次不带工具的模型调用生成交接文档，再由 CLI 起一个新 session 承载它。

### 触发条件

| 场景 | `reason` | 行为 |
| --- | --- | --- |
| 省略后仍超 `target` | `budget_exhausted` | 不调 provider 主请求，直接生成交接 |
| provider 第二次返回 `context_too_long` | `context_too_long` | 先收紧预算重算重发一次，仍超限才生成交接 |
| 用户传 `--handoff` | `manual` | 直接生成交接，不跑 turn |

`context_window_tokens = 0`、`--no-handoff` 或 `agent_depth > 0` 时只有 `--handoff` 一条路径生效。子代理的职责是回一个结论，不是开新 session。

### 生成交接文档

一次独立的 provider 调用，不带工具，不进入 ReAct 循环。

- 提示词：`ap-core/engine/prompts/handoff.md`，编译期 `#load` 内嵌，与 `system.md` 同机制。
- system 消息 = 本 session 冻结的 system prompt + `\n` + `handoff.md` 全文。拼在后面而不是替换：技能清单与 `AGENTS.md` 硬约束只在冻结 prompt 里；冻结 prompt 是稳定前缀，与主请求共用同一段字节。
- messages = 省略后的投影，加上可选的聚焦提示词（`--handoff "<prompt>"` 的那段文本）作为最后一条 `user` 消息。投影的预算是 `context_window_tokens - handoff_max_tokens - reserve`，其中 `reserve` 是同一个窗口余量（默认 `52428`）；system 消息本身也计入。
- `max_tokens = handoff_max_tokens`（默认 `16384`），不取 `--max-tokens`。`include_usage` 跟随 `stream_include_usage`。
- 只尝试一次，不重试。失败时写 `error(scope=llm, kind=<原错误>, message="handoff failed: ...")` 并按 `--no-handoff` 的路径结束。
- 输出正文直接作为交接文档，不改写、不重排、不加包装。输出为空视为失败。

提示词的四条硬要求：不重复其他产物（只给路径或 URL）、必须脱敏、列出建议技能（带 `location`）、按聚焦提示词调整侧重。小节结构写进提示词，代码不校验：交接是尽力而为的产物，强制结构只会让它编造内容填坑。

### 事件

新增持久事件 `handoff`，字段见 [react-loop-and-session.md](react-loop-and-session.md)。它同时登记进 `event_type_known` 与 `event_type_canonical`，恢复时保留，投影时忽略。`handoff.usage` 计入 `session_end.usage`。

### 新 session

CLI adapter 在拿到交接文本后创建新 session。引擎不参与。

- 新 session 走正常 new session 路径：重新组装 system prompt，用当前工具集、当前模型、当前 `AGENTS.md` 与技能。**不是 fork**，不复制 transcript，不冻结源 session 的任何值。
- 第一条事件是 `user_message`，内容为 `## 上一会话交接
来源 session: <id>

<交接文档正文>`。
- `ap -s <id> --handoff "<prompt>"` 会在新 session 里继续跑这个 turn；`ap -s <id> --handoff` 只创建新 session 并打印它的 id。传了 prompt 时它同时是交接的聚焦提示与第一个 turn，用同一条文本。
- 判定「这条 user_message 是交接」靠文本首行，不加新字段。

## context_too_long

关闭自动交接时行为不变：provider 返回 `context_too_long` 是上下文超限的唯一出口。识别规则见 [provider.md](provider.md)。

1. 不重试。
2. 写 `error(scope=llm, kind=context_too_long, retryable=false)`。消息固定为 `context too long; start a new session or reduce input`。
3. 写 `turn_end(stop_reason=context_too_long)`。
4. 本次 turn 的 `result_text` 保留最后一个 assistant 文本。
5. `ap-cli` 写 `session_end(reason=error)`，退出 3。

开启自动交接时，这条路径只在交接自身失败后退回使用。纠正顺序见 [errors-and-cancellation.md](errors-and-cancellation.md)。

## 相关文档

- [react-loop-and-session.md](react-loop-and-session.md)：事件 schema、`handoff` 事件、恢复与 fork
- [errors-and-cancellation.md](errors-and-cancellation.md)：`context_too_long` 的纠正路径与交接失败
- [cli-and-config.md](cli-and-config.md)：`--context-window`、`--handoff`、`--no-handoff`
- [provider.md](provider.md)：请求格式与 `context_too_long` 识别
- [skills.md](skills.md)：技能发现与 `SKILL.md` 格式
- [subagents.md](subagents.md)：agent 定义与工具白名单
- [tools.md](tools.md)：工具契约与 blob
