# 变更方案：收窄 SDK 边界为 agent 运行时

状态：**草案，待评审**。评审通过后再落到 `docs/*.md` 与代码；本文件不属于定稿规格。

## 1. 摘要

当前 SDK（`apcore` + `ap-core/engine`）把 agent 机制和 coding agent 的产品策略混在一起：

- 五个内置工具、工具白名单、工具 schema 写死在 SDK；
- `task` 工具在 SDK 里拉起 `ap` 子进程、解析 `stream-json`，形成对 CLI 的反向依赖；
- skill 发现、`AGENTS.md`、环境段、agent 定义正文、`--append-system-prompt` 都由 SDK 拼进 system prompt；
- `Settings` 同时包含 provider、loop、transcript、工具与子代理的参数。

本方案把边界收紧为：

- **SDK 只保留机制**：agent loop、provider、transcript、session 生命周期、context 投影、工具契约 / 注册表 / 执行管线。
- **应用层负责策略**：内置工具、skill、`AGENTS.md`、环境段、agent 定义解析、`--append-system-prompt`、子代理启动。
- **system prompt 只由 SDK 固定 base 与工具段；其余段落全部由应用层按顺序 append。**
- SDK 的 `Session_Options` 接收已解析的会话参数，不再读 agent 文件、技能目录或记忆文件。

迁移完成后，`ap-tui` / `ap-web` 的进程契约不变；`ap` 的默认用户可见行为保持不变，默认 system prompt 逐字节一致。

## 2. 现状与问题

### 2.1 工具

| 文件 | 现状 |
| --- | --- |
| `ap-core/engine/config.odin` | `ALL_TOOL_NAMES` 是 `[5]string`；`tool_name_valid`、`select_tools` 以它为准 |
| `ap-core/engine/tools_registry.odin` | `TOOL_INFOS` 写死五个工具的描述与 JSON Schema；`tool_definitions` / `tool_prompt_section` 直接使用 |
| `ap-core/engine/tools.odin` | `tool_execute` 用 `switch name` 分发到具体工具 |
| `ap-core/engine/tool_task.odin` | import `protocol`，拉起 `ap` 子进程，解析 stream-json，依赖 `self_exe` / `bash_path` / `no_skills` |
| `apcore/sdk.odin` | `all_tool_names`、`list_tools_text`、`select_tools` 把工具集暴露给宿主 |

问题：

1. SDK 知道具体工具名、参数和子代理命令行；新增/删除工具必须改 SDK。
2. 其他宿主无法只复用 loop，必须背着 coding agent 的工具集。
3. `task` 是 CLI 行为，不是 agent 运行时机制。

### 2.2 skill 与 system prompt

| 文件 | 现状 |
| --- | --- |
| `ap-core/engine/session.odin` | `resolve_session` 直接调用 `load_agent`、`discover_skills`、`build_system_prompt`；`no_skills` / `no_agents_md` / `append_system_prompt` 是会话参数 |
| `ap-core/engine/context.odin` | `build_system_prompt` 固定拼接 base → 工具 → 环境 → 技能 → 全局记忆 → 项目记忆 → agent 正文 → 追加指令 |
| `ap-core/engine/skills.odin` | 扫描 `~/.agents/skills` 与项目 `.agents/skills`，解析 frontmatter，生成提示词块与 `--list-skills` 文本 |
| `ap-core/engine/prompts/system.md` | base 提示词通过 `#load` 内嵌 |

问题：skill 是 ap 的产品约定，不是 agent loop 机制；提示词顺序被 SDK 写死，宿主无法在不改 SDK 的情况下组装自己的 prompt。

### 2.3 配置与 agent 定义

- `Settings` 同时包含 provider（`base_url` / `api_key` / `llm_timeout_ms`）、loop（`max_steps` / `max_tokens`）、transcript（`blob_threshold_bytes`）、工具（`tool_timeout_ms` / `max_capture_bytes`）和子代理（`max_agent_depth`）。
- `Session_Request` 带 `config_dir`、`home_dir`、`self_exe`、`bash_path`、`no_agents_md`、`no_skills`。
- `engine/config.odin` 既定义 `Settings` 默认值，又解析 `agents/*.md` 的 frontmatter。

问题：SDK 的配置结构和文件解析跟着产品策略长，宿主无法只配置自己关心的部分。

## 3. 设计原则与已接受决策

