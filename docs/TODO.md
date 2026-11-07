# docs 重写工作清单

本文件是 `docs/` 全部 Markdown 文档的重写计划与验收清单。它不是规格，完成重写后保留为工作记录。

## 目标

1. 用 `technical-writing` 的方法重写 `docs/` 下的每一篇 Markdown。旧文档只作参考，不逐句搬运。
2. 事实以代码为准。每篇文档里的参数、字段、路径、函数名、退出码都要能在当前仓库里找到依据。
3. 一篇文档只服务一种阅读目的。参考文档只描述事实，操作指南只给步骤，解释文档只回答“为什么”。
4. 同一件事只在一篇文档里讲全，其它文档链接过去，不复制长段落。
5. 保持现有文件名不变，避免破坏仓库内外的链接。

## 范围

重写：

- `docs/README.md`
- `docs/architecture.md`
- `docs/dependencies.md`
- `docs/cli-and-config.md`
- `docs/react-loop-and-session.md`
- `docs/context-management.md`
- `docs/provider.md`
- `docs/tools.md`
- `docs/subagents.md`
- `docs/skills.md`
- `docs/tui.md`
- `docs/web.md`
- `docs/integration.md`
- `docs/magi.md`
- `docs/errors-and-cancellation.md`
- `docs/proposals/cli-explicit-prompt-source.md`
- `docs/proposals/cli-prompt-context-tools.md`
- `docs/proposals/sdk-scope.md`

不改：

- `docs/acp/schema.json`：外部 ACP schema，机器生成/同步的 JSON，不是散文文档。重写会破坏工具消费。
- `README.md`、`AGENTS.md`、`settings.example.json`：本轮只改 `docs/`。如果文件名变化导致链接失效，再单独修正。
- 任何代码、测试、构建脚本。

## 写作契约

所有子任务先读本文件和 `AGENTS.md`，再读被分配文档对应的代码。写作时遵守以下规则。

### 模式

| 文档 | 模式 | 读者要解决的问题 |
| --- | --- | --- |
| `README.md` | explanation | ap 是什么，为什么这样设计，术语怎么用 |
| `architecture.md` | reference | 模块怎么分，谁依赖谁，契约是什么 |
| `dependencies.md` | reference | 哪个包能 import 哪个包，检查器怎么跑 |
| `cli-and-config.md` | reference | 参数、配置、输出、存储、恢复行为是什么 |
| `react-loop-and-session.md` | reference | turn/step 怎么走，事件长什么样，怎么恢复 |
| `context-management.md` | reference | system prompt 和 messages 怎么组装 |
| `provider.md` | reference | 请求、SSE、错误怎么映射 |
| `tools.md` | reference | 五个工具的参数、结果和边界是什么 |
| `subagents.md` | reference | agent 定义、启动协议、结果契约是什么 |
| `skills.md` | reference | 技能怎么发现、解析、注入 |
| `tui.md` | reference | `ap-tui` 怎么启动 ap、怎么渲染、怎么输入 |
| `web.md` | reference | `ap-web` 的 HTTP/SSE、并发和前端行为 |
| `integration.md` | how-to | 新前端怎么把 ap 当黑盒接进去 |
| `magi.md` | reference | 三角色怎么投票，输入输出和失败语义是什么 |
| `errors-and-cancellation.md` | reference | 错误怎么分类、重试、取消、落盘 |
| `proposals/*.md` | explanation | 当时为什么提出这个变更，现在哪些已落地 |

参考文档可以有一小段“范围与理由”，只说明这篇文档解决什么问题、为什么采用当前形状。不要展开论证，不要写“我们认为”“显然”。解释文档可以表达判断，但要围绕一个真实的“为什么”，不要写成历史流水账。

### 语言

- 正文用中文，标识符、命令、路径、字段名用英文并放进代码字体。
- 术语统一：

| 用 | 不要用 |
| --- | --- |
| session | 会话（作为术语时） |
| transcript | 记录、日志（指事件集时） |
| turn | 轮次、回合 |
| step | 步骤（指一次 LLM 调用时） |
| tool call | 工具请求、函数调用 |
| 工具执行 | tool execution（正文里） |
| 子代理 | subagent（首次可写“子代理（subagent）”） |
| 恢复 | 重放（`-s` 恢复 session 时）；重放只用于读历史 |
| 取消 | 中断（用户信号导致取消时写“信号中断”） |
| provider | 服务商、模型接口 |
| blob | 大文件、缓存文件（指内容寻址存储时） |

