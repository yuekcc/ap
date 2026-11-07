# MAGI 一票否决决策器

`magi-cli` 是一个基于 `apcore` SDK 的独立决策程序。它把一个问题与可选材料交给 BALTHASAR-2、CASPER-3、MELCHIOR-1 三名角色独立投票，再按一票否决规则合成决议。三名角色各自拥有独立 session，transcript 可审计，但都没有工具，也不会修改工作区。

这篇文档定义 `magi` 的角色、输入输出、决策规则、执行模型、失败语义与安全边界。通用 CLI 参数、`settings.json` 全表和 session 文件布局见 [cli-and-config.md](cli-and-config.md)，事件 schema 见 [react-loop-and-session.md](react-loop-and-session.md)。

## 角色

角色正文来自 `agent-things/magi` 的三份 agent 定义，编译期由 `#load` 嵌入 `magi/prompts/`。运行时不读取 `$AP_CONFIG/agents/`。

| 成员 | `agent_name` | 视角 | 关注点 |
| --- | --- | --- | --- |
| `BALTHASAR-2` | `magi-balthasar-2` | 战略与务实 | 成本收益、风险、可行性、长期影响 |
| `CASPER-3` | `magi-casper-3` | 伦理与哲学 | 道德框架、人类福祉、公平与权利 |
| `MELCHIOR-1` | `magi-melchior-1` | 科学与分析 | 证据、概率、验证、客观性 |

三名成员共用 `magi/prompts/constitution.md` 的投票规则：

- `veto=false` 表示不行使否决权。
- `veto=true` 表示行使否决权。
- 材料不足、问题无法判断或结论没有把握时必须否决。系统默认姿态是拒绝。
- 回答只输出一个 JSON 对象。

`agent_name` 写入该成员 session 的 `session_start.agent_name`，只作审计标签。成员展示名使用 `BALTHASAR-2` 这类 `id`，它也是最终输出里的 `votes[].agent`。

没有主持人、辩论或加权投票阶段。三名成员只输出各自的投票，合成由纯函数 `decide` 完成。

## 输入

一次请求只能有一个来源。

| 来源 | 用法 | 说明 |
| --- | --- | --- |
| 问题模式 | `--question <文本>`，可加 `--context <文本>` 或 `--context-file <路径>` | 参数直接给出问题与材料 |
| JSON 文件 | `--input-file <路径>` | 读取完整 JSON 请求 |
| stdin | `--print0` | 从 fd 0 读完整 JSON 请求直到 EOF |

`parse_args` 的约束：

- `--question`、`--input-file`、`--print0` 三者互斥，同时出现退出码 2，三者都没给也退出码 2。
- `--context` 与 `--context-file` 互斥。
- `--input-file` 或 `--print0` 不能再配 `--context` 或 `--context-file`，材料写在 JSON 的 `context` 字段里。
- `--help` 与 `--version` 不需要请求，优先返回。
- `--print0` 的 `0` 表示 stdin，不是 NUL 分隔。magi 不会隐式读取 stdin。

JSON 请求：

```json
{
  "question": "是否包含恶意行为",
  "context": "<材料>"
}
```

字段规则：

- `question` 必填，必须是字符串，且不能全是空白。
- `context` 可省略、为 `null` 或为字符串。省略或 `null` 时用户消息写「（未提供材料）」。
- 顶层必须是 JSON 对象。
- `--input-file`、`--context-file` 与 `--print0` 的内容必须是合法 UTF-8。
- 相对路径按启动目录解析，支持 `~`。

其他参数：`--config-dir <目录>`、`--model <id>`、`--max-tokens <n>`、`--output-format json|text`、`--verbose`、`--debug`。

## 输出

默认 `--output-format json`：

