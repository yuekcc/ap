# 提案：上下文预算、工具结果省略与 handoff

状态：已实现。正文已并入 [context-management.md](../context-management.md)、[react-loop-and-session.md](../react-loop-and-session.md)、[cli-and-config.md](../cli-and-config.md)、[provider.md](../provider.md) 与 [errors-and-cancellation.md](../errors-and-cancellation.md)；本文件只保留决策理由与被否决的方案。代码入口：`ap-core/engine/budget.odin`、`ap-core/engine/handoff.odin`、`ap-core/engine/prompts/handoff.md`、`ap-cli/run.odin`。

## 目标

当前 `context_too_long` 是上下文超限的唯一出口：不重试、不压缩、直接退出 3。一个长任务跑到一半就不可继续。本提案加三件事，按批次独立可验证：

1. **token 预算**：本地估算请求大小，用 provider 返回的 `usage` 校准，在超过预算前给出可观测的预警。
2. **工具结果省略**：超预算时把较早的工具输出在投影层替换成固定桩文本，对话文本不动。
3. **handoff**：上下文真的不够用时，用一次不带工具的模型调用生成交接文档，由 CLI 起一个新 session 承载它，然后继续干活。

## 非目标

- 不做对话历史摘要压缩（原计划第 3 步）。省略只在工具结果上生效，assistant 文本与 user 提示词永不改写。
- 不做向量检索、外部记忆库、消息级淘汰。
- 不做自动删减 system prompt 或工具 schema。它们超预算时只能 handoff。
- 不引入 tokenizer 依赖。只做字节启发式加 usage 校准。
- 不改工具契约、不加新工具、不加审批。

## 现状要点

- `context_build(project, events)` 从完整 transcript 投影 messages，是纯函数。见 [context-management.md](../context-management.md)。
- 大工具结果已写 blob，投影时解析 `content_ref`；blob 缺失视为 `.Usage` 错误，不静默降级。
- `turn_end.usage` 只累加本 turn；`session_end.usage` 由 `historical_usage_from_events` 汇总全部 `turn_end`。
- 退出码 3 覆盖 `context_too_long`。见 [cli-and-config.md](../cli-and-config.md)。

## 契约修订

三处需要显式修订，其余契约不变。

1. **`context_build` 的纯函数定义改为「(transcript, budget) 的纯函数」。**
   新增 `context_build_budgeted(project, events, policy, limit_tokens)`；`limit_tokens` 由调用方显式传入，不从环境读、不读时钟、不做 IO 决策。原 `context_build` 保留，等价于 `limit_tokens = max_int`（不省略），因此现有测试与现有行为逐字节不变。
   `limit_tokens` 在每个 step 内固定，跨 turn 只在 `max_tokens` 变化时变化，所以同一 transcript 配同一 policy 仍然完全可复现。
2. **省略不跳过 blob 校验。**
   被省略的工具结果仍然解析 blob、校验 sha256，只在投影成文本时替换成桩。blob 缺失依旧让组装失败。这样「不静默降级」不变，省略是显式的、可复现的投影选择。
3. **handoff 是追加事件，不修改历史。**
   生成结果写成一条新的 `handoff` 事件，原始 `message_end`、`tool_execution_end`、`user_message` 一律不动。

另外一条实现边界：**引擎只负责产交接文本并写 `handoff` 事件，创建新 session 由 CLI adapter 负责。** 引擎不读 argv、不决定退出码、不组装 system prompt，符合现有分层。

## 一、token 预算

### 配置

`settings.json` 新增三个字段，`Settings` 对应新增三个字段。

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `context_window_tokens` | `1048576` | 模型窗口大小。ap 面向 1M 上下文设计，预算与自动交接默认启用；`0` 表示关闭，行为回到当前版本 |
| `context_reserve_tokens` | `32768` | 为输出波动、估算误差留的余量，参与目标计算。按 64K 输出上限的一半取 |
| `handoff_max_tokens` | `16384` | 生成交接文档那次调用的 `max_tokens`。交接文本不需要 64K |

