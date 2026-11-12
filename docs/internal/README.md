# ap Coding Agent Spec

ap 是用 Odin 写的 coding agent。输入一条提示词，它进入 ReAct 循环：请求模型、执行工具、把结果送回模型，直到任务完成或命中终止条件。`ap` 本体只做一次性 CLI，交互界面由独立前端承担。

本文件是规格入口，说明 ap 的设计取舍、硬约束、已定决策、术语和文档地图。参数表、事件字段和模块契约分别由各分篇定义。

## 三种进程形态

- `ap` 是一次性 CLI。一条提示词进，一个 turn 出，然后退出。
- `ap-tui` 与 `ap-web` 是独立前端。每个 turn 启动一个 `ap` 子进程，提示词走 stdin，事件走 stdout。
- `magi-cli` 是第二个进程内宿主。它直接调用 `apcore`，为三名角色各开一个隔离 session。

`ap` 本体不跨 turn 保存交互状态。session 的历史在 transcript 里，下一轮由 `-s` 或 `-c` 恢复。`ap-tui` 与 `ap-web` 因此可以随时重启，也能在刷新后从 transcript 重放。`magi-cli` 不启动 `ap` 子进程，也不注册工具。

进程契约与事件消费方式见 [integration.md](integration.md)。模块职责与生命周期顺序见 [architecture.md](architecture.md)。

## 五条设计取舍

**一次性 CLI 当内核。** ap 没有 REPL，也没有常驻服务。每条提示词启动一次进程，参数、输出格式和退出码保持稳定。脚本、子代理和前端都调用同一个可执行文件，不需要理解 agent 内部。代价是交互状态必须落到 transcript，前端要自己维护 session 选择。

**transcript 是唯一事实来源。** 对话事件只追加到 JSONL，消息列表、usage 和 agent 信息都能从 transcript 重建。恢复只读历史，不重新执行工具，也不调用模型生成摘要。这样崩溃恢复和事后审计才有共同依据。细节见 [react-loop-and-session.md](react-loop-and-session.md)。

**全自动执行。** ap 没有审批弹窗、权限规则或沙箱。安全边界放在可追溯的记录、实时可见的工具输出和信号取消上，而不是交互确认。这个选择意味着 agent 可以静默修改文件或运行任意命令，部署前必须接受这一点。取消语义见 [errors-and-cancellation.md](errors-and-cancellation.md)。

**工具保持最小。** 内置工具只有 `read_file`、`write_file`、`edit_file`、`bash` 和 `task`。搜索、列目录和管道组合交给 bash，减少工具 schema 的数量和模型的选择成本。代价是模型需要写出更长的 shell 命令。工具边界见 [tools.md](tools.md)。

**SDK 只保留机制。** agent loop、provider、transcript、context 和工具契约在 `ap-core`。具体工具、技能、`AGENTS.md`、agent 定义和 CLI 语义在 `ap-cli`。这条分界让 `magi` 能作为第二个宿主复用 `apcore`，也让前端二进制不必链接 agent 代码。模块划分见 [architecture.md](architecture.md)。

## 硬约束

以下五条不是可选项。

1. 所有 tool call 与结果必须可追溯。内容内联在 transcript，或通过 blob 引用。blob 缺失时恢复失败，不静默降级。
2. 取消必须及时。收到信号后停止循环、中止 HTTP 请求、终止工具与子代理的进程树。Unix 先发 `SIGTERM`，2 秒后发 `SIGKILL`。Windows 使用 Job Object。`kill -9` 与断电无法保证清理。
3. 危险操作不能隐藏。工具调用与输出必须实时可见。`text` 格式写 stderr，`stream-json` 格式写 stdout 事件。
4. 完整事件只追加，永不改写。恢复只读记录，不重新执行工具，也不调用模型补写历史。唯一允许的物理改动是截掉崩溃留下的不完整尾行。
5. stdout 是机器通道。`text`、`json`、`stream-json` 只把结果或事件写到 stdout。日志、进度和工具输出写 stderr。

模块级契约，例如 `context_build` 的纯函数要求和 blob 的 fsync 顺序，见 [architecture.md](architecture.md)。

## 已定决策

