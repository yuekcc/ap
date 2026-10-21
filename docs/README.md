# ap Coding Agent Spec

ap 是一个跨平台的命令行 coding agent：接收一条提示词，通过 ReAct 循环调用 LLM 与本地工具，直到任务完成。第一阶段只提供非交互的一次性 CLI，运行结束即退出。

本文件是规格总入口，定义全局决策、术语和文档地图。子系统细节见各分篇。

## 目标

1. 跨平台，Linux / macOS / Windows 行为一致；shell 统一用 Bash，差异封装在一层抽象里
2. session 可持久化、可在同一项目内恢复（`ap -s` / `ap -c`）、可重放
3. 工具集最小可用：读文件、写文件、编辑文件、执行 shell、启动子代理
4. 子代理：`task` 工具拉起独立 `ap` 进程，隔离上下文，只回传结论
5. 流式输出；工具执行过程对用户可见（stderr，或 `stream-json` 模式下的 stdout 事件）
6. 全自动执行，不引入审批交互
7. 只做 CLI：一条提示词进，一个 turn 出，没有交互式 REPL

## 前置条件

- 所有平台都需要可用的 `bash`。Windows 上由 **Git for Windows** 提供（`bash.exe` 在 PATH 中）；找不到时启动失败，退出码 2
- Windows 上 ap 是原生程序，接收 Win32 路径；不依赖 MSYS 的 `/z/...` 形式。文件工具同时接受 `/` 与 `\` 作为分隔符
- 实现语言 Odin；HTTP/TLS 通过 `vendor:curl`，Windows 使用随 Odin 分发的静态 libcurl，Linux/macOS 链接系统 libcurl

## 非目标（v1）

1. 交互模式、TUI、历史编辑、Esc 取消（v1 只有信号中断）
2. 工具执行审批、权限规则、沙箱
3. 上下文压缩、token 预算；压缩能力后续由 **handoff** 取代
4. Hooks（PreToolUse / PostToolUse 等拦截机制）
5. Plan mode、多 agent 并行编排
6. MCP、插件系统
7. 内置 WebFetch / WebSearch
8. 图形界面、IDE 插件、Web 界面
9. 远程会话共享、服务端部署
10. `--add-dir`：所有相对路径只相对启动目录
11. 除 read_file / write_file / edit_file / bash / task 之外的任何工具（包括 grep / glob / ls / todo / 原生后台进程）
12. blob 的自动回收（GC）；由用户自行清理
13. 技能的脚本执行、参数传入、版本管理与远程安装；v1 只发现并注入清单

## 已知风险

全自动 + 无沙箱意味着 agent 可以静默删文件、跑任意命令，用户唯一的止损手段是信号中断。因此以下四条是**硬约束**，不是可选项：

1. 所有 tool call 与结果必须可追溯：transcripts 内联，或通过 blob 引用；blob 缺失时恢复必须失败而不是静默降级
2. 中断必须及时：收到信号后立即停止循环并开始终止对应进程树；Unix 先 `SIGTERM`、2s 后 `SIGKILL`，Windows 用 Job Object；`kill -9` / 断电无法保证清理残留子进程
3. 危险操作不做隐藏：工具调用与输出必须实时对用户可见（stderr；`stream-json` 模式下为 stdout 事件）
4. 完整事件只追加，永不改写；恢复只读取记录，不重新执行工具、不重新调用 LLM 生成摘要。恢复时唯一允许的物理改动是截掉崩溃留下的不完整尾行（它从未成为事件）

## 已定决策

| 决策 | 结论 | 影响 |
| --- | --- | --- |
| 运行平台 | 跨平台，shell 统一 Bash | Windows 需要 Git for Windows，见 [tools.md](tools.md) |
| 实现语言 | Odin | 见 [architecture.md](architecture.md) 的实现约束 |
| 产品形态 | 只有一次性 CLI，无交互 | 见 [cli-and-config.md](cli-and-config.md) |
| 工具执行安全 | 全自动，无审批、无沙箱 | 靠 transcripts + blob + 可中断兜底 |
| 工具执行方式 | 串行；工具无状态（不共享 cwd/env） | 一个 step 内多个 tool call 按序执行 |
| 工具集 | 仅 read_file / write_file / edit_file / bash / task | 见 [tools.md](tools.md) |
| 路径 | 无 `--add-dir`；相对路径只相对启动目录 | 跨目录操作使用绝对路径 |
| 会话存储 | JSONL 只追加 transcripts + 内容寻址 blob | 事件 schema 见 [react-loop-and-session.md](react-loop-and-session.md) |
| 上下文管理 | 不做压缩、不做 token 预算；超限即终止 | 记录 usage；`context_too_long` 是唯一超限出口 |
| 会话恢复 | 以 transcripts 为准，system prompt / model / agent 全部冻结 | 只在当前项目内查找 |
| 记忆文件 | `AGENTS.md` | 全局 `$AP_CONFIG/AGENTS.md` + 项目向上查找 |
| 技能 | 只发现并注入清单，正文按需读取 | 见 [skills.md](skills.md) |
| 循环粒度 | user turn = 一条提示词到终止；step = 一次 LLM 调用 | 事件与日志按 step 切分 |
| 子代理 | 独立进程 + 独立 session，深度默认 1 | 见 [subagents.md](subagents.md) |
| 进程间协议 | `--output-format stream-json`，stdout 只放事件 | 子代理与脚本化的唯一通道 |
| Provider | 只支持 OpenAI chat completions 兼容接口 | 见 [provider.md](provider.md) |
| 大输出 | 超过 100KB 写 blob，transcripts 只存引用 | 模型仍看到完整内容；blob 由用户清理 |
| 上下文版本 | 事件带 `v: 1`；未知事件类型跳过 | 前向兼容 |

## 术语

- **session**：一次逻辑对话，由 `session_id` 标识，可跨多次 ap 运行恢复。
- **transcript**：session 的事件记录集，落盘为一个 JSONL 文件，一行一个事件，只追加。
- **blob**：内容寻址的大块数据文件，存放超过阈值的工具结果或工具参数；transcript 通过 sha256 引用它。
- **user turn**（下文简称 turn）：从一条用户提示词开始，到循环终止为止的一段执行。
- **step**：一个 turn 内的一次逻辑 LLM 调用。重试不增加 step。
- **message**：提交给 LLM 的一条对话记录（system / user / assistant / tool）。
- **tool call**：LLM 响应中要求执行工具的请求，含工具名与参数。
- **tool execution**：ap 对单个 tool call 的本地执行过程。
- **subagent**：由 `task` 工具拉起、拥有独立 session 的 ap 进程。
- **skill**：放在 `SKILL.md` 里的 Markdown 指令包；ap 把元数据清单注入 system prompt，模型按需读取正文。
- **provider**：LLM 接口的适配层，v1 只有 OpenAI chat completions。
- **stream event**：写到 stdout、但不落盘的临时事件（增量文本、工具输出片段）。
- **transcript event**：追加到 transcript 的持久事件。

## 模块关系

```
CLI（cli-and-config.md）
  │ 用户输入 / 信号；新 session 时发现技能（skills.md）
  ▼