三个字段都在实现时接入了 `settings.json` 与 `Settings`。`context_reserve_tokens` 与 `handoff_max_tokens` 的缺省值来自 `ap-core/engine/config.odin` 的 `DEFAULT_CONTEXT_RESERVE_TOKENS` 与 `DEFAULT_HANDOFF_MAX_TOKENS`；采纳的方案是让它们可配置，理由见下方「待定」第 7 条。

常量，不进配置：

| 常量 | 值 | 理由 |
| --- | --- | --- |
| `HANDOFF_TRIGGER_PERCENT` | `90` | `estimated` 达到 `target` 的 90% 就进入上下文管理流程（先省略，仍超阈则 handoff） |
| `CONTEXT_ELIDE_TARGET_PERCENT` | `80` | 触发后先尝试把 `estimated` 降到 80%，避免一步之内直接交接 |
| `ELIDE_KEEP_RECENT_RESULTS` | `6` | 最近 6 个工具结果永不省略 |
| `ELIDE_MIN_BYTES` | `2048` | 小结果省略收益低于噪声成本 |
| `ESTIMATE_ASCII_DIVISOR` | `4` | ASCII 字节数除 4 |
| `ESTIMATE_NON_ASCII_DIVISOR` | `3` | 非 ASCII 字节数除 3，UTF-8 中日韩约 3 字节 1 token |
| `CALIBRATION_MIN_PERCENT` | `50` | 校准系数下限，防估算函数退化 |
| `CALIBRATION_MAX_PERCENT` | `200` | 校准系数上限，防脏 usage 带偏 |

`context_window_tokens` 关闭时，`context_reserve_tokens` 与 `handoff_max_tokens` 都不生效。

`context_window_tokens` 的默认值 `1048576` 与 `ap-core` 的 `DEFAULT_CONTEXT_WINDOW_TOKENS` 一致，已经随「面向 1M 上下文、64K 输出」的规格落到 `ap-core/engine/config.odin` 与 `settings.example.json`。**预算与自动交接默认启用**，不需要用户额外开关；不想要自动交接时用 `--no-handoff`，完全关掉整套上下文管理时把 `context_window_tokens` 设为 `0`。

预算逻辑（估算、校准、省略、交接）尚未实现。实现前这个字段只被读取和校验，不影响投影与请求。

### 目标计算

```
target = context_window_tokens - max_tokens - context_reserve_tokens
```

- `max_tokens` 取本次请求的值（每个 turn 可能不同）。
- 按默认值算：`1048576 - 65536 - 32768 = 950272`。
- `target <= 0` 时视为配置错误，退出 2。
- 估算对象是**整个请求**：system prompt + 全部 messages + 工具定义 JSON。三者都计入 `input_tokens`，分开算会漏。

### 本地估算

```
estimate_tokens(s) = ceil(ascii_bytes(s) / 4) + ceil(non_ascii_bytes(s) / 3)
```

逐字符统计字节类别，对每个字符串求和，再对 messages 的结构字段加固定小开销（每条消息 4 token，每个 tool_call 8 token）。函数是纯的、无状态的，可单测。

估算只用于「接近预算时怎么决策」，不追求绝对值准确。

### usage 校准

transcript 只追加，所以第 N 步发出的 messages 一定是第 N+1 步 messages 的前缀。这让上一次调用的 `input_tokens` 成为一段真实测量的前缀长度。

Loop 保存两个值：

- `last_request_estimate`：上次发请求前的本地估算总和。
- `last_observed_input`：上次 `message_end.usage` 的输入 token 数。取 `input_tokens`；若 `cached_tokens` 存在且与 `input_tokens` 语义上不重叠（协议当前按「已含在 input_tokens 内」处理），只取 `input_tokens`。

```
ratio_percent = last_observed_input * 100 / last_request_estimate
ratio_percent = clamp(ratio_percent, 50, 200)
estimated = estimate_tokens(当前请求) * ratio_percent / 100
```

没有任何观测值时 `ratio_percent = 100`。ratio 在每个成功响应后更新一次，写入 `turn_end.context.calibration_percent`。

校准值属于 Loop 运行态，不进 transcript，因此不破坏 `context_build` 的纯函数性：它只影响传入的 `limit_tokens`，不影响投影规则本身。

### 触发决策

每个 step 计算一次，顺序固定，只有一个阈值：

