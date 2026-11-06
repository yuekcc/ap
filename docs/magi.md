# MAGI 决策 CLI

`magi`（可执行文件 `magi-cli`）是一个基于 `apcore` SDK 的独立决策程序：把一个问题和一个可选材料分别交给三名角色独立判断，再用**一票否决制**合成最终决议。它复用 ap 的 `settings.json`、provider、session 与 transcript 机制，但不执行工具，也不修改工作区。

```
{question, context}
        │
        ├──► BALTHASAR-2 ──► veto=true/false
        ├──► CASPER-3    ──► veto=true/false
        └──► MELCHIOR-1  ──► veto=true/false
                                 │
                          一票否决制
                                 │
                    {approved, summary, votes}
```

## 目标

1. 三名角色各自看到同一份问题和材料，独立投票，不共享对话上下文。
2. 任意一名成员 `veto=true`，最终 `approved=false`；全部 `veto=false` 才 `approved=true`。
3. 成员投票失败（provider 错误、超时、输出无法解析）按**否决**处理，即 fail-closed。
4. 每个成员一个独立 session；transcript 可审计，可用 `ap -s <session_id>` 查看。
5. 只用 `apcore` 的公开门面；不 import `engine`，不在 CLI 里实现 agent loop。

## 非目标

- 不做 LLM 主持的辩论或权重投票。v1 的合成规则是确定性的，避免“评审者”自身成为不可审计的一票。
- 不调用工具，不读写工作区，不派生子代理。成员只输出投票 JSON。
- 不重试整个投票，不自动重试 provider 之外的失败；`apcore` 已有的 LLM 重试仍然生效。
- 不替代安全审查。模型投票只是建议，不是沙箱、权限系统或内容过滤器。

## 角色

角色正文来自 `agent-things/magi` 的三份 agent 定义，编译期内嵌在 `magi/prompts/`：

| 成员 | 视角 | 关注点 |
| --- | --- | --- |
| `BALTHASAR-2` | 战略与务实 | 成本收益、风险、可行性、长期影响 |
| `CASPER-3` | 伦理与哲学 | 道德框架、人类福祉、公平与权利 |
| `MELCHIOR-1` | 科学与分析 | 证据、概率、验证、客观性 |

公共投票规则在 `constitution.md`：`veto=false` 表示**不否决**；`veto=true` 表示行使否决权；材料不足或无法确定时必须否决。

`magi-deliberator-evaluation.md` / `magi-deliberator-voting.md` 不在 v1 的决策链路中。需要时可以在后续版本增加一个显式的评审阶段，但不能改变“任意成员能否决”的底线。

## 输入

三种输入方式互斥：

```sh
magi-cli --question '是否包含恶意行为' --context '<材料>'
magi-cli --question '...' --context-file material.txt
magi-cli --input-file request.json
magi-cli --print0 < request.json
```

JSON 请求格式：

```json
{
  "question": "是否包含恶意行为",
  "context": "<材料>"
}
```

- `question` 必填且不能全是空白。
- `context` 可省略或为 `null`；省略时提示词里写“未提供材料”。
- 输入必须是 UTF-8。`--input-file` 的相对路径相对启动目录。
- `--print0` 的 `0` 表示 stdin，不是 NUL 分隔；读取到 EOF 为止。
- 不隐式读取 stdin，必须显式传 `--print0`。

## 输出

默认 `--output-format json`：

```json
{
  "schema": "magi.decision.v1",
  "approved": true,
  "summary": "MAGI 一致通过（3/3 名成员未行使否决权）。",
  "votes": [
    {
      "agent": "BALTHASAR-2",
      "veto": false,
      "reason": "方案成本可控，没有明显落地障碍。",
      "status": "ok",
      "session_id": "ses_...",
      "stop_reason": "stop"
    }
  ]
}
```

字段：

| 字段 | 说明 |
| --- | --- |
| `schema` | 固定 `magi.decision.v1`，破坏性变更时升版本 |
| `approved` | 最终决议；`true` 仅当所有成员都给出有效且未否决的投票 |
| `summary` | 人类可读摘要；否决时列出否决成员与理由 |
| `votes[].agent` | 成员展示名 |
| `votes[].veto` | 该成员是否行使否决权；投票失败时为 `true` |
| `votes[].reason` | 成员理由，或失败原因 |
| `votes[].status` | `ok` 或 `error` |
| `votes[].session_id` | 该成员的 transcript session；启动失败时为空 |
| `votes[].stop_reason` | `stop` / `max_tokens` / `max_steps` / `context_too_long` / `cancelled` 或内部标记 |

`--output-format text` 输出同样的裁决与逐成员理由，适合人读；机器调用应使用 `json`。

stdout 只放决议。进度、重试、成员失败等人类可读信息只写 stderr；`--verbose` 打开成员进度。成员失败、无效投票与恢复冲突 warning 另外追加到 `$AP_CONFIG/logs/app-YYYY-MM-DD.log`，与 ap 共用同一套日志文件；纯进度不写文件。

## 决策规则

```text
approved = 所有成员 status == "ok" 且 veto == false
```

- 一名成员 `veto=true` → 否决。
- 一名成员失败 → 否决，`summary` 说明“未能完成投票”。
- 三名成员都否决 → 否决。
- 没有投票 → 否决。