| 决策 | 结论 | 详情 |
| --- | --- | --- |
| 运行平台 | Linux、macOS、Windows，shell 统一用 Bash | [tools.md](tools.md) |
| 编写语言 | Odin nightly | [architecture.md](architecture.md) |
| 工具执行 | 串行，无状态，不共享 cwd 或环境变量 | [tools.md](tools.md) |
| 工具集 | `read_file`、`write_file`、`edit_file`、`bash`、`task` 五种 | [tools.md](tools.md) |
| 路径 | 没有 `--add-dir`，相对路径只相对启动目录 | [cli-and-config.md](cli-and-config.md) |
| 会话存储 | 只追加 JSONL transcript 加内容寻址 blob | [cli-and-config.md](cli-and-config.md) |
| 大输出 | 超过 `blob_threshold_bytes` 写 blob，默认 102400 字节 | [tools.md](tools.md) |
| 诊断日志 | stderr 加 `$AP_CONFIG/logs/app-YYYY-MM-DD.log`，默认 warning 及以上 | [cli-and-config.md](cli-and-config.md) |
| 上下文 | 面向 1M 窗口做 token 预算：本地估算加 usage 校准，接近窗口先省略较早的大工具输出，仍不够就 handoff 到新 session。不做对话压缩与消息级淘汰 | [context-management.md](context-management.md) |
| 图片输入 | `read_file` 在 `image_input=true` 时把 PNG/JPEG/GIF/WebP 写入 blob，provider 以合成 user 图片消息发送 | [tools.md](tools.md) |
| 恢复 | 以 transcript 为准，system prompt、model、agent、cwd 与工具集冻结 | [react-loop-and-session.md](react-loop-and-session.md) |
| 记忆与注入 | `AGENTS.md` 分层注入，`SYSTEM.md` 可替换基础段，`--no-agents-md` 与 `--no-skills` 可裁剪 | [context-management.md](context-management.md) |
| 技能 | 只发现并注入清单，正文按需读取 | [skills.md](skills.md) |
| 子代理 | 独立进程与独立 session，深度默认 1 | [subagents.md](subagents.md) |
| MAGI | 三名角色独立投票，一票否决，成员失败按否决处理 | [magi.md](magi.md) |
| Provider 与协议 | 只支持 OpenAI chat completions，前端与子代理用 `stream-json`，事件带 `v: 1` | [provider.md](provider.md) |

循环粒度固定为两级。turn 从一条提示词开始，到循环终止为止。step 是一次逻辑 LLM 调用，重试不增加 step。事件与恢复规则见 [react-loop-and-session.md](react-loop-and-session.md)。

## 术语

- **session**：一次逻辑对话，由 `session_id` 标识，可以跨多次 ap 运行恢复。
- **transcript**：session 的事件记录集，落盘为一个 JSONL 文件，一行一个事件，只追加。
- **blob**：内容寻址的大块数据文件，存放超过阈值的工具结果或参数，transcript 通过 sha256 引用。
- **turn**：从一条用户提示词开始，到循环终止为止的一段执行。
- **step**：一个 turn 内的一次逻辑 LLM 调用。重试不增加 step。
- **message**：提交给模型的一条对话记录，角色为 system、user、assistant 或 tool。
- **tool call**：模型响应中要求执行工具的请求，包含工具名与参数。
- **工具执行**：ap 对单个 tool call 的本地执行过程。
- **子代理（subagent）**：由 `task` 工具启动、拥有独立 session 的 ap 进程。
- **skill**：放在 `SKILL.md` 里的 Markdown 指令包。ap 把元数据清单注入 system prompt，正文由模型按需读取。
- **provider**：模型接口的适配层。当前只有 OpenAI chat completions。
- **stream event**：写到 stdout、但不落盘的临时事件，例如增量文本和工具输出片段。
- **transcript event**：追加到 transcript 的持久事件。

## 模块关系

```
cmd/ap ──► ap-cli ──► apcore ──► engine
                                  ├──► provider
                                  ├──► tool
                                  └──► transcript

cmd/ap-tui ──► ap-tui ──┐
cmd/ap-web ──► ap-web ──┴──► ap-core/client ──► ap-core/platform

cmd/magi-cli ──► magi ──► apcore ──► engine
```

`ap-cli` 是组装根，负责把外部输入变成 `apcore.Config`。`ap-tui`、`ap-web` 与 `magi` 都不链接 agent loop。模块职责与依赖方向见 [architecture.md](architecture.md)，允许的 import 边见 [dependencies.md](dependencies.md)。