1. 用不省略的投影估算 `estimated`。
2. `estimated * 100 < target * HANDOFF_TRIGGER_PERCENT` → 直接用，记 `elided_results = 0`。
3. 否则先走省略流程（第二节），得到新的投影与 `estimated'`，目标是把 `estimated'` 降到 `target * CONTEXT_ELIDE_TARGET_PERCENT`。省略是廉价尝试：不调模型、不新建 session。
4. 省略后 `estimated' * 100 < target * HANDOFF_TRIGGER_PERCENT` → 用省略后的投影发请求，stderr 写一行进度：`[context] elided N tool results, ~M tokens saved`。
5. 省略后仍 `>= target * HANDOFF_TRIGGER_PERCENT` → 进入 handoff 流程（第三节）。

90% 是唯一的决策阈值。`CONTEXT_ELIDE_TARGET_PERCENT = 80` 只是省略的收敛目标，不是独立的触发点：它决定一次省略把水位压到多低，决定是否交接的仍然是 90%。

### 观测

`turn_end` 新增可选字段 `context`：

```json
"context": {
  "estimated_tokens": 121340,
  "limit_tokens": 180000,
  "elided_results": 4,
  "elided_bytes": 183422,
  "calibration_percent": 103
}
```

- 取本 turn 最后一次 step 决策后的值。`context_window_tokens = 0` 时整个字段输出 `null`。
- 字段只进 transcript 与 `json`/`stream-json` 输出，不进 messages。
- 旧版本读新 transcript 时忽略未知字段，不受影响。

## 二、工具结果省略

### 候选与排除

省略在 `tool_result_content_in` 之后、写入 message 之前生效。候选是 `role=tool` 消息，按消息列表顺序遍历。

按顺序应用排除规则：

1. `tool_execution_end.ok == false` 的结果不省略。错误文本是模型纠错的主要依据，且通常很短。
2. 内容字节数 `< ELIDE_MIN_BYTES` 的结果不省略。
3. 从末尾倒数的 `ELIDE_KEEP_RECENT_RESULTS` 个候选不省略。
4. 其余按**从旧到新**顺序逐个省略，直到 `estimated' <= target * CONTEXT_ELIDE_TARGET_PERCENT`，或候选耗尽。

单条结果的「字节数」按解析后的内容长度计算，和 `content_ref` / `content` 无关——两种存储形式必须得到同样的判定，否则阈值边界上会出现不确定行为。

### 桩文本

固定格式，只含确定性字段：

```
[tool output elided: <tool_name>, <bytes> bytes. Re-run the tool or re-read the file if you need it again.]
```

- `tool_name` 来自配对成功的 assistant `tool_calls`。
- `bytes` 是解析后的内容字节数。
- 不含时间、不含 `seq`、不含「第几步」，避免同一 transcript 在不同精度下算出不同文本。
- 语言与 system prompt 其余部分一致用英文，模型不需要为桩切换语种。

### 不变式

- **确定性**：同一 `(events, policy, limit_tokens)` 必须产出逐字节相同的 messages。桩文本、省略集合、顺序都不能依赖分配器顺序或 map 迭代顺序。候选遍历用消息列表顺序，不用 map。
- **单调**：省略集合只随 events 增长而变大，不会把已省略的结果还原。原因是 `target` 固定、估算随内容增长，最旧优先的算法天然满足。
- **成对结构不变**：省略只改 tool 消息的 `content`，不动 assistant 的 `tool_calls`，不动消息条数与顺序。tool call 与 tool result 的配对关系不受影响。
- **校验不变**：省略前仍按现有规则解析 blob、校验 sha256，失败照样返回 `.Usage`。
- **前缀稳定**：最后 `ELIDE_KEEP_RECENT_RESULTS` 个结果与被省略部分之间的边界，在同一 turn 内只在省略集合变大时移动。

### prompt cache 代价

省略会让被省略位置之后的整个前缀失效，provider 的 `cached_tokens` 会明显下降。三条缓解：

1. 触发点设在 90%、一次性降到 80%，把「每增长 1% 就重新排一次」摊成大约每消耗 10% 窗口才动一次。
2. 省略从最旧开始，被改动的边界尽量靠前，一次性让尾部连续区域重新预热。
3. 成本可观测：`turn_end.context.elided_bytes` 与 `usage.cached_tokens` 一起看，能直接评估这笔账。