- 一句话只做一件事。超过约 25 个字的句子拆开；操作步骤超过约 20 个字也拆开。
- 条件放在动作前面：“要恢复 session，传 `-s`。”
- 主语写清楚。参考文档用“ap”“Loop”“Provider”作主语，不用“我们”。操作指南可以对读者说“你”。
- 现在时。只有确实发生在未来的事才用“将”。
- 不用分号。要并列就断句。少用破折号，能断句就断句。
- 不用斜杠表示“或”。写“A、B 或两者”。
- 每个“它”“该”“其”都要有唯一指向。指不清就重复名词。
- 不用“进行”“实现”“起到……作用”“通过……的方式”这类空壳动词。直接写动作。
- 不用“需要注意的是”“值得一提的是”“总而言之”“首先/其次/最后”这类填充。
- 不写“简单”“快速”“轻松”。如果真简单，读者不会来看文档。
- 不写比喻、成语、拉丁缩写。不要造新词。
- 列表前用一句完整的话引入。步骤用编号，并列用项目符号。列表项保持同一语法结构。
- 标题写结论，不写主题。操作标题用动词短语，概念标题用名词短语。一篇文档只有一个 H1，不跳级。

### 结构与格式

- 开头 2–4 句：这篇文档定义什么，不定义什么，相关文档在哪。不要写“本文档旨在……”。
- 参考文档按被描述对象的结构组织，让读代码和读文档能互相对照。
- 代码块：Odin 用 tab 缩进；JSON、JavaScript、shell 按各自惯例，不混用。
- 路径写真实存在的路径。不要写不存在的脚本、目录或参数。
- 表格只放可查的事实。表格单元格里不写长句。
- 每篇文档末尾可以有“相关文档”，只放真正需要接着读的 3–6 篇。
- 删除“定稿 v1”“已实现 phase 1”这类状态标签，除非它影响读者判断。状态信息集中放在 `README.md` 的文档地图里。

### 事实校验

写作前先看代码，不要先信旧文档。至少校验：

- 参数名、默认值、互斥关系：`ap-cli/options.odin`、`magi/options.odin`。
- 配置字段与环境变量：`ap-cli/settings.odin`、`settings.example.json`。
- 事件类型与字段：`ap-core/protocol/schema.odin`、`parse.odin`。
- transcript、恢复、fork：`ap-core/engine/transcript.odin`、`session.odin`。
- 循环、重试、取消：`ap-core/engine/loop.odin`、`errors.odin`。
- provider、SSE：`ap-core/engine/provider.odin`、`sse.odin`。
- 工具：`ap-cli/tools/*.odin`、`ap-core/tool/*.odin`。
- 包边界：`tools/check-deps.sh`、`tools/check-deps.ps1`。
- 前端：`ap-tui/`、`ap-web/`、`ap-web/frontend/`、`ap-core/client/`。
- MAGI：`magi/`。

旧文档与代码冲突时，以代码为准，并在汇报里列出冲突。代码里看不到、但旧文档写成硬契约的内容，保留，并标注“需要确认”。

### 反抄袭

- 逐段重写。可以保留专有名词、字段名、命令和必要的短句，但不整段照搬旧文档。
- 同一事实在多篇文档出现时，选一篇作为归属文档写全，其它文档用一句话加链接。
- 删除重复的“为什么”“注意事项”和过长的例子。例子只留能说明边界的一个。
- 目标：总行数比当前约 5150 行减少 10%–25%，同时不丢事实。不要为凑数删契约。

## 唯一归属

| 主题 | 归属文档 | 其它文档怎么做 |
| --- | --- | --- |
| 事件 schema、turn/step、恢复、fork | `react-loop-and-session.md` | 链接，不复述字段表 |
| CLI 参数、用户可见退出码表、诊断日志、配置、存储布局、项目识别 | `cli-and-config.md` | 链接，不复述参数表 |
| 错误到退出码的映射 | `errors-and-cancellation.md` | 只写 `Error_Kind` 映射，完整表链接到 `cli-and-config.md` |
| 包布局与 import 白名单 | `dependencies.md` | 链接，不复述白名单 |
| 模块职责与进程模型 | `architecture.md` | 链接 |
| system prompt、记忆、消息投影 | `context-management.md` | 链接 |
| provider 请求、SSE、错误映射 | `provider.md` | 链接 |
| 五个工具的参数与边界 | `tools.md` | 链接 |
| 子代理定义与启动协议 | `subagents.md` | 链接 |
| 技能发现与注入 | `skills.md` | 链接 |
| 前端进程契约与 turn 生命周期 | `integration.md` | TUI/Web 文档只写自己的差异 |
| 错误分类、重试、取消、超时 | `errors-and-cancellation.md` | 链接 |
| MAGI 决策语义 | `magi.md` | 链接 |