## 文档地图

状态只有三类。`规格` 是当前代码必须遵守的行为，`设计记录` 是历史方案，`工作清单` 是维护记录。

| 文件 | 内容 | 状态 |
| --- | --- | --- |
| [README.md](README.md) | 总览、设计取舍、硬约束、术语、索引 | 规格 |
| [architecture.md](architecture.md) | 模块职责、进程生命周期、契约、内存、Odin 约束 | 规格 |
| [dependencies.md](dependencies.md) | 包布局、允许的 import 边、检查器 | 规格 |
| [cli-and-config.md](cli-and-config.md) | 参数、输出、配置、存储布局、项目识别 | 规格 |
| [react-loop-and-session.md](react-loop-and-session.md) | turn/step、事件 schema、恢复与 fork | 规格 |
| [context-management.md](context-management.md) | system prompt、记忆、消息投影 | 规格 |
| [provider.md](provider.md) | OpenAI 适配、SSE、usage、错误映射 | 规格 |
| [tools.md](tools.md) | 五个工具的参数、结果、blob 与进程边界 | 规格 |
| [subagents.md](subagents.md) | agent 定义、启动协议、结果契约 | 规格 |
| [skills.md](skills.md) | 技能发现、`SKILL.md` 格式、提示词注入 | 规格 |
| [tui.md](tui.md) | `ap-tui` 的进程模型、渲染、输入与命令 | 规格 |
| [lineedit.md](lineedit.md) | 独立行编辑器：decoder、editor、layout、render、history、transport | 规格 |
| [web.md](web.md) | `ap-web` 的 HTTP/SSE、并发与前端 | 规格 |
| [integration.md](integration.md) | 新前端接入 ap 的进程契约与 turn 生命周期 | 规格 |
| [magi.md](magi.md) | 三角色投票、一票否决、输入输出与失败语义 | 规格 |
| [errors-and-cancellation.md](errors-and-cancellation.md) | 错误分类、重试、取消、超时、落盘 | 规格 |
| [proposals/cli-explicit-prompt-source.md](proposals/cli-explicit-prompt-source.md) | 提示词三选一的设计记录 | 设计记录 |
| [proposals/context-budget-and-handoff.md](proposals/context-budget-and-handoff.md) | token 预算、工具结果省略与 handoff 的设计记录（已实现，决策理由保留） | 设计记录 |
| [proposals/read-image.md](proposals/read-image.md) | `read_file` 图片输入、blob 引用与合成 user 消息的设计记录（已实现） | 设计记录 |
| [proposals/cli-prompt-context-tools.md](proposals/cli-prompt-context-tools.md) | 上下文裁剪与工具开关的设计记录 | 设计记录 |
| [proposals/sdk-scope.md](proposals/sdk-scope.md) | SDK 边界收窄的设计记录 | 设计记录 |
| [TODO.md](TODO.md) | docs 重写计划与验收清单 | 工作清单 |

`refs/` 放外部协议原文，不是 ap 自己的规格，也不属于上面三类状态：

- [refs/keyboard-protocol.rst](refs/keyboard-protocol.rst)：kitty keyboard protocol 原文，`ap-tui` 按键编解码的依据。ap 侧的使用方式见 [tui.md](tui.md#kitty-keyboard-protocol)。

## 与 Claude Code 的关系

ap 借鉴了 Claude Code 的循环骨架、只追加 transcript、技能清单、子代理和结构化输出。没有采纳审批与 hooks，因为它们与全自动执行冲突。没有采纳 TodoWrite 和 plan mode，因为它们需要交互界面。上下文压缩没有采纳：省略只作用在工具结果上，assistant 文本与 user 提示词永不改写，真的不够用就 handoff 到新 session，决策理由见 [proposals/context-budget-and-handoff.md](proposals/context-budget-and-handoff.md)。MCP 与插件系统留到核心循环稳定之后。完整的非目标清单见仓库根目录的 [README.md](../README.md)。

## 相关文档

- [cli-and-config.md](cli-and-config.md)：参数、配置、输出与存储
- [react-loop-and-session.md](react-loop-and-session.md)：循环、事件与恢复
- [architecture.md](architecture.md)：模块、进程与契约
- [dependencies.md](dependencies.md)：包边界与检查器
- [integration.md](integration.md)：前端接入 ap