不采用「优先省略最新结果」的变体。它让缓存边界更靠后，但最新结果恰好是模型最可能在用的，语义损失大于成本收益。

## 三、handoff

### 触发条件

| 场景 | `reason` | 行为 |
| --- | --- | --- |
| 省略后仍超 `target` | `budget_exhausted` | 不调 provider 主请求，直接生成交接 |
| provider 返回 `context_too_long` | `context_too_long` | 先强制重算一次，仍超限才生成交接 |
| 用户传 `--handoff` | `manual` | 直接生成交接，不跑 turn |

`context_window_tokens = 0` 时只有 `--handoff` 一条路径生效。此时 provider 返回 `context_too_long` 维持现状：写 `error`、`turn_end`、退出 3，不做交接。

### provider 返回 context_too_long 时的纠正路径

估算失误时不该直接放弃：

1. 第一次收到 `context_too_long`：把 `limit_tokens` 临时设为 `target * CONTEXT_ELIDE_TARGET_PERCENT / 2`，重新省略投影，再发一次同一 step 的请求。此过程不写 `error` 事件、不增加 step、不写 `turn_end`，只在 stderr 写一行 `[context] provider rejected request as too long; recomputing with tighter budget`。
2. 第二次仍 `context_too_long`：进入 handoff 流程。
3. `--no-handoff` 或 `agent_depth > 0`：不重算也不交接，维持现状（写 `error`、`turn_end(stop_reason=context_too_long)`、退出 3）。

### 生成交接文档

一次独立的 provider 调用，不带工具，不进入 ReAct 循环。

- 提示词：`ap-core/engine/prompts/handoff.md`（设计见下），编译期 `#load` 内嵌，与 `system.md` 同机制。
- system 消息 = 本 session 冻结的 system prompt + `\n` + `handoff.md` 全文。拼在**后面**而不是替换：
  - 「建议技能」需要技能清单（`name`、`location`），它只在冻结 prompt 里；
  - `AGENTS.md` 里的硬约束能被模型直接引用，比让它从对话里反推准确；
  - 冻结 prompt 是稳定前缀，与主请求共用同一段字节。本次不带 `tools`，所以缓存不一定全部命中，但也不会因为改写前缀而全量失效。
- messages = **省略后的投影**（不是完整 transcript，模型也读不完）。用同一套省略规则，把 `limit_tokens` 设为 `context_window_tokens - handoff_max_tokens - context_reserve_tokens`；system 消息本身也计入这个预算。
- 可选的聚焦提示词：`--handoff "<prompt>"` 的 prompt 作为最后一条 `user` 消息附上，告诉模型下一次会话要做什么。同一条文本随后也是新 session 的第一个 turn，不需要两份（见「新 session」）。
- `max_tokens = handoff_max_tokens`，`include_usage` 跟随 `stream_include_usage`。
- 只尝试一次，不重试。失败时写 `error(scope=llm, kind=<原错误>, message="handoff failed: ...")` 并按现有路径结束（`--no-handoff` 的行为）。
- 输出正文直接作为交接文档，不改写、不重排、不加包装。输出为空视为失败。

### 交接提示词的取舍

`handoff.md` 参照本机 `agent-things/skills/handoff/SKILL.md` 的写法，保留四条核心要求，改掉与 ap 不兼容的部分。

保留：

1. **不重复其他产物。** 已经写在文件、提交、diff、规格里的内容，只给路径或 URL，不抄一遍。这是控制交接文档长度最有效的一条，也避免交接后两份事实开始漂移。
2. **脱敏。** API key、口令、token、PII 一律替换为占位符。交接文档要进 transcript、进下一个 session 的上下文、可能被前端展示，比临时文件泄露面更大。
3. **建议技能。** 列出下一个 agent 该读哪几个 `SKILL.md`。ap 只有元数据清单，正文要 `read_file`，所以必须带 `location`。
4. **按目标定制。** 有聚焦提示词时按它调整侧重。

改掉：

