# 变更记录：SDK 边界收窄为 agent 运行时

状态：**已落地**。当前模块职责、包布局与 import 白名单分别以 [architecture.md](../architecture.md) 和 [dependencies.md](../dependencies.md) 为准。本文只记录当时为什么把 SDK 与 coding agent 的产品策略拆开。

## 当时的问题

旧 SDK 把 agent 机制和 ap 的产品策略放在同一层。

具体工具写死在 SDK 里。`ALL_TOOL_NAMES` 是 `[5]string`，`TOOL_INFOS` 保存五个工具的描述与 JSON Schema，`tool_execute` 用 `switch name` 分发到实现。新增或删除一个工具必须改 SDK。

`task` 工具在 SDK 内拉起 `ap` 子进程，解析 `stream-json`。这形成了一条反向依赖：SDK 依赖 CLI 的可执行文件和输出协议。任何只想复用 loop 的宿主，都会被这条链路拖上一个完整 CLI。

system prompt 的段落顺序被 SDK 写死。技能扫描、`AGENTS.md` 读取、环境段、agent 定义正文和追加指令都在 `engine` 里拼接。宿主没有办法在不改 SDK 的情况下换一种顺序，或去掉自己不关心的段落。

`Settings` 同时包含 provider、loop、transcript、工具超时、捕获上限和子代理深度。`Session_Request` 还带 `config_dir`、`home_dir`、`self_exe`、`bash_path`、`no_agents_md`、`no_skills`。结果是一个「agent 运行时」被迫认识文件布局、技能目录和子代理命令行。

这组耦合让两件事同时变难：ap 想改工具或提示词，要动 SDK；别的宿主想只用 loop，也要背着 coding agent 的策略。

## 选择的切分

方案只用一个判断：**机制留在 SDK，策略留给 adapter**。

| 层 | 负责 |
| --- | --- |
| SDK `engine` | agent loop、provider、transcript、session 生命周期、context 投影、工具执行管线 |
| SDK `ap-core/tool` | 工具契约、注册表、参数助手、执行入口、blob 文本读取 |
| SDK `apcore` | 门面：`Config`、`Env`、`Session_Options`、session 生命周期、类型别名 |
| `ap-cli` | 参数、`settings.json`、环境发现、agent 解析、prompt sections、输出、退出码、信号、组装根 |
| `ap-cli/tools` | 五个内置工具与进程树管理 |
| `ap-cli/skills` | 技能发现、frontmatter 解析、提示词块、`--list-skills` 文本 |

system prompt 也按同一刀切：

```text
SDK 固定：
  1. base 提示词
  2. 工具段
  3. prompt_sections[]，按调用顺序原样拼接

adapter 决定：
  prompt_sections 的内容、顺序与标题
```

SDK 只保证每个非空 section 前有一个空行，并在 section 不以换行结尾时补一个。它不解析 Markdown，不自动加标题，不合并空白。默认的「环境 → 技能 → 全局记忆 → 项目记忆 → agent 正文 → 追加指令」属于 `ap-cli/prompt.odin`，不是 SDK 规则。

工具也按契约与实现分开。SDK 只接收 `[]Tool`，`Tool.user` 是宿主绑定的不透明配置。`task` 的子进程参数、`stream-json` 解析和 skill 开关都由应用层持有。

## 落地核对

当前代码已经按这个切分运行：

- `ap-core/tool/` 存在，提供 `Tool`、`Tool_Context`、`Tool_Result`、`Registry`、`Progress_Kind`、注册与执行管线。
- `ap-core/engine/` 只剩机制模块：`config`、`context`、`errors`、`loop`、`provider`、`sse`、`session`、`transcript`，没有具体工具、技能发现、agent 文件解析或进程管理。
- `ap-cli/tools/` 有五个工具、`Tool_Config` 和进程树清理。`ap-cli/skills/` 负责技能。`ap-cli/agent.odin` 解析 agent 定义。`ap-cli/prompt.odin` 组装 sections。
- `Session_Request` 的 prompt、模型与工具字段都是已解析值：`agent_name`、`model`、`max_steps`、`max_tokens`、`base_system_prompt`、`prompt_sections`、`tools`。没有 `config_dir`、`home_dir`、`self_exe`、`bash_path`、`no_agents_md`、`no_skills`。
- `Settings` 只保留 `model`、`base_url`、`api_key`、`max_steps`、`max_tokens`、`llm_timeout_ms`、`blob_threshold_bytes`、`stream_include_usage`。工具超时、捕获上限和子代理深度在 `aptools.Tool_Config`。
- `env_open` 只确保配置目录可写、解析 cwd 与 project、校验并复制工具注册表。它不读配置文件，不找 bash，不猜子代理可执行文件。
- `apcore` 不再提供 `all_tool_names`、`select_tools`、`list_tools_text`、`list_skills_text`。工具与技能查询属于应用层。
- `preview_prompt` 与 `session_open` 共用 `resolve_session`，恢复与 fork 都读冻结的 prompt 与工具集。
- `magi` 是第二个宿主。它只 import `apcore` 与 `ap-core/platform`，用 `env_open` 建立空工具注册表，再用 `Session_Options` 给每名成员组装独立 session。