| 决策 | 结论 |
| --- | --- |
| SDK 定位 | agent 运行时：机制，不包含 coding agent 的产品策略 |
| 具体工具实现 | 移到应用层；SDK 只保留工具契约、注册表、执行管线 |
| `task` | 属于应用层；SDK 不再知道子进程命令行与 stream-json |
| skill | 属于应用层；SDK 不再扫描目录、不解析 `SKILL.md` |
| `AGENTS.md` / 环境段 / agent 正文 | 属于应用层；由应用层组装成 prompt section |
| system prompt | SDK 固定 base 与工具段；其余全部由应用层按序 append |
| append 生效时机 | 仅新 session 建会话时；随 `session_start` 冻结 |
| 恢复 / fork | 使用冻结 prompt 与冻结工具集；append 输入一律忽略，只 warning |
| 工具上下文 | 通用字段 + 不透明 `user` 配置；SDK 不感知 `self_exe` / `bash_path` / skill 开关 |
| 工具注册方式 | 显式传入 `[]Tool`，不使用全局可变注册表 |
| `settings.json` | 文件格式不变；内部拆成 SDK `Settings` 与工具配置 |
| provider / platform / protocol | 本轮不移动；SDK 保留默认 OpenAI provider 与 `Stream_Fn` 注入点 |
| transcript schema | 不改；继续用 `session_start.content` 与 `session_start.tools` 冻结 |
| 默认提示词 | 迁移后逐字节一致（除必须由应用层注入的时间等动态内容） |

## 4. 目标架构

### 4.1 模块职责

| 层 | 负责 | 明确不做 |
| --- | --- | --- |
| SDK `engine` | loop 状态机、provider、transcript、session 生命周期、context 投影、工具执行管线 | 具体工具、skill、`AGENTS.md`、agent 文件解析、子代理启动 |
| SDK `ap-core/tool` | `Tool` / `Tool_Context` / `Tool_Result` / `Registry` / 进度事件 | 具体工具实现、进程管理策略 |
| SDK `apcore` | 门面：`Config` / `Env` / `Session_Options` / 会话生命周期 / 类型别名 | 读 argv、读 settings.json、写 stdout、装信号 |
| 应用 `ap-cli` | 参数、settings、环境发现、输出、退出码、信号、**组装根** | agent loop、provider、transcript |
| 应用 `ap-cli/tools` | `read_file` / `write_file` / `edit_file` / `bash` / `task` | 修改 transcript、控制 loop |
| 应用 `ap-cli/skills` | 技能发现、frontmatter 解析、提示词块、`--list-skills` 文本 | 执行技能正文 |
| 应用 `ap-cli` prompt 组装 | 环境段、记忆段、agent 正文、`--append-system-prompt`、`--base-system-prompt` 规范化 | 改 base 与工具段的格式 |

### 4.2 依赖方向

单向，违反即视为设计错误：

```
cmd/ap ──► ap-cli（package apcli）
             ├──► apcore
             ├──► ap-core/platform, ap-core/protocol
             ├──► ap-cli/tools（package aptools）
             └──► ap-cli/skills（package apskills）

ap-cli/tools ──► ap-core/tool, ap-core/platform, ap-core/protocol
ap-cli/skills ──► ap-core/platform

apcore ──► engine, ap-core/tool, platform, protocol
engine ──► ap-core/tool, platform, protocol
ap-core/tool ──► platform, protocol
platform ──► core: / vendor:
protocol ──► core:
```

禁止：

- `engine` import `apcore`、`ap-cli`、`ap-cli/tools`、`ap-cli/skills`；
- `ap-cli` 直接 import `engine`；
- `ap-core/tool` import `engine`（否则形成契约与实现的环）；
- `ap-cli/tools` import `apcore` 根包（需要类型时只 import `ap-core/tool`）。

### 4.3 包布局

```
ap-core/
  tool/              package tool：工具契约与注册表
  engine/            package engine：loop / provider / session / context / transcript
  platform/          package platform：路径、project/session、blob、进程树、取消
  protocol/          package protocol：事件 schema、解析、行分帧
  sdk.odin           package apcore：SDK 门面
ap-cli/
  tools/             package aptools：五个内置工具
  skills/            package apskills：技能发现与提示词块
  agent.odin         package apcli：agent 定义解析（新增或从 engine 迁入）
  prompt.odin        package apcli：system prompt section 组装（新增）
  run.odin           package apcli：组装根
  options.odin       package apcli：参数解析
  settings.odin      package apcli：settings.json 解析与拆分
  output.odin        package apcli：输出格式
```

`ap-cli/tools` 与 `ap-cli/skills` 是独立包，不是 `apcli` 同包文件。Odin 同目录即同包，拆子目录可以让 CLI adapter 不被工具实现撑大。

## 5. SDK 接口

### 5.1 工具契约（`ap-core/tool`）

```odin
package tool

import "../platform"
import "core:encoding/json"

Progress_Kind :: enum {
	Block,
	Line,
}

Function_Def :: struct {
	name:        string,
	description: string,
	parameters:  json.Value,
}

Tool_Def :: struct {
	type:     string,
	function: Function_Def,
}

Tool_Result :: struct {
	ok:          bool,
	content:     string,
	error:       string,
	duration_ms: int,
	exit_code:   Maybe(int),
	metadata:    json.Value,
	fatal:       bool,
}

Tool_Context :: struct {
	cwd:          string,
	project:      platform.Project,
	cancel:       ^platform.Cancel_Token,
	session_id:   string,
	tool_call_id: string,
	agent_name:   string,
	agent_depth:  int,

	on_update:     proc(user: rawptr, chunk: string),
	update_user:   rawptr,
	on_progress:   proc(user: rawptr, kind: Progress_Kind, line: string),
	progress_user: rawptr,
}

Tool :: struct {
	name:            string,
	description:     string,
	parameters_json: string, // JSON Schema 文本，沿用现有解析方式
	user:            rawptr, // 应用层配置；SDK 视为不透明
	execute: proc(
		user: rawptr,
		args: json.Value,
		ctx:  ^Tool_Context,
	) -> Tool_Result,
}

Registry :: struct {
	tools: []Tool,
}
```