- 参考文件让模型把文档写到临时目录。ap 不写文件：正文直接作为 `handoff` 事件的内容，由 CLI 注入新 session 的首条 `user_message`。让模型选路径只会引入失败面（目录不可写、路径不一致）。
- 参考文件面向有 Skill 工具的宿主。ap 没有该工具，只能给出 `name` 与 `location`。
- 参考文件是给人手动调用的技能，不限制篇幅。自动交接可能在没有用户确认的情况下发生，所以要显式要求「不复述对话」「不确定就写不确定」。

### `prompts/handoff.md` 正文

```markdown
你负责把上文这段即将结束的对话压缩成一份交接文档，交给一个全新的 agent 继续这段工作。

输出约定：

- 只输出交接文档正文，Markdown。不要前言、不要「好的，以下是」之类的包装，不要写文件，不要调用工具。
- 用中文。代码标识符、路径、命令保持原文。
- 不重复其他产物已经记录的内容。规格、计划、ADR、issue、commit、diff、代码本身，一律只给路径或 URL 加一句话说明，不要抄录。
- 必须脱敏。API key、口令、token、cookie、私钥、真实姓名、邮箱、内部主机名，一律替换为 <已脱敏>。宁可漏写，也不要泄露。
- 只写可验证的事实。对话里没有结论的地方写「不确定」，不要推测补全。
- 按下面的小节输出，没有内容的小节省略。不要复述对话过程，只留结论与状态。

## 任务目标

用户最初要什么。原话里的硬约束、禁止事项、验收标准必须完整保留，这是下一个 agent 最容易被摘要丢掉的东西。

## 当前状态

已完成什么、正在做什么、卡在哪里。已完成的部分说明验证到什么程度：跑过什么命令、结果是什么。

## 未完成

还差什么。每条写清阻塞点，以及需要谁或什么信息才能推进。

## 关键文件

每个文件一行：`<路径>` —— 为什么重要（改过什么、还差什么）。

## 决策与约束

已经定下的选择与理由，包括被否决的方案。目的是让下一个 agent 不要重新推翻已经讨论过的结论。

## 下一步

具体的、可执行的下一步，按优先级排列。写清预期结果，不要写「继续完善」这类无法验收的说法。

## 建议技能

下一个 agent 应该读的技能，每个一行：`<name>` —— `location` —— 为什么需要。
```

小节标题写进提示词，代码不校验结构。模型少写或写错小节不算失败：交接文档是尽力而为的产物，强制结构只会让它编造内容来填坑。

### 事件

新增持久事件类型 `handoff`。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `v`、`seq`、`ts`、`type` | 信封 | `type` 固定为 `handoff` |
| `reason` | string | `budget_exhausted`、`context_too_long` 或 `manual` |
| `content` | string | 交接文档正文。写入 blob 时为空串 |
| `content_ref` | string | blob 引用，可选 |
| `content_bytes` | int | 正文字节数，可选 |
| `content_preview` | string | 预览，可选 |
| `usage` | usage | 这次交接调用本身的用量；未调用时为全 `null` |
| `source_events` | int | 参与投影的 transcript 事件数，仅诊断用 |

- 写入顺序遵循 blob 先写后引用：先写 blob 并 fsync，再追加事件。
- `handoff` 必须同时登记进 `protocol.event_type_known` 与 `event_type_canonical`，否则恢复时会被当未知事件丢掉。
- `handoff.usage` 计入 `session_end.usage`：`historical_usage_from_events` 除了 `turn_end` 也累加 `handoff`。放在事件里而不是塞进 `turn_end.usage`，是因为 manual handoff 没有 turn。
- 同一 session 可以有多条 `handoff`，恢复时全部保留，投影忽略它们（它们不是 messages）。

### 新 session

CLI adapter 在拿到交接文本后创建新 session。引擎不参与。

- 新 session 走正常 new session 路径：重新组装 system prompt，用当前工具集、当前模型、当前 `AGENTS.md` 与技能。**不是 fork**，不复制 transcript，不冻结源 session 的任何值。
- 新 session 的第一条事件是 `user_message`，内容为：

```
## 上一会话交接
来源 session: <source_session_id>

<交接文档正文>
```

