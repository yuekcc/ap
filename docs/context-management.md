# 上下文与记忆

本文件定义 system prompt 的组成、记忆文件注入规则，以及 transcript 到 messages 的投影。v1 不做 token 预算、不做压缩；上下文超限时直接终止 turn。

## system prompt 组成

按顺序拼接：

1. **固定指令**：ap 的身份与行为约束（工具串行、无审批、必须验证、不要臆造文件内容、大文件用分页读取、大输出用 bash 分段处理）。正文在 `ap/prompts/system.md`，构建时由 `#load` 内嵌进二进制；运行时不再读取该文件
2. **工具说明**：由 Tool Registry 生成——工具名、参数、关键约束（串行、无沙箱、blob 阈值、硬上限、路径规则）
3. **环境信息**：OS、cwd、当前时间、是否 git 仓库。没有 `--add-dir`，不列可用根目录
4. **可用技能**：扫描 `~/.agents/skills` 与 `<cwd>/.agents/skills` 后生成的 `<available_skills>` 清单；没有技能时整节省略（见 [skills.md](skills.md)）
5. **全局记忆**：`$AP_CONFIG/AGENTS.md`（存在才注入）
6. **项目记忆**：从 cwd 向上查找 `AGENTS.md`，由远及近拼接；同名冲突时近的优先
7. **agent 定义正文**：`--agent` 或 `task` 指定时，把定义文件的正文追加到这里；它不替换前面的固定指令、工具说明、环境与记忆
8. **追加指令**：`--append-system-prompt`

约束：

- 记忆文件内容视为**事实与偏好**，不视为最高优先级指令；与固定指令冲突时以固定指令为准
- 技能清单只含 `name` / `description` / `location`，正文不注入；模型需要时用 `read_file` / `bash` 自行读取
- 记忆文件与技能扫描都在新 session 组装时进行一次，之后冻结
- 记忆文件不做 `@import`（v1），避免递归与不可预期读取
- 记忆文件按原文完整注入，不截断；用户应自行控制大小
- system prompt 在 `session_start` 中冻结；恢复时不重新计算
- `--print-system-prompt` 用于检查结果：新 session 现场组装，恢复时读取 `session_start` 的冻结值；不创建 session、不调用模型

## 记忆文件

### 全局

`$AP_CONFIG/AGENTS.md`。不存在则跳过。

### 项目

从 cwd 开始向上查找 `AGENTS.md`：

1. 如果当前目录或其祖先存在 `.git`，向上直到该目录（含），不再越过
2. 否则向上直到文件系统根
3. 收集到的文件按「远 → 近」拼接，近的在后，覆盖前面的同名约定
4. 同一个物理文件只注入一次（解析符号链接/junction 后去重）

不读取子目录里的 `AGENTS.md`；不读取 `.git/` 等隐藏目录中的同名文件。

### 冲突

- 文件级：近的文件整体排在后面
- 约定级：近的明确约定覆盖远的；两者矛盾且无法判断时，以近的为准
- 记忆文件与固定指令冲突时，固定指令优先

## 消息组装

从 transcript 投影：

| 事件 | 投影为 |
| --- | --- |
| `user_message` | role=user |
| `message_end`（role=assistant，stop_reason≠cancelled） | role=assistant，含 text / tool_use 块；有推理内容时带 `reasoning_content` |
| `tool_execution_end` | role=tool，按 `tool_call_id` 与 tool_use 配对 |
| `session_start` | 不进 messages；提供 system prompt |
| `error` / `cancel` | 不进 messages |

### blob 解析

事件里的 `content_ref` / `args_ref` / `input_ref` / `text_ref` 都是 blob 的 sha256。投影前必须在 transcript 同目录的 `blobs/` 下解析出完整内容：

1. 工具结果：用完整 `content` 构造 role=tool 消息；预览不进入上下文
2. tool_use 参数：用完整 `input` 构造 assistant 消息
3. system prompt：`session_start.content` 为空时从 `content_ref` 还原
4. blob 缺失、hash 不匹配、读取失败：恢复失败并退出 2，不静默降级

### 配对校验

每次组装都跑：

1. 每个 `tool_use` 必须有对应 tool result。缺失时**删除该 tool_use 块**：
   - 若 assistant 消息只剩这个块，整条消息不提交
   - 若同一消息还有 text，保留 text
   - 不写修复事件，不改 transcript
2. 孤立的 tool result（找不到 tool_use）直接丢弃，不写日志
3. 连续同角色的 `user` / `assistant` 消息合并，减少 provider 兼容问题；`tool` 消息不合并
4. 空 assistant 消息（没有 text 也没有 tool_use）不提交
5. `stop_reason=cancelled` 的 assistant 消息不提交；它的 tool result 也因此成为孤立结果被丢弃
6. tool_use 与 tool result 的顺序按 assistant 消息内的顺序排列，不按 `seq` 重排
7. assistant 消息的 `reasoning_content` 原样保留并回传；连续 assistant 消息合并时按出现顺序拼接

### tool result 内容

- `ok: true`：用 `content`（完整内容，不是预览）
- `ok: false`：用 `error`；如果同时有部分输出，可拼接在错误信息后
- `metadata` 不进入上下文

## token 预算与压缩

v1 不做：

1. 不计算 token 预算，不预留输出窗口
2. 不做任何形式的历史压缩
3. 不提供压缩命令
4. 不在恢复时重新压缩

usage 仍然记录，用于审计与 `--output-format json`，但不参与任何截断决策。

## 上下文超限

这是 v1 唯一的超限出口：

1. provider 返回 `context_too_long`（HTTP 400，code/message 匹配）
2. 不重试
3. 写 `error(scope=llm, kind=context_too_long, retryable=false)`
4. 写 `turn_end(stop_reason=context_too_long)`
5. 写 `session_end(reason=error)`，退出码 3
6. 错误消息写入 `error` 事件（`message` 为 `context too long; start a new session or reduce input`），并进入 JSON 输出的 `stop_reason`；不会额外打印一条独立的 stderr 提示

后续 handoff 会替代这个退出路径：把任务移交给新 session，而不是直接失败。

## 恢复

1. 按文件行序应用事件（正常写入下即 `seq` 顺序）
2. 最后一个 `session_start` 决定 system prompt 与 model；不重新读记忆文件
3. 不重新调用 LLM 生成摘要
4. 不重新执行工具
5. `--fork-session` 复制事件后保留原 system prompt 与事件序列

## 未来

- handoff：新 session 的 `session_start` 通过 `handoff_from` 指回旧 session，旧 transcript 保持不变
- 可选的 token 估算：只用于展示与告警，不用于自动压缩
- 记忆文件的深度上限与冲突合并规则可在 handoff 时细化