约束：

1. `Tool.user` 用于绑定每工具的宿主配置（例如 `bash_path`、`self_exe`、超时、最大捕获字节）。SDK 不解释它。
2. `Tool_Context` 不再包含 `Settings`、`self_exe`、`bash_path`、`config_dir`、`no_skills`、`no_agents_md`、`max_steps`。
3. `Tool_Result` 字段保持不变；`fatal` 语义不变：基础设施故障才终止 turn。
4. `Progress_Kind` 从 engine 移到 tool；engine 可以用类型别名保持内部代码兼容。
5. 注册表在 session 生命周期内不可变；重复工具名、空工具名在注册时拒绝。
6. `Registry.tools` 的顺序是声明顺序，也是工具 schema 与提示词工具段的顺序；`Session_Options.tools` 只是过滤器，不改变顺序。
7. `Registry` 的切片与每个 `Tool.user` 必须活得比 `Env` / `Session` 长；由应用层持有。

### 5.2 `Config` / `Env`

```odin
Config :: struct {
	config_dir: string,
	cwd:        string,
	settings:   Settings,
	tools:      []Tool,
}

Env :: struct {
	config_dir: string,
	cwd:        string,
	project:    Project,
	settings:   Settings,
	tools:      Registry,
}
```

`env_open` 只做三件事：

1. 确保配置目录可写；
2. 解析 cwd、打开 project；
3. 校验并保存工具注册表。

`env_open` 不再解析 `child_agent_bin`、`bash_path`、`home_dir`。`child_agent_bin` 与 `bash_path` 属于应用层工具配置。

### 5.3 `Session_Options`

```odin
Session_Options :: struct {
	kind:              Session_Kind,
	source_session_id: string,

	// 以下字段只在新 session 生效；恢复 / fork 时使用冻结值。
	agent_name:          string, // 仅作标签，不触发文件读取
	model:               string, // 空 = 用 Settings.model
	max_steps:           int,    // 0 = 用 Settings.max_steps
	max_tokens:          int,    // 0 = 用 Settings.max_tokens
	agent_depth:         int,
	parent_session_id:   Maybe(string),
	parent_tool_call_id: Maybe(string),

	base_system_prompt: Maybe(string), // 空 = 用 SDK 内置 base
	prompt_sections:    []string,      // 按顺序 append；空串跳过
	tools:              []string,      // 生效工具集；空切片 = 零工具
}

// 追加一段 system prompt；顺序 = 调用顺序。
session_options_append :: proc(opts: ^Session_Options, section: string) {
	if len(section) == 0 {
		return
	}
	append(&opts.prompt_sections, section)
}
```

说明：

1. `Session_Options` 全部是**已解析值**。它不再包含 `config_dir`、`home_dir`、`self_exe`、`bash_path`、`no_skills`、`no_agents_md`、`append_system_prompt`、`agent`。
2. `agent_name` 只用于写入 `session_start` 与显示；恢复时以冻结值为准。
3. `prompt_sections` 只在 `session_open` / `preview_prompt` 调用期间被读取；SDK 不保留该切片。
4. `tools` 为空切片表示零工具，不能省略；应用层默认传入所有注册工具的名字。
5. `session_options_append` 只是便利函数；直接 `append(&opts.prompt_sections, s)` 等价。

### 5.4 system prompt 组装

SDK 只固定两段：

```text
1. base 提示词        ← 内置 SYSTEM_PROMPT，或 base_system_prompt
2. 工具说明           ← 由注册表 + 生效工具集生成，格式沿用现有实现
3. prompt_sections[]  ← 应用层按调用顺序追加，原样拼接
```

拼接规则：

```odin
prompt := base
if !has_suffix(prompt, "\n") {
	prompt += "\n"
}
prompt += "\n## 工具\n"
prompt += tool_section
prompt += "\n"

for section in sections {
	if len(section) == 0 {
		continue
	}
	prompt += "\n"
	prompt += section
	if !has_suffix(section, "\n") {
		prompt += "\n"
	}
}
```

约定：

1. SDK 不解析 section，不自动加标题，不合并空白；section 是原始 Markdown 块。
2. SDK 保证每个非空 section 前有一个空行，并在 section 不以 `\n` 结尾时补一个；section 自带的结尾空白原样保留。
3. 应用层负责 CRLF→LF、首尾空白、section 内部顺序与标题，并保证 section 不以多余空行结尾。
4. 工具段格式不变：`## 工具` + `registry_prompt_section` 的输出；零工具时仍写 `（本次没有可用工具）`。
5. 默认情况下，应用层按以下顺序追加 section，保证与当前默认 prompt 一致：