- 之后的行为取决于调用方式：`ap -s <id> --handoff "<prompt>"` 会在新 session 里继续跑这个 turn；`ap -s <id> --handoff` 只创建新 session 并打印它的 id。传了 prompt 时它同时是交接文档的聚焦提示与新 session 的第一个 turn，两处用同一条文本。
- 判定「这条 user_message 是交接」不靠新字段判断，靠文本首行。加字段会让 `session_start` 承担不属于它的语义，也会让旧前端误解析。

### CLI 与输出

新增参数：

| 参数 | 说明 |
| --- | --- |
| `--context-window <n>` | 覆盖 `settings.json` 的 `context_window_tokens`。`0` 表示关闭 |
| `--handoff` | 立即生成交接并创建新 session。必须与 `-s`、`-c` 或 `--fork-session` 之一连用，否则退出 2 |
| `--no-handoff` | 关闭自动交接。`context_too_long` 恢复为退出 3 |

- `--handoff` 与 `--print-system-prompt` 互斥，退出 2。
- 源 session 没有任何 `user_message` 时 `--handoff` 退出 2。
- 子代理进程不传 `--handoff`、不传 `--no-handoff`；自动交接在 `agent_depth > 0` 时禁用。子代理的职责是回一个结论，不是开新 session。
- `magi` 直接调 `apcore`，启用预算但不启用交接。任一角色上下文超限按该角色失败处理，沿用现有「成员失败按否决」语义。

`stop_reason` 新增取值 `handoff`。

| 结束路径 | `turn_end.stop_reason` | `session_end.reason` | 退出码 |
| --- | --- | --- | --- |
| 交接成功 | `handoff` | `exit` | 0 |
| 交接失败（生成失败或 `--no-handoff`） | `context_too_long` | `error` | 3 |

退回真实失败时保留现有 `error(kind=context_too_long)` 事件。

`--output-format json` 新增顶层字段（其余字段不变）：

```json
"handoff": {
  "reason": "budget_exhausted",
  "session_id": "20260101-a1b2c3d4",
  "content": "...",
  "usage": { ... }
}
```

无交接时该字段为 `null`。`text` 格式不打印交接文档，只把新 session id 写到 stderr：`handoff created session <id>`。`stream-json` 照常转发 `handoff` 事件，前端可选择展示或忽略。

### 前端影响

本提案不要求 `ap-tui` 与 `ap-web` 变更。`handoff` 事件是新的 transcript 事件类型，两者的解析路径都忽略未知类型；`stop_reason=handoff` 需要它们不要再当错误处理——这是必须核对的一处，见测试计划。后续可选增强（另开提案）：TUI 显示交接摘要并提示切换 session，Web 的 turn 结束卡片加「继续」按钮。

## 一次 turn 的完整决策流程

```
turn 开始
  写入 user_message、turn_start
  循环 step:
    写入 step_start
    messages = 不省略投影
    estimated = calibrate(estimate(system + messages + tools))
    if context_window_tokens == 0:
        发请求（现状）
    elif estimated * 100 < target * 90:
        发请求
    else:
        messages' = 省略投影(降到 target * 80)
        if estimate(system + messages' + tools) * 100 < target * 90:
            发请求（用 messages'）
        else:
            生成 handoff → 写 handoff 事件 → turn_end(handoff) → 退出循环
    if provider 返回 context_too_long:
        if 首次 and 允许交接: 收紧预算重算 → 重发同一 step
        else if 允许交接: 生成 handoff → …
        else: 现状（error + turn_end(context_too_long)）
    执行工具 / 结束 turn（现状）
CLI: stop_reason == handoff 时创建携带交接文本的新 session
```

## 兼容性