## 分工

五个子任务并行。每个子任务只改自己名下的文件，不碰 `docs/TODO.md`、代码和 `docs/acp/schema.json`。

### A. 运行时

文件：

- [x] `docs/react-loop-and-session.md`
- [x] `docs/context-management.md`
- [x] `docs/provider.md`
- [x] `docs/errors-and-cancellation.md`

要点：

- `react-loop-and-session.md` 拥有事件 schema。保留 `session_start`、`session_end`、`user_message`、`turn_start/turn_end`、`step_start`、`message_start/message_end`、`tool_execution_start/end`、`error`、`cancel`、`usage` 的字段与约束。把 stream 事件单独成节，明确它们不落盘。
- `context-management.md` 只讲 system prompt 组装、`SYSTEM.md`、`AGENTS.md` 发现、技能清单位置、transcript 到 messages 的投影、配对校验、`context_too_long`。blob 细节链接到 `tools.md`。
- `provider.md` 只讲 OpenAI chat completions 适配、请求字段、SSE 解析、tool call 组装、`stop_reason`、usage、错误映射、curl 选项。重试策略链接到 `errors-and-cancellation.md`。
- `errors-and-cancellation.md` 只讲错误分类、重试边界、工具失败、信号与取消、超时、落盘与退出码映射。事件顺序只写取消路径需要的那一段，完整 schema 链接到 `react-loop-and-session.md`，诊断日志与用户可见退出码表链接到 `cli-and-config.md`。
- 校验 `ap-core/engine/loop.odin`、`provider.odin`、`sse.odin`、`context.odin`、`errors.odin`、`ap-core/protocol/schema.odin`。

### B. CLI 与工具

文件：

- [x] `docs/cli-and-config.md`
- [x] `docs/tools.md`
- [x] `docs/subagents.md`
- [x] `docs/skills.md`

要点：

- `cli-and-config.md` 拥有参数表、提示词来源、输出格式、日志、退出码、`settings.json`、环境变量、工作区布局、项目识别、恢复/继续/fork 的 CLI 侧行为。恢复的 schema 细节链接到 `react-loop-and-session.md`。
- `tools.md` 拥有五个工具的参数、返回、截断、blob、进程树和注册表。取消与错误分类链接到 `errors-and-cancellation.md`。
- `subagents.md` 只讲 agent 定义、内置 `general`、启动命令行、stdout 解析、结果契约、深度与失败处理。
- `skills.md` 只讲发现位置、`SKILL.md` 格式、提示词块、`--list-skills`、安全边界。
- 校验 `ap-cli/options.odin`、`settings.odin`、`run.odin`、`output.odin`、`console.odin`、`ap-cli/tools/*.odin`、`ap-cli/skills/*.odin`、`ap-core/tool/*.odin`。

### C. 架构与总览

文件：

- [x] `docs/architecture.md`
- [x] `docs/dependencies.md`
- [x] `docs/README.md`

要点：

- `dependencies.md` 拥有包布局和允许的 import 边。表格与 `tools/check-deps.sh` 的实际规则一致。写清检查器怎么跑、`--self-test` 验证什么。
- `architecture.md` 讲模块职责、依赖方向、关键接口、启动/退出/中断顺序、状态归属、内存契约、Odin 约束。不要重复 `dependencies.md` 的白名单表，链接过去。
- `docs/README.md` 是解释型入口：ap 是什么、三种进程形态、五条设计取舍、硬约束、决策表、术语、模块图、文档地图。把“参考 Claude Code 的取舍”压缩成仍然有用的几行，删除重复论证。文档地图要包含 `proposals/`，状态列保留但简化。
- 校验 `ap-core/sdk.odin`、`engine/session.odin`、`engine/context.odin`、`ap-core/tool/`、`ap-core/platform/`、`tools/check-deps.sh`。

### D. 前端与集成

文件：

- [x] `docs/tui.md`
- [x] `docs/web.md`
- [x] `docs/integration.md`

要点：

- `integration.md` 是唯一 how-to。按“找到 ap → 拼命令行 → 设 cwd → 处理三个流 → 跟 turn 生命周期 → 解析事件 → 管 session → 取消与并发 → 验收”组织。事件字段只列集成方必须处理的，完整 schema 链接到 `react-loop-and-session.md`。
- `tui.md` 只写 `ap-tui` 的进程模型、调用参数、session 管理、历史重放、渲染、输入层、命令、构建测试和已知限制。通用进程契约链接到 `integration.md`。
- `web.md` 只写 `ap-web` 的 HTTP/SSE、API 表、并发、目录选择、前端、构建、安全和实现细节。通用 turn 生命周期链接到 `integration.md`。
- 校验 `ap-tui/`、`ap-web/`、`ap-web/frontend/`、`ap-core/client/`、`ap-core/protocol/`。