```text
## 环境
## 可用技能
## 全局记忆 (AGENTS.md)
## 项目记忆 (<file>)
## Agent 定义 (<name>)
## 追加指令
```

### 5.5 冻结、恢复与预览

| 场景 | system prompt | 工具集 |
| --- | --- | --- |
| 新 session | 组装 base + 工具段 + sections，可能写 blob，写入 `session_start.content` | 写入 `session_start.tools` |
| 恢复 | 从 `session_start` 读取冻结 prompt | 以 `session_start.tools` 过滤注册表 |
| fork | 复制源 session 的冻结 prompt 与工具集 | 同左 |
| `preview_prompt` 新 session | 与 `session_open` 走同一个组装函数，逐字节一致 | 同左 |
| `preview_prompt` 恢复 / fork | 返回冻结 prompt | 同左 |

恢复 / fork 时，以下输入只 warning、不生效：

```text
--base-system-prompt ignored on restore: session prompt is frozen
prompt sections ignored on restore: session prompt is frozen
tool set ignored on restore: session is frozen to its recorded tool set
--agent ignored on restore: session is frozen to "<name>"
```

工具集恢复规则：

1. 以 `session_start.tools` 为准，不再读取 agent 文件。
2. 冻结列表中的工具名如果在当前注册表中不存在，**跳过并 warning**，不终止会话。
3. 新 session 的 `tools` 出现未知名字属于应用层错误，返回 `.Usage` 错误。

### 5.6 工具执行管线

Loop 仍然负责：

1. 按 step 读取 assistant 的 tool calls，串行执行；
2. 执行前检查取消标志；
3. 写 `tool_execution_start` / `tool_execution_end`；
4. 参数或结果超过 `blob_threshold_bytes` 时写 blob 并记录引用；
5. `fatal` 时写 `error(scope=tool)` 并终止 turn；
6. 把 `on_update` / `on_progress` 转给 emitter。

工具自身负责：

1. 参数校验与执行；
2. 遵守 `ctx.cancel`，取消时终止自己的子进程树；
3. 返回 `Tool_Result`，不直接写 transcript；
4. 需要时通过 `platform` 读写自己的辅助文件（例如 `bash` 的 `.txt` 分页产物）。

接口变化：

```odin
registry_definitions :: proc(
	registry:     ^Registry,
	active_tools: []string,
) -> ([]Tool_Def, Error)

registry_prompt_section :: proc(
	registry:     ^Registry,
	active_tools: []string,
) -> string

tool_execute :: proc(
	registry: ^Registry,
	name:     string,
	args:     json.Value,
	ctx:      ^Tool_Context,
) -> Tool_Result
```

`active_tools` 是过滤集合；输出顺序始终按 `Registry.tools` 的声明顺序。

### 5.7 `Settings`

SDK 只保留与机制相关的字段：

```odin
Settings :: struct {
	model:                string,
	base_url:             string,
	api_key:              string,
	max_steps:            int,
	max_tokens:           int,
	llm_timeout_ms:       int,
	blob_threshold_bytes: int,
	stream_include_usage: bool,
}
```

移出 SDK：

| 字段 | 新归属 |
| --- | --- |
| `tool_timeout_ms` | `ap-cli/tools` 工具配置 |
| `max_capture_bytes` | `ap-cli/tools` 工具配置 |
| `max_agent_depth` | `ap-cli/tools` / 子代理配置 |
| `path` | `ap-cli/settings.odin` |

`settings.json` 的文件格式与字段名不变；`ap-cli/settings.odin` 一次读取，再拆成 `apcore.Settings` 与 `aptools.Tool_Config`。

## 6. 应用层职责

### 6.1 启动流程

```text
1. parse args
2. 解析 config_dir / cwd / home_dir
3. 读取 settings.json → SDK Settings + Tool_Config
4. 定位 bash
5. 发现 skill（--no-skills 时跳过）→ skill section
6. 读取 AGENTS.md（--no-agents-md 时跳过）→ memory sections
7. 解析 agent 定义 → name / model / max_steps / tools / body
8. 组装工具注册表 → 应用 agent / --tools 白名单与深度规则
9. 组装 prompt sections：环境 → 技能 → 全局记忆 → 项目记忆 → agent 正文 → 用户追加
10. env_open(Config{config_dir, cwd, settings, tools})
11. session_open(env, Session_Options{...})
12. turn_run / session_close
```

`--list-skills`、`--list-tools`、`--print-system-prompt` 仍由应用层处理，不创建 session、不需要 API key。

### 6.2 工具

`ap-cli/tools` 实现五个工具，语义与 `docs/tools.md` 完全一致：

- `read_file` / `write_file` / `edit_file`：文件工具；
- `bash`：Bash 子进程、进程树、输出上限、分页 `.txt`；
- `task`：拉起 `ap` 子进程、解析 stream-json、结果元数据。