- **不升 `SCHEMA_VERSION`。** 新增事件类型与新增 `stop_reason` 取值都是加性的：旧读取方通过 `event_type_known` 跳过未知事件类型，`stop_reason` 是字符串原样透传。升版本会让旧版本直接拒绝整个 transcript，代价远大于收益。破坏性变更（改字段语义、删字段）才升版本。
- **新版本读旧 transcript**：没有 `handoff` 事件、没有 `turn_end.context`，投影结果与当前逐字节相同。
- **旧版本读新 transcript**：跳过 `handoff` 事件，`turn_end.context` 作为未知字段忽略，`stop_reason=handoff` 出现在 `json` 输出里但旧代码不识别——这是已知且可接受的降级，文档需写明。
- **`settings.json` 新增键**：旧版本按现有规则 warning 并忽略。反过来，旧 `settings.json` 缺这些键时取默认值。**默认 `context_window_tokens = 1048576` 意味着预算与自动交接默认开启**，这是有意选择：ap 面向 1M 上下文模型设计，默认值就该与模型能力一致，让用户少配一个字段。需要旧行为的用户显式写 `"context_window_tokens": 0` 或传 `--no-handoff`。
- **`max_tokens` 默认值同时从 8192 改为 65536**。这是同一个规格调整的一部分：64K 输出上限、90% 预算阈值、`context_reserve_tokens = 32768` 都是围绕同一规格确定的，单独改其中一项会让预算公式失去意义。旧配置显式写了 `max_tokens` 的不受影响。
- **`--context-window 0` 与不传不等价**：不传时取配置值（默认 `1048576`，预算开启）；`--context-window 0` 显式关闭预算。

## 测试计划

引擎（`odin test ap-core/engine`）：

- 估算函数：纯 ASCII、纯 CJK、混合、空串、`ceil` 边界。
- 校准：无观测值时为 100；`ratio` 上下限钳制；观测值退化（0、异常大）时不崩。
- 不省略投影 = 现状：`context_window_tokens = 0` 或 `limit_tokens = max_int` 时，`context_build_budgeted` 与 `context_build` 的 `messages_bytes` 逐字节相同（golden 回归）。
- 确定性：同一 `(events, policy, limit)` 连算两次结果逐字节相同；打乱内部 map 迭代顺序不影响结果（用多次构造验证）。
- 排除规则：`ok=false`、小于 `ELIDE_MIN_BYTES`、最近 `ELIDE_KEEP_RECENT_RESULTS` 个都不被省略。
- 省略顺序：从旧到新；只省略到目标比例即停止。
- 单调：追加事件后已省略集合仍是子集关系。
- `content` 与 `content_ref` 两种存储形式的判定一致。
- 被省略结果的 blob 缺失仍然失败（`.Usage`）。
- 桩文本逐字节固定（防格式化漂移）。
- `context_too_long` 纠正路径：假 provider 第一次返回超限、第二次成功 → 无 `error` 事件、step 数不变。
- 纠正两次都失败 → 走交接。
- `--no-handoff` 与 `agent_depth > 0` → 维持现状，退出路径与事件序列不变。
- 交接成功：`handoff` 事件字段完整、blob 先于事件、`stop_reason=handoff`。
- 交接调用：system 消息是「冻结 prompt + `handoff.md`」，且不以 `tools` 字段 出现；请求里省略 `tools`。
- 交接调用的 `max_tokens` 等于 `handoff_max_tokens`，不取 `--max-tokens`。
- 交接生成失败 → `error` + `turn_end(context_too_long)`。
- `handoff.usage` 计入 `session_end.usage`。
- `turn_end.context` 数值正确，关闭预算时为 `null`。
- `handoff` 事件能被 `event_type_known` 认出，恢复后仍在，且不影响投影。

CLI（`odin test ap-cli`）：

- `--context-window` 解析、`0` 语义、非法值退出 2。
- `--handoff` 参数校验：缺 `-s/-c`、与 `--print-system-prompt` 连用、源 session 为空 → 退出 2。
- `--handoff` 创建的新 session：`session_start` 是新组装的（不是源 session 的冻结值），第一条 `user_message` 含来源 session id 与交接正文。
- `--handoff "<prompt>"` 在新 session 里跑该 turn，`json` 输出里 `handoff.session_id` 指向它。
- 交接成功时退出 0 且 `stop_reason=handoff`；`--no-handoff` 时退出 3。
- `text` 格式下交接文档不进 stdout，新 session id 进 stderr。
- 子代理启动参数不含 `--handoff`。

前端与集成：核对 `ap-tui`、`ap-web` 对 `stop_reason=handoff` 不做错误处理（读代码 + 必要时补最小测试）。`npm --prefix ap-web test` 若有解析相关用例需同步。

## 需要同步的文档与代码