```json
{
  "schema": "magi.decision.v1",
  "approved": false,
  "summary": "MAGI 否决（2/3 名成员未否决）：CASPER-3 否决：材料包含操纵性指令。",
  "votes": [
    {
      "agent": "BALTHASAR-2",
      "veto": false,
      "reason": "方案成本可控，没有明显落地障碍。",
      "status": "ok",
      "session_id": "ses_...",
      "stop_reason": "stop"
    },
    {
      "agent": "CASPER-3",
      "veto": true,
      "reason": "材料包含操纵性指令。",
      "status": "ok",
      "session_id": "ses_...",
      "stop_reason": "stop"
    },
    {
      "agent": "MELCHIOR-1",
      "veto": false,
      "reason": "证据足以支持通过。",
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
| `approved` | 最终决议，仅当三名成员都完成投票且都未否决时为 `true` |
| `summary` | 人类可读摘要，列出否决成员与理由，或说明成员未能完成投票 |
| `votes[].agent` | 成员展示名 |
| `votes[].veto` | 该成员是否行使否决权；`status="error"` 时按否决计数 |
| `votes[].reason` | 成员理由，或失败原因 |
| `votes[].status` | `ok` 或 `error` |
| `votes[].session_id` | 该成员 session id；启动失败时字段省略 |
| `votes[].stop_reason` | 该成员最后一个 turn 的停止原因，或内部失败标记 |

`session_id` 与 `stop_reason` 带 `omitempty`，值为空时不出现。`stop_reason` 的正常取值是 `stop`、`max_tokens`、`max_steps`、`context_too_long`、`cancelled`。失败路径还会写 `session_open`、`turn_run`、`repair_turn` 三个内部标记。

`--output-format text` 输出同样的裁决与逐成员结论，供人阅读。机器调用应使用默认的 `json`。

stdout 只放决议。进度、成员失败与 warning 写 stderr。`--verbose` 打开成员进度，`--debug` 打开更详细的 SDK 日志。失败与 warning 还会追加到 `$AP_CONFIG/logs/app-YYYY-MM-DD.log`，与 ap 共用同一套文件日志。

## 决策规则

```text
approved = 每名成员 status == "ok" 且 veto == false
```

- 任意一名成员 `veto=true`，最终否决。
- 任意一名成员 `status="error"`，最终否决，`summary` 写「未能完成投票」。
- 三名成员都否决，最终否决。
- 没有投票，最终否决。

因此 `approved=true` 是强保证：三名成员都成功返回了结构化投票，且都没有行使否决权。纯函数 `decide` 只读 `Member_Vote`，不调用模型，也不写 transcript。

合法否决是正常决议，退出码仍是 0。只有成员没有完成投票才返回退出码 3。

## 执行模型

1. 解析参数，设置控制台，确定 `$AP_CONFIG` 与启动目录。
2. 打开 `$AP_CONFIG/logs` 的当天日志文件。
3. 读取并校验请求。
4. 读取 `settings.json` 的 provider 子集，应用 `--model` 与 `--max-tokens`。
5. 调 `apcore.env_open` 一次，工具注册表为空。三名成员共用只读 `Env`。
6. 安装信号处理，启动三个线程，每名成员各跑一个 `Session_Kind.New` session。
7. 每名成员先调用一次 `apcore.turn_run`。投票 JSON 不合法时，在同一个 session 再调用一次修复 turn。
8. 每名成员退出时调用 `apcore.session_close`，并写 `session_end`。失败路径也会关闭 session。
9. 主线程 join 三个成员，检查信号，调用 `decide`，输出决议。

每个成员的 `Session_Options`：

| 字段 | 值 |
| --- | --- |
| `kind` | `.New` |
| `agent_name` | `magi-balthasar-2`、`magi-casper-3` 或 `magi-melchior-1` |
| `model` | `settings.model`，可被 `--model` 覆盖 |
| `max_steps` | `1` |
| `max_tokens` | `settings.max_tokens`，可被 `--max-tokens` 覆盖 |
| `base_system_prompt` | 公共投票规则加角色正文 |
| `tools` | 空切片，即零工具 |
| `prompt_sections` | 不设置 |

`max_steps=1` 表示每轮 turn 最多一次 LLM 调用。修复轮是同一 session 里的第二个 turn，不是同一个 turn 的第二个 step。

线程创建失败时，该成员退化为同步执行，避免丢票。

成员 transcript 写到当前项目的 session 目录：

```text
$AP_CONFIG/projects/<project_path_hash>/<session_id>.jsonl
```

`project_path_hash` 是规范化启动目录的 `fnv32a` 前 8 位十六进制。目录与恢复规则见 [cli-and-config.md](cli-and-config.md)。每份 transcript 包含 system prompt、用户消息、模型回答与 `session_end`。在同一个项目里运行 `ap -s <session_id>` 可以恢复并查看该成员的完整上下文。

## 提示词层次

成员 system prompt 由公共规则、角色正文与工具段组成，SDK 按固定顺序拼接：

```text
constitution.md
## 你的角色
<角色正文>
## 工具
（本次没有可用工具）
```

公共规则在前，角色人格在后，避免角色正文稀释结构化输出要求。`## 工具` 一节由 SDK 根据空注册表生成。

用户消息：

```text
## 问题

<question>

## 材料

<context 或 （未提供材料）>

请以 <角色名> 的身份独立投票。只输出 JSON。
```

角色看不到其他成员的投票，也没有工具去查证材料之外的事实。MAGI 是三个独立视角的交叉检查，不是共享上下文的讨论。

## 投票解析

`parse_vote_response` 是纯函数，规则如下：

1. 从左到右找第一个花括号平衡的 JSON 对象。
2. 配对时跳过字符串内部的花括号，`reason` 里出现 `{}` 不会截断。
3. 允许对象前后有说明文字或 Markdown 代码围栏。
4. `veto` 必须存在且是布尔值。缺少 `veto` 或类型错误都视为解析失败。
5. `reason` 可省略。省略时为空字符串，非字符串时忽略。
6. JSON 语法错误或顶层不是对象，视为解析失败。