依赖方向由 `tools/check-deps.sh` 与 `tools/check-deps.ps1` 检查。白名单不在本文复制，见 [dependencies.md](../dependencies.md)。

## 放弃的方案

保留具体工具，只增加一个「工具可替换」的注入点。这没有解决核心问题。工具名、Schema 和子代理命令行仍然属于 SDK，`task` 仍然反向依赖 CLI。

只把 `task` 移出去，保留其它四个工具。工具集仍然写死在 SDK 的 `ALL_TOOL_NAMES` 里，新增文件工具仍要改 SDK。

保留 SDK 内的 prompt 组装，用更多布尔参数控制段落。参数会持续增长，宿主仍然不能决定顺序。把 sections 交给 adapter 更直接，也让「哪些段落属于产品策略」变成代码结构问题，而不是开关组合问题。

使用全局可变工具注册表。测试之间会互相污染，工具与 `Tool.user` 的生命周期也难界定。显式传入 `[]Tool` 让所有权更清楚。

## 迁移

方案按阶段落地：先抽出工具契约与注册表，再迁五个工具，再改 prompt sections，再迁 agent 解析，最后收窄 `Settings` 并清理门面。每一步都保持可编译、可测试。

`settings.json` 的文件格式与字段名没有变。变化只在读取后的归属：`ap-cli/settings.odin` 一次读取，再拆成 `apcore.Settings` 与 `aptools.Tool_Config`。外部用户不需要改配置文件。

transcript schema 没有变。`session_start.content` 仍是冻结的 system prompt，超过 blob 阈值时改为 `content_ref`。`session_start.tools` 仍是冻结的工具集。

这是 `apcore` 的破坏性 API 变更。仓库内只有 `ap-cli` 和 `magi` 两个宿主，迁移成本可控。外部宿主要按新的 `Config` / `Session_Options` 重写组装层。

## 还剩下什么

边界收窄已经完成，剩下的是使用这套边界的成本。

宿主必须自己组装 prompt 策略。`ap-cli/prompt.odin` 是 ap 的参考实现，不是 SDK 的默认值。新宿主如果直接传空 sections，得到的 prompt 只有 base 与工具段。这个结果是有意的，但意味着「像 ap 一样」需要复制 section 组装，而不是调用一个 SDK 函数。

`magi` 就是这种成本的例子。它的 base 只有公共投票规则与角色正文，不注入环境、记忆、技能或 agent 正文。它通过 `Session_Options` 得到想要的最小 prompt，而不是把 coding agent 的段落全带上。

工具策略仍然集中在应用层。五个工具的行为、超时、捕获上限和子代理深度都由 `aptools.Tool_Config` 决定。SDK 只执行管线，不理解这些字段。新增工具时改 `ap-cli/tools`，不需要改 `ap-core/tool`。

`platform`、`protocol`、`client` 没有移动。provider 仍留在 SDK，默认实现是 `provider_stream`。`Loop` 内部有 `Provider_Call` 函数指针，但它不是 `apcore` 的公开接口，宿主不能通过它替换 provider。

## 相关文档

- [architecture.md](../architecture.md)：当前模块职责、进程模型与启动顺序
- [dependencies.md](../dependencies.md)：包布局与允许的 import 边
- [context-management.md](../context-management.md)：SDK 固定段与 adapter sections 的最终规则
- [tools.md](../tools.md)：工具契约与五个工具实现的分工
- [subagents.md](../subagents.md)：`task` 与应用层子进程启动