| 位置 | 改动 |
| --- | --- |
| `ap-core/engine/config.odin`、`ap-cli/settings.odin` | 三个新字段、`known_setting_keys`、默认值与校验 |
| `ap-core/engine/context.odin` | 估算、省略投影、`context_build_budgeted` |
| `ap-core/engine/prompts/handoff.md` | 新增，编译期内嵌。正文见「第三章」，含脱敏、不重复其他产物、建议技能三条硬要求 |
| `ap-core/engine/loop.odin` | 预算决策、纠正路径、交接调用、`turn_end.context` |
| `ap-core/engine/session.odin` | manual handoff 入口、`session_end.usage` 汇总 |
| `ap-core/protocol/events.odin`、`names.odin` | `handoff` 事件、`stop_reason=handoff`、`turn_end.context` |
| `ap-core/sdk.odin`、`ap-cli/options.odin`、`ap-cli/run.odin`、`ap-cli/output.odin` | 参数、新 session 创建、`json` 字段、退出码 |
| `docs/context-management.md` | 预算、省略、`context_build_budgeted`、交接章节，替换「不做压缩与 token 预算」正文 |
| `docs/react-loop-and-session.md` | `handoff` 事件、`stop_reason`、`turn_end.context` |
| `docs/cli-and-config.md` | 新参数、新配置字段、`json` 输出、退出码表 |
| `docs/provider.md` | `context_too_long` 的纠正路径与 usage 校准取材 |
| `docs/errors-and-cancellation.md` | `context_too_long` 的出口变化、交接失败路径 |
| `docs/architecture.md` | `context_build` 纯函数契约改为「(transcript, budget)」 |
| `docs/README.md` | 「已定决策」的上下文一行改口径，文档地图登记本提案 |
| `settings.example.json` | 三个新字段 |
| `README.md` | 上下文与长任务行为的对外说明 |

## 风险与待定

1. **省略会打掉 prompt cache。** 缓解见第二节，但 90%→80% 的取值需要在真实 provider 上量一次 `cached_tokens` 再定。
2. **桩文本可能让模型重复劳动。** 模型看到「已省略」会重跑工具，这是我们要的行为，但要观察是否形成循环。若出现，退路是把 `ELIDE_KEEP_RECENT_RESULTS` 调大而不是改桩语义。
3. **启发式估算偏差大。** 校准能吃掉系统偏差，吃不掉内容形态差异（例如大段 JSON 的 token/字节比明显偏离）。建议先在 `--verbose` 下把 `estimated` 与真实 `input_tokens` 的比值打出来观察一周。
4. **交接质量是新增的失败面。** 一次模型调用可能编造或漏项。可缓解的手段有三条：提示词要求「不确定就写不确定」；交接只靠省略后的投影，模型看不到的部分本来就不该被它写下来；`--no-handoff` 是可靠退路。另外，「建议技能」依赖 system prompt 里的技能清单（`name` 与 `location`），清单被 `--no-skills` 关掉时该小节必然为空——这是预期行为，不是缺陷。
5. **退出码与 `stop_reason` 变化影响脚本与前端。** 只在开启预算时生效，但 `docs/cli-and-config.md` 与 `docs/integration.md` 要写清「`handoff` 不是失败」。
6. **待定：交接后是否自动重放当前 turn 的原始提示词。** 本提案选择不自动重放，避免同一条提示词在两个 session 里各跑一遍、副作用翻倍。若实际使用中觉得麻烦，另开提案加 `--handoff --resume-prompt`。
7. **已定：`context_reserve_tokens` 不做比例自适应，但升为配置项。** 它仍是固定 token 数（默认为 `max_tokens` 的一半），改由 `settings.json` 覆盖。理由：窗口小或输出上限调小的部署需要收紧余量，否则预算公式直接失去意义；比例自适应会让 `target` 随 `--max-tokens` 漂移，可预期性反而更差。

## 相关文档

- [context-management.md](../context-management.md)：当前投影规则与「不压缩」决策
- [react-loop-and-session.md](../react-loop-and-session.md)：事件 schema 与恢复
- [provider.md](../provider.md)：usage 字段与 `context_too_long` 识别
- [cli-and-config.md](../cli-and-config.md)：参数、配置与退出码