ReAct Loop（react-loop-and-session.md）
  ├── Context（context-management.md）──► system prompt / 历史消息 / blob 解析
  ├── Provider（provider.md）─────────► OpenAI chat completions
  ├── Tool Registry（tools.md）───────► 文件系统 / Shell
  │      └── Subagent Runner（subagents.md）──► 子进程 ap
  └── Transcript Store ──────────────► <session_id>.jsonl + blobs/
```

## 文档地图

| 文件 | 负责内容 | 状态 |
| --- | --- | --- |
| [README.md](README.md) | 总览、决策、术语、索引 | 定稿 v1 |
| [architecture.md](architecture.md) | 模块边界、依赖方向、进程模型、Odin 约束 | 定稿 v1 |
| [cli-and-config.md](cli-and-config.md) | 启动参数、输出格式、配置、工作区布局、项目识别 | 定稿 v1 |
| [react-loop-and-session.md](react-loop-and-session.md) | 循环状态机、事件 schema、恢复与重放、fork | 定稿 v1 |
| [context-management.md](context-management.md) | system prompt、记忆文件、消息投影 | 定稿 v1 |
| [provider.md](provider.md) | OpenAI 适配、SSE、usage、错误、curl 传输 | 定稿 v1 |
| [tools.md](tools.md) | 五个工具的契约、blob、进程与输出上限 | 定稿 v1 |
| [subagents.md](subagents.md) | agent 定义、启动协议、结果契约 | 定稿 v1 |
| [skills.md](skills.md) | 技能发现、SKILL.md 格式、提示词注入、`--list-skills` | 定稿 v1 |
| [errors-and-cancellation.md](errors-and-cancellation.md) | 错误分类、重试、信号、超时、恢复 | 定稿 v1 |

## 参考 Claude Code 的取舍

采纳：

| 设计 | 落在哪 |
| --- | --- |
| turn / step 两级循环 | react-loop-and-session.md |
| 事件流写 transcript（可重放） | react-loop-and-session.md |
| 记忆文件分层注入（全局 + 项目，向上查找） | context-management.md |
| 技能只注入清单、正文按需读取 | skills.md |
| 子代理：独立上下文、agent 定义文件、工具白名单 | subagents.md |
| 结构化输出（`--output-format`，token 高效、可脚本化） | cli-and-config.md |
| 工具超时、退出码作为结果 | tools.md |
| 中断语义（一次取消、二次强退） | errors-and-cancellation.md |
| 成本与 token 统计 | cli-and-config.md、react-loop-and-session.md |

不采纳（v1），理由：

| 设计 | 理由 |
| --- | --- |
| 权限审批 / allow-deny 规则 | 已明确选全自动；安全边界应放在沙箱，而不是弹窗 |
| Hooks | 本质是审批机制的变体，与无审批冲突 |
| TodoWrite | 需要 UI 才有价值；CLI 下用文本计划替代 |
| Plan mode | 与「全自动执行」目标相悖 |
| 上下文压缩 | v1 不做；后续用 handoff 替代 |
| 交互式 REPL / TUI | 第一阶段只做一次性 CLI |
| 原生后台 bash | v1 用 wrapper 脚本兜住，不提供进程管理工具族 |
| grep / glob / ls | v1 用 bash 覆盖，减少工具与 schema 复杂度 |
| MCP / 插件 | 生态型功能，先把核心循环跑通 |

## 后续版本

1. handoff：在上下文将满时把任务移交给新 session，替代压缩
2. 交互模式 / TUI
3. 并行工具调用（transcript 已按 `tool_call_id` 关联，无需改格式）
4. 后台子代理、一次 task 启动多个子代理
5. blob 的 GC 与 session 清理命令
6. 更多工具（grep / glob / webfetch 等）