工具配置：

```odin
Tool_Config :: struct {
	config_dir:        string,
	bash_path:         string,
	self_exe:          string,
	model:             string,
	max_steps:         int,
	tool_timeout_ms:   int,
	max_capture_bytes: int,
	max_agent_depth:   int,
	no_agents_md:      bool,
	no_skills:         bool,
	tools_set:         bool,
	tools:             []string, // tools_set 时用于子代理传播
}
```

每个内置 `Tool.user` 指向同一个 `Tool_Config`（或按工具拆分的子结构）。应用层保证它在 session 期间存活。

白名单规则（从 SDK 移到应用层）：

```text
CLI --tools  >  agent 定义 tools:  >  全部已注册工具
task 在 agent_depth >= max_agent_depth 时从生效集合移除
```

`--list-tools` 使用同一个注册表与白名单解析函数，输出格式不变。

### 6.3 skill

`ap-cli/skills` 迁移现有 `engine/skills.odin`：

- 发现 `~/.agents/skills/<name>/SKILL.md` 与 `<cwd>/.agents/skills/<name>/SKILL.md`；
- 解析 frontmatter、同名覆盖、按 name 排序；
- 生成 `## 可用技能` 块；
- 生成 `--list-skills` 简表。

`--no-skills` 只影响提示词注入，不影响 `--list-skills`。SDK 中不再出现 `skill` 概念。

### 6.4 agent 定义

`apcli/agent.odin` 迁移 `engine/config.odin` 中的 agent 解析：

- 文件位置与 frontmatter 格式不变；
- 解析 `name` / `description` / `tools` / `model` / `max_steps` / 正文；
- 应用层解析优先级：CLI > agent 定义 > settings；
- 解析后的值通过 `Session_Options` 传给 SDK。

恢复时不再重新加载 agent 文件；`session_start` 已冻结 prompt、`agent_name`、`model`、`tools`。这样修改 agent 文件不会改变已有 session。

### 6.5 子代理

`task` 在 `ap-cli/tools` 中组装子进程参数，SDK 不参与：

```text
ap --agent <name> --output-format stream-json --print0
   --parent-session-id <id> --parent-tool-call-id <id>
   --agent-depth <n+1> --config-dir <dir> --model <m> --max-steps <n>
   [--no-agents-md] [--no-skills] [--tools ...]
```

深度规则不变；`--tools`、`--no-agents-md`、`--no-skills` 的传播规则不变。

## 7. 数据模型与兼容性

### 7.1 `Session_Request`

内部 `Session_Request` 与 `apcore.Session_Options` 对齐：

```odin
Session_Request :: struct {
	kind:              Session_Kind,
	project:           platform.Project,
	settings:          ^Settings,
	source_session_id: string,

	agent_name:        string,
	model:             string,
	max_steps:         int,
	max_tokens:        int,
	agent_depth:       int,
	parent_session_id: Maybe(string),
	parent_tool_call_id: Maybe(string),

	base_system_prompt: Maybe(string),
	prompt_sections:    []string,
	tools:              []string,
}
```

删除：`config_dir`、`cwd`、`home_dir`、`self_exe`、`bash_path`、`agent`、`no_agents_md`、`no_skills`、`append_system_prompt`、`tools_set`。

### 7.2 `session_start`

schema 不变：

- `content` 仍是最终 system prompt（或 blob 引用）；
- `tools` 仍是生效工具集；
- `agent_name`、`model`、`agent_depth`、`cwd`、`parent_*` 继续冻结。

语义澄清：`tools` 记录的是**应用层应用白名单与深度规则后的生效集合**。当前文档把 `task` 的深度移除描述为运行期行为；迁移后由应用层在建会话前完成，`session_start.tools` 直接反映最终结果。`--list-tools` 与 `session_start.tools` 的差异因此消失，文档需要同步修正。

旧 transcript 兼容：

- 新二进制读取旧 transcript：`tools` 缺失时按旧逻辑回退到 agent 定义？**不再回退**。应用层无法知道旧 agent 定义时，使用注册表全部工具，并 warning。
- 旧二进制读取新 transcript：`tools` 字段已知，不受影响。

### 7.3 `settings.json`

文件格式不变。映射：

| 字段 | 归属 |
| --- | --- |
| `model`, `base_url`, `api_key` | SDK / provider |
| `max_steps`, `max_tokens`, `blob_threshold_bytes`, `stream_include_usage` | SDK / loop |
| `llm_timeout_ms` | SDK / provider |
| `tool_timeout_ms`, `max_capture_bytes`, `max_agent_depth` | 应用层 / tools |
| `path` | 应用层 |

### 7.4 `apcore` 门面

保留：

- `env_open` / `session_request` / `preview_prompt` / `session_open` / `turn_run` / `session_close`；
- `settings_defaults`（只含 SDK 字段）；
- `Error` / `Session` / `Emitter` / `Project` / `Cancel_Token` 等类型别名；
- 日志函数。