因此 `approved=true` 是一个强保证：三名成员都成功返回了结构化投票，且都没有行使否决权。

## 执行模型

1. `magi-cli` 读取 `$AP_CONFIG/settings.json`，只取 `model` / `base_url` / `api_key` / `max_tokens` / `llm_timeout_ms` / `blob_threshold_bytes` / `stream_include_usage`。`AP_API_KEY` 优先。
2. 调 `apcore.env_open` 一次，注册表为空；三个成员共用只读 `Env`。
3. 三名成员**并行**各开一个 `Session_Kind.New` session：
   - `agent_name` 写 `magi-<role>`，仅作标签，不读取 agent 文件。
   - `tools = []`，即零工具。
   - `max_steps = 1`；一次 turn 只允许一次 LLM 调用。
   - `base_system_prompt` = 公共投票规则 + 角色正文。
4. 每个成员跑一轮 `apcore.turn_run`。输出不是合法投票 JSON 时，在**同一 session** 追加一个修复轮，要求只输出 JSON；修复轮失败同样按否决处理。
5. 每个成员结束时调用 `apcore.session_close`，`session_end` 写入 transcript。成员失败也会关闭 session。
6. 主线程等待三名成员，调用纯函数 `decide` 聚合，再输出决议。

session 落在当前项目的 transcript 目录：

```
$AP_CONFIG/projects/<fnv32a(cwd)>/<session_id>.jsonl
```

每个成员是一份独立 transcript，包含 system prompt、用户问题、模型回答和 `session_end`。用户可以用 `ap -s <session_id>` 在同一个项目里恢复并查看该成员的完整上下文。

## 提示词层次

每个成员的 system prompt 由 SDK 按固定顺序组装：

```text
constitution.md                 # 一票否决语义、默认拒绝、JSON 输出要求
## 你的角色
balthasar-2.md / casper-3.md / melchior-1.md
## 工具
（本次没有可用工具）             # SDK 固定追加
```

用户消息：

```text
## 问题
<question>

## 材料
<context 或 "（未提供材料）">

请以 <角色名> 的身份独立投票。只输出 JSON。
```

角色看不到其他成员的投票，也没有工具可以“查证”材料之外的东西。这是刻意的：MAGI 是三个独立视角的交叉检查，不是共享上下文的讨论。

## 解析与失败

投票 JSON 解析规则：

1. 从回答中找第一个花括号平衡的 JSON 对象；允许前后有少量说明文字或 Markdown 代码围栏。
2. 只接受布尔型 `veto`；`reason` 缺失时为空，非字符串时忽略。
3. 缺少 `veto`、`veto` 类型错误、JSON 坏掉 → 触发一次修复轮。
4. 修复轮仍失败 → 该成员 `status="error"`，整体否决。

其他失败：

| 情况 | 行为 |
| --- | --- |
| provider 重试耗尽 / 认证失败 / 超时 | 成员 `error`，整体否决 |
| `context_too_long` | 成员 `error`，整体否决 |
| `max_tokens` 截断导致 JSON 不完整 | 触发修复轮；仍失败则否决 |
| session 创建失败 | 成员 `error`，该成员没有 `session_id` |
| Ctrl+C / SIGTERM | 取消所有成员，关闭已打开的 session，进程以 130 / 143 退出，不输出决议 |
| `settings.json` 缺失或无效 | 启动前退出 2 |

## 配置

与 ap 共用 `$AP_CONFIG/settings.json`，默认 `~/.ap`；`--config-dir` 或 `AP_CONFIG` 覆盖。magi-cli 不读取 `SYSTEM.md`、`AGENTS.md`、技能或 agent 定义。

```json
{
  "model": "your-model",
  "base_url": "https://api.openai.com/v1",
  "api_key": "sk-..."
}
```

`--model` 覆盖 `model`，`--max-tokens` 覆盖 `max_tokens`。没有单独的 MAGI 配置文件。

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 决议完成；`approved` 为 `true` 或 `false` 都算完成 |
| 1 | 内部错误（序列化、线程创建后的基础设施问题等） |
| 2 | 参数、输入、配置错误 |
| 3 | 至少一名成员 `status="error"`；stdout 仍会给出 fail-closed 的决议 |
| 130 | SIGINT |
| 143 | SIGTERM |

注意：合法否决（成员主动投 `veto=true`）是正常决议，退出码仍然是 0。只有成员**没有完成投票**才是 3。

## 安全边界

- 成员没有工具，不能读文件、执行命令或写 transcript 之外的东西；投票过程不会修改工作区。
- 问题和材料是不可信输入，可能包含针对模型的提示注入。MAGI 的结论因此只是建议，不能当作安全判定的唯一依据。
- 三名成员共享同一个 provider 配置和模型；如果模型本身有系统性偏差，三个角色可能一起错。
- 默认拒绝降低了漏判风险，但也可能把“材料不足”误判为否决；调用方应把 `approved=false` 和 `summary` / 各成员 `reason` 一起展示。
- transcript 是审计依据；不要删除 `session_id` 指向的 JSONL，否则无法重放该成员的判断过程。

## 测试

```sh
odin test magi -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
```

单测覆盖投票解析、一票否决聚合、fail-closed、提示词组装和参数互斥。完整流程需要真实 provider；本地验证可用 OpenAI 兼容的 SSE 替身，不需要外网。