解析失败时，向同一 session 发送 `REPAIR_PROMPT`，要求只输出一个 JSON 对象。修复轮成功后继续用修复结果。修复轮仍失败时，该成员 `status="error"`，`reason` 带最后一次输出的前 200 个字符，整体按否决处理。

摘要中的理由会压平成一行。空理由显示为「未给出理由」。

## 失败语义

成员失败一律 fail-closed。

| 情况 | 结果 |
| --- | --- |
| provider 重试耗尽、认证失败、连接错误 | 成员 `error`，`reason` 为 provider 错误，`stop_reason` 为空并省略 |
| `context_too_long` | 成员 `error`，`stop_reason="context_too_long"` |
| 其他 loop 错误，例如内部错误 | 成员 `error`，`stop_reason` 为空并省略 |
| `max_tokens` 截断导致 JSON 不完整 | 先修一轮，仍失败则成员 `error` |
| 投票 JSON 两轮都不合法 | 成员 `error`，保留最后一次 `stop_reason` |
| session 创建失败 | 成员 `error`，`stop_reason="session_open"`，没有 `session_id` |
| `turn_run` 返回错误 | 成员 `error`，`stop_reason="turn_run"` |
| 修复轮返回错误 | 成员 `error`，`stop_reason="repair_turn"` |
| 成员被取消 | 成员 `error`，`stop_reason="cancelled"`，进程随后按信号退出 |
| 线程创建失败 | 该成员同步执行，不单独计为失败 |
| `settings.json` 缺失或字段无效 | 启动前退出码 2，不创建 session |
| Ctrl+C、SIGTERM | 取消三名成员，关闭已打开的 session，进程以 130、143 退出，不输出决议 |

即使存在 `status="error"` 的成员，stdout 仍会输出 fail-closed 的决议，退出码为 3。

## 配置

`magi-cli` 与 ap 共用 `$AP_CONFIG/settings.json`，默认目录是 `~/.ap`。`--config-dir` 优先于 `AP_CONFIG`。

只读取以下字段：

| 字段 | 用途 |
| --- | --- |
| `model` | 成员模型 |
| `base_url` | provider 地址 |
| `api_key` | API key，`AP_API_KEY` 优先 |
| `max_tokens` | 单次响应上限 |
| `llm_timeout_ms` | provider 超时 |
| `blob_threshold_bytes` | transcript 的 blob 阈值 |
| `stream_include_usage` | 是否请求 usage |

不读取 `max_steps`，成员固定 `1`。`model` 与 `api_key` 必填，`max_tokens`、`llm_timeout_ms`、`blob_threshold_bytes` 必须为正数，`base_url` 去掉尾部 `/` 后不能为空。缺失或类型错误都退出码 2。

`--model` 覆盖 `model`。`--max-tokens` 覆盖 `max_tokens`。没有单独的 MAGI 配置文件。

`magi-cli` 不读取 `SYSTEM.md`、`AGENTS.md`、技能目录或 agent 定义。完整配置字段见 [cli-and-config.md](cli-and-config.md)。

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 决议完成，`approved` 为 `true` 或 `false` 都算完成 |
| 1 | 内部错误，例如决议序列化失败、线程基础设施错误，或 `Internal` 类环境错误 |
| 2 | 参数、输入或配置错误 |
| 3 | 至少一名成员 `status="error"`，stdout 仍给出 fail-closed 决议 |
| 130 | SIGINT |
| 143 | SIGTERM |

## 安全边界

- 成员没有工具，不能读文件、执行命令或写 transcript 之外的内容。投票不修改工作区。
- 问题和材料是不可信输入，可能带有提示注入。MAGI 的结论只是建议，不能当作安全判定的唯一依据。
- 三名成员共用同一个 provider 与模型。模型本身的系统性偏差会让三个角色一起出错。
- 默认拒绝降低漏判风险，也会把「材料不足」判成否决。调用方应同时展示 `approved`、`summary` 与各成员 `reason`。
- transcript 是审计依据。删除 `session_id` 指向的 JSONL 后无法重放该成员的判断过程。
- 隔离来自零工具注册表与独立 session，不是权限系统或沙箱。

## 测试

```sh
odin test magi -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
```

单元测试覆盖投票解析、JSON 提取、一票否决聚合、fail-closed、提示词组装、参数互斥与决议序列化。完整流程需要真实 provider。本地验证可用 OpenAI 兼容的 SSE 替身，不需要外网。

## 相关文档

- [cli-and-config.md](cli-and-config.md)：通用参数、`settings.json`、session 文件布局
- [react-loop-and-session.md](react-loop-and-session.md)：turn、step 与事件 schema
- [architecture.md](architecture.md)：`magi` 与 `apcore` 的进程和模块边界
- [dependencies.md](dependencies.md)：`magi` 允许的 import
