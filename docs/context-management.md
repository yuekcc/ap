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

记忆文件按文件原文注入。agent 正文去掉开头换行后注入。两者都不做 CRLF 规范化，不截断，不做 `@import`。只有 `SYSTEM.md` 经过规范化。

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

Provider 请求中的 messages 由一条 `role=system` 消息加投影结果组成。system 消息的内容来自最后一个 `session_start`。

| 事件 | 投影 |
| --- | --- |
| `user_message` | 一条 `role=user` 消息 |
| `message_end`，`stop_reason` 不是 `cancelled` | 一条 `role=assistant` 消息 |
| `tool_execution_end` | 一条 `role=tool` 消息，跟在要求它的 assistant 消息后 |
| `session_start` | 不进入 messages，只提供 system prompt |
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

## context_too_long

当前不计算 token 预算，不做历史压缩，也不按 usage 截断。provider 返回 `context_too_long` 是唯一的上下文超限出口。识别规则见 [provider.md](provider.md)。

1. 不重试。
2. 写 `error(scope=llm, kind=context_too_long, retryable=false)`。消息固定为 `context too long; start a new session or reduce input`。
3. 写 `turn_end(stop_reason=context_too_long)`。
4. 本次 turn 的 `result_text` 保留最后一个 assistant 文本。
5. `ap-cli` 写 `session_end(reason=error)`，退出 3。
6. 错误信息进入 `error` 事件。`json` 输出的 `stop_reason` 为 `context_too_long`。输出格式见 [cli-and-config.md](cli-and-config.md)。

当前没有 handoff。用户需要新建 session 或减少输入。

## 相关文档

- [react-loop-and-session.md](react-loop-and-session.md)：事件 schema、恢复与 fork
- [provider.md](provider.md)：请求格式与 `context_too_long` 识别
- [skills.md](skills.md)：技能发现与 `SKILL.md` 格式
- [subagents.md](subagents.md)：agent 定义与工具白名单
- [tools.md](tools.md)：工具契约与 blob