新增：

- `Tool` / `Tool_Context` / `Tool_Result` / `Registry` / `Progress_Kind` 的类型别名与注册辅助函数。

移除：

- `all_tool_names` / `select_tools` / `tool_name_known`；
- `list_tools_text` / `list_skills_text`（属于应用层）。

这是一次明确的 SDK API 破坏性变更；仓库内唯一宿主是 `ap-cli`，迁移成本可控。对外部宿主，在发布说明中标注。

## 8. 代码改动清单

### 8.1 新增 `ap-core/tool/`

- `tool.odin`：`Tool` / `Tool_Def` / `Tool_Result` / `Tool_Context` / `Progress_Kind`；
- `args.odin`：`tool_arg_string` / `tool_arg_optional_string` / `tool_arg_optional_int` / `tool_arg_optional_bool`；错误类型用 `platform.Error`，避免 tool 包依赖 engine；
- `registry.odin`：`Registry`、`registry_init`、`registry_find`、`registry_select`、`registry_definitions`、`registry_prompt_section`；
- `execute.odin`：`tool_execute(registry, name, args, ctx)`；
- `blob.odin`：从 `engine/context.odin` 迁入 `content_block_text`（读取 `text_ref`），供 `task` 与 context 投影共用；错误类型映射为 `platform.Error`；
- `tool_test.odin`：契约与注册表测试。

### 8.2 `ap-core/engine/`

- `tools.odin`：删除（参数 helper 与 `tool_execute` 迁到 `ap-core/tool`）。
- `tools_registry.odin`：删除（`Tool_Def` / `tool_definitions` / `tool_prompt_section` 迁到 `ap-core/tool`）。
- `tool_file.odin` / `tool_bash.odin` / `tool_task.odin`：删除（迁到 `ap-cli/tools`）。
- `process.odin`：删除（迁到 `ap-cli/tools/process.odin`；只被 `bash` / `task` 使用）。
- `skills.odin`：删除（迁到 `ap-cli/skills`）。
- `config.odin`：删除 `ALL_TOOL_NAMES` / `tool_name_valid` / `select_tools` / agent 解析；`Settings` 收窄。
- `context.odin`：`build_system_prompt` 只处理 base + 工具段 + sections；删除环境、技能、记忆、agent 正文、追加指令的拼接。
- `session.odin`：删除 `load_agent` / `discover_skills` / `build_system_prompt` 的产品参数；改为接收已解析的 `Session_Request`；冻结 prompt 与 tools；恢复 warning。
- `loop.odin`：`Loop` 增加 `registry` 与 `active_tools`；`Tool_Context` 组装去掉应用字段；`loop_init` 签名收窄。
- `transcript.odin`：不变；继续提供冻结 prompt 读取。

### 8.3 `ap-core/sdk.odin`

- `Config` / `Env` / `Session_Options` 按第 5 节调整；
- 增加工具类型别名；
- 删除工具名与 skill 文本查询；
- `session_request` 映射新字段。

### 8.4 `ap-cli/`

- `tools/`：迁入五个工具与测试；新增 `Tool_Config`；迁入 `engine/process.odin` 作为 `tools/process.odin`（`run_child` / `Run_Options` / 进程树清理）；`task` 使用 protocol 直接解析子进程事件。
- `skills/`：迁入技能发现/解析/提示词块与测试。
- `agent.odin`：迁入 agent 解析与测试。
- `prompt.odin`：组装环境段、技能段、记忆段、agent 正文、用户追加；提供单一 `build_prompt_sections`。
- `settings.odin`：读取 `settings.json`，拆成 `apcore.Settings` 与 `aptools.Tool_Config`。
- `run.odin`：按 6.1 顺序组装注册表与 section；`--print-system-prompt` 与 `session_open` 共用 `build_prompt_sections`；`--list-tools` 从注册表输出。
- `app.odin`：help 文本不变；如 SDK 改动导致说明需要调整，只改措辞。
- `options.odin`：参数解析不变。

### 8.5 依赖检查

`tools/check-deps.*` 更新允许边：

| 源 | 允许 | 禁止 |
| --- | --- | --- |
| `ap-cli` | `apcore`、`ap-core/tool`、`ap-core/platform`、`ap-core/protocol`、`ap-cli/tools`、`ap-cli/skills` | `ap-core/engine`、`ap-core/client`、前端 |
| `ap-cli/tools` | `ap-core/tool`、`ap-core/platform`、`ap-core/protocol` | `apcore`、`ap-core/engine`、`ap-cli/skills` |
| `ap-cli/skills` | `ap-core/platform` | `apcore`、`ap-core/engine`、`ap-cli/tools` |
| `apcore` | `engine`、`ap-core/tool`、`platform`、`protocol` | `ap-cli`、前端 |
| `engine` | `ap-core/tool`、`platform`、`protocol` | `apcore`、`ap-cli`、`ap-cli/tools`、`ap-cli/skills` |
| `ap-core/tool` | `platform`、`protocol`、`core:` | 所有其它本地包 |