### E. MAGI 与历史方案

文件：

- [x] `docs/magi.md`
- [x] `docs/proposals/cli-explicit-prompt-source.md`
- [x] `docs/proposals/cli-prompt-context-tools.md`
- [x] `docs/proposals/sdk-scope.md`

要点：

- `magi.md` 只讲角色、输入、输出、决策规则、执行模型、提示词层次、解析与失败、配置、退出码、安全边界、测试。
- 三篇 proposals 是解释型设计记录，不是当前规格。开头写清状态：已落地、部分落地或被取代。正文回答“当时的问题是什么、选了哪个方案、放弃了什么、怎么迁移”。不要用现在时把未落地开关写成当前行为。
- 逐项对照当前代码和 `docs/cli-and-config.md`，标出：
  - `cli-explicit-prompt-source.md`：三选一是否已落地。
  - `cli-prompt-context-tools.md`：`--no-agents-md`、`--no-skills` 已落地；`--base-system-prompt*`、`--tools`、`--list-tools` 是否落地，以当前代码为准。
  - `sdk-scope.md`：SDK 边界收窄是否已落地。
- 校验 `magi/`、`ap-cli/options.odin`、`ap-core/sdk.odin`。

## 审查波次

五个子任务完成后，再做一次集中审查：

- [x] 交叉核对所有文档里的参数名、环境变量、字段名、退出码，确认只有一处定义，其它地方链接。
- [x] 检查每篇文档是否只有一个模式。参考文档里出现步骤、操作指南里出现大段原理，都要拆开或删掉。
- [x] 检查术语是否统一，特别是 session / turn / step / transcript / 子代理 / 取消。
- [x] 检查所有相对链接指向存在的文件。
- [x] 检查 `docs/README.md` 的文档地图覆盖全部 Markdown，包括 `proposals/` 和 `TODO.md`。
- [x] 对照 `README.md` 的文档表，确认没有新增未登记的文档。
- [x] `git diff --stat` 只包含 `docs/`。
- [x] 抽查 10 个关键事实：提示词三选一、`--fork-session`、`stop_reason` 取值、退出码、`session_start.tools`、blob 阈值、`max_agent_depth`、事件是否带 `seq`、默认监听地址、MAGI 一票否决。
- [x] 通读一遍，删掉机器味：连续短句、每段同长度、空泛总结、重复开头。

### 审查记录

集中审查修正了以下跨文档冲突：

- `turn_end.stop_reason` 只写五个值。`tool_use` 属于 `message_end`，不属于 `turn_end`。
- 前端历史重放可以在 blob 缺失时退化为 `*_preview`。这是展示层行为，不是 agent 恢复规则；agent 恢复仍然退出 2。
- 用户可见退出码表和诊断日志归 `cli-and-config.md`，`errors-and-cancellation.md` 只保留 `Error_Kind` 映射和链接。
- `subagents.md` 的 `model` 与 `max_steps` 字段说明补充了 `task` 启动时的实际优先级。
- 恢复时截掉不完整尾行、读取时忽略最后一条损坏行的区别已在 `architecture.md`、`react-loop-and-session.md`、`errors-and-cancellation.md` 对齐。
- `bash` 默认超时改为 `min(tool_timeout_ms, 600000)`。
- 连续 assistant 消息的合并规则按代码改为“左边没有内容时取右边”。

## 验证记录

- `./test.sh` 通过，`tools/check-deps.sh` 输出 `check-deps: ok`。
- 首次全量运行出现过一次 `apweb.test_api_turn_validation_and_single_flight` 的 `turn:1` 断言失败；该用例单独重跑通过，第二次全量运行也通过。失败与本次文档改动无关，属于已有测试的时序抖动。
- 所有 Markdown 相对链接可解析，每篇文档只有一个 H1，没有跳级标题。
- `docs/` 从约 5150 行降到 3903 行，减少约 24%。`docs/acp/schema.json` 未改。
- `git status` 只显示 `docs/` 下的 Markdown 变更。

## 完成标准

- 18 篇 Markdown 全部重写，`docs/acp/schema.json` 未改。
- 没有整段照搬旧文档。相同事实只在一处展开。
- 代码能确认的事实与代码一致；不能确认的契约已标注。
- 所有链接可解析，`docs/README.md` 地图完整。
- 没有改动代码、构建产物或未授权文件。