自测用例增加：`engine` 反向 import `ap-cli/tools` 必须被拒绝。

## 9. 实施顺序

每一步都应保持可编译、可测试；不要把所有改动堆在一个提交里。

1. **工具契约**：新增 `ap-core/tool`，把 `Tool_Result` / `Tool_Context` / `Progress_Kind` / 注册表移过去；engine 暂时保留旧工具实现，但通过注册表调用。
2. **工具迁移**：把五个工具与测试迁到 `ap-cli/tools`；`apcli` 注册内置工具；删除 engine 的具体工具文件；`Tool_Context` 去掉应用字段。
3. **prompt append**：新增 `prompt_sections`，`build_system_prompt` 只保留 base + 工具段；把环境、技能、记忆、agent 正文、用户追加移到 `ap-cli/prompt.odin`；删除 `no_skills` / `no_agents_md` / `append_system_prompt`。
4. **agent 迁移**：把 agent 定义解析移到 `ap-cli/agent.odin`；`Session_Options` 接收已解析的 `agent_name` / `model` / `max_steps` / `tools`；恢复不再读 agent 文件。
5. **Settings 拆分**：收窄 `apcore.Settings`；`ap-cli/settings.odin` 产出工具配置；`max_agent_depth` / `tool_timeout_ms` / `max_capture_bytes` 从 SDK 移除。
6. **清理与边界**：删除 `apcore` 的工具名/skill 查询；更新 check-deps；删除 engine 中的死代码。
7. **文档与回归**：更新第 10 节列出的文档；跑全量测试、e2e、默认 prompt 逐字节对比。

第 1、2 步可独立发布；第 3、4 步共享 prompt 组装，建议同一次评审通过后连续实施；第 5 步可以单独提交。

## 10. 文档改动清单

| 文件 | 改动 |
| --- | --- |
| `docs/architecture.md` | 模块清单、依赖图、包布局、SDK 门面按新边界重写；明确 `ap-cli` 是组装根 |
| `docs/dependencies.md` | 包布局与允许边新增 `ap-core/tool`、`ap-cli/tools`、`ap-cli/skills`；check-deps 自测补充 |
| `docs/context-management.md` | system prompt 改为 base + 工具段 + 应用层 sections；列出默认 section 顺序与冻结规则 |
| `docs/skills.md` | 明确 skill 属于应用层；SDK 不参与发现与注入；`--list-skills` 不变 |
| `docs/tools.md` | 工具契约、注册表、执行管线归 SDK；五个工具实现归 `ap-cli/tools`；`task` 归应用层 |
| `docs/subagents.md` | `task` 的子进程参数由应用层组装；SDK 不感知 stream-json |
| `docs/cli-and-config.md` | settings 字段归属；启动顺序；`--print-system-prompt` 的组装位置 |
| `docs/react-loop-and-session.md` | `session_start` 不变；恢复规则补充“未知冻结工具跳过 + warning” |
| `docs/integration.md` | SDK API 变更；`Config` / `Session_Options` 示例 |
| `README.md` | 源码结构更新；说明 SDK 的职责边界 |
| `docs/proposals/sdk-scope.md` | 本文件 |

## 11. 测试计划

### 11.1 工具契约与注册表（`ap-core/tool`）

- 重复工具名 / 空名注册失败；
- `registry_select` 按注册表顺序过滤，`tools` 的输入顺序不影响结果；
- 未知工具名在 New 时返回 `.Usage`，在恢复时跳过并 warning；
- `Tool_Result` 的 `fatal` / `duration_ms` / `exit_code` / `metadata` 透传；
- 注册表为空时 `registry_definitions` 为空，`registry_prompt_section` 输出“本次没有可用工具”。

### 11.2 prompt 组装（`engine/context_test.odin` + `ap-cli` 测试）

- base + 工具段 + sections 的拼接顺序、空 section 跳过、结尾恰好一个换行；
- section 内部空行与缩进原样保留；
- `base_system_prompt` 覆盖只替换 base，工具段仍存在；
- 默认 section 顺序与当前默认 prompt 逐字节一致（测试注入固定时间或忽略时间行）；
- `preview_prompt` 与 `session_open` 的 `session_start.content` 逐字节一致；
- 超过 `blob_threshold_bytes` 时写 `content_ref`，恢复能还原完整 prompt。

### 11.3 冻结与恢复（`engine/session_test.odin`）

- 新 session 的 `session_start.tools` 等于生效工具集；
- 恢复时修改 agent 文件 / 注册表新增工具，不改变冻结 prompt 与工具集；
- 恢复时传 `base_system_prompt` / `prompt_sections` / `tools` 产生对应 warning；
- fork 复制冻结 prompt 与工具集；
- 冻结工具在当前注册表中不存在时跳过并 warning，不终止；
- 旧 transcript 无 `tools` 字段时按注册表全部工具处理并 warning。

### 11.4 工具迁移（`ap-cli/tools`）

- 迁移现有 `tools_test.odin` 的全部用例；
- `Tool_Context` 不再提供 `self_exe` / `bash_path` / `settings` 后，五个工具行为不变；
- `task` 的子进程参数、stderr 转发、取消、结果元数据不变；
- `bash` 的 `.txt` 分页、进程树清理、输出上限不变；
- 文件工具编码、CRLF、`replace_all`、分页限制不变。

### 11.5 应用层（`ap-cli`）

- `settings.json` 拆分后，SDK 字段与工具字段映射正确；
- `--list-tools` / `--list-skills` / `--print-system-prompt` 不读 API key、不创建 session；
- `--tools all/none`、agent 白名单、深度移除规则不变；
- 环境段、记忆段、技能段、agent 正文、用户追加的顺序与开关正确；
- `--no-agents-md` / `--no-skills` / `--base-system-prompt` 行为不变。

### 11.6 端到端

- `ap --print-system-prompt` 与模型实际收到的 system prompt 一致；
- 五个工具各跑一轮；
- `task` 子代理完整跑一轮，父进程正确读取 `child_session_id` 与结果；
- `-s` / `-c` / fork 恢复正常；
- `--tools none` 时 provider 请求不含 `tools`；
- `ap-tui` / `ap-web` 各跑一轮，进程契约不变。

### 11.7 依赖检查

- `tools/check-deps.sh --self-test` / `check-deps.ps1 -SelfTest` 通过；
- `cmd/ap-web` / `cmd/ap-tui` 的编译文件清单中没有 `ap-core/engine/`；
- `ap-cli` 的编译文件清单中没有 `ap-core/engine/`。

## 12. 风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 默认 prompt 漂移 | 模型行为变化 | 固定时间注入 + 默认 prompt 逐字节 golden test；工具段格式不改 |
| 工具迁移引入行为回归 | 文件/命令/子代理行为变化 | 代码尽量原样搬移；现有工具测试全部跟随迁移；e2e 覆盖 |
| SDK API 破坏 | 外部宿主编译失败 | 仓库内只有 `ap-cli`；发布说明标注；必要时保留一版类型别名 |
| 包循环 | `tool` 依赖 engine 导致编译环 | `ap-core/tool` 只依赖 `platform`；`Progress_Kind` 放 tool 包 |
| 注册表生命周期 | 悬空切片或 `Tool.user` | 文档规定应用层持有；`env_open` 校验并复制切片；session 期间不可变 |
| 恢复时工具被移除 | prompt 提到不存在的工具 | 跳过 + warning；不自动改写冻结 prompt；文档写清限制 |
| `--print-system-prompt` 与真实 prompt 不一致 | 用户误判 | `preview_prompt` 与 `session_open` 共用同一组装函数；测试断言逐字节一致 |
| 应用层变胖 | CLI 难维护 | 工具/skill/agent/prompt 都拆到子包；`apcli` 只做组装 |
| `settings.json` 兼容 | 用户配置失效 | 文件格式与字段名不变；只改内部归属；补映射测试 |
| 子代理参数漂移 | 子代理行为变化 | `task_child_args` 保持纯函数并保留现有测试 |

## 13. 非目标（本方案）

- 不把 provider 移出 SDK；仍保留默认 OpenAI 兼容实现与 `Stream_Fn` 注入点。
- 不移动 `platform` / `protocol` / `client`。
- 不改变 transcript schema、事件类型或 blob 规则。
- 不改变五个工具的参数、输出格式与语义。
- 不新增插件、MCP、运行时动态加载工具。
- 不做并行工具调用。
- 不改变 `ap-tui` / `ap-web` 的进程契约。
- 不新增 CLI 参数；`--tools` / `--list-tools` 等行为保持不变。
- 不引入权限、审批或沙箱。
- 不做上下文压缩。

## 14. 验收标准

1. `ap-core/engine` 不再包含具体工具实现、skill 发现、`AGENTS.md` 读取、agent 文件解析与子进程启动。
2. `ap-cli/tools` 提供五个内置工具；`task` 不再出现在 SDK 中。
3. SDK 的 system prompt 只由 base、工具段与 `prompt_sections` 组成；应用层决定其余顺序与内容。
4. 默认参数下，迁移后的 system prompt 与迁移前逐字节一致（动态时间除外）。
5. `prompt_sections` 只在 New 生效；恢复 / fork 使用冻结 prompt；`preview_prompt` 与 `session_open` 一致。
6. `session_start.tools` 继续冻结生效工具集；恢复时未知工具跳过并 warning。
7. `--list-skills` / `--list-tools` / `--print-system-prompt` 行为不变，且不需要 API key。
8. 五个工具与 `task` 子代理的现有测试、e2e 全部通过。
9. `ap-cli` 仍不直接 import `ap-core/engine`；`ap-tui` / `ap-web` 的编译文件清单仍不含 agent 代码。
10. `docs/*.md`、`README.md` 与 `tools/check-deps.*` 同步更新。
