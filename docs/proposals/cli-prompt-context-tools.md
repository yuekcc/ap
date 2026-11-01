# 变更方案：system prompt / AGENTS.md / skills / tools 的命令行控制

状态：**草案，待整体评审**。评审通过后再落到 `docs/*.md` 与代码；本文件不属于定稿规格。

## 1. 摘要

新增四个运行级开关，用于裁剪新 session 的上下文与工具集；另加一个查看入口：

- `--base-system-prompt <text>` / `--base-system-prompt-file <path>`：替换**内置固定指令段**，保留工具、环境、技能、记忆、agent 定义与追加指令
- `--no-agents-md`：不注入全局与项目 `AGENTS.md`
- `--no-skills`：不扫描、不注入技能清单
- `--tools <list>`：覆盖工具白名单
- `--list-tools`：查看本次声明生效的工具集后退出（与 `--list-skills` 对称）

另外统一用户输入提示词片段的空白处理：CRLF→LF、去首尾空白、确保一个结尾换行，内部空白不动。

同时：

- 删除 `--workspace`（`--config-dir` 的误导性别名）
- 把生效工具集冻结进 `session_start`
- 修复 `--print-system-prompt` 不打印 warning 的问题
- 旧的 `--print` / `--print0` / `--print-system-prompt` 名称保持不变

不新增 `--append-system-prompt-file`：长文本追加用 `AGENTS.md`，或由 shell 展开到 `--append-system-prompt`。

## 2. 已接受的设计决策

| 决策 | 结论 |
| --- | --- |
| `--base-system-prompt` 语义 | 替换内置固定指令段，保留其余自动拼接内容 |
| `--base-system-prompt` 与 append | 可以同时使用；base 在前，append 在最后 |
| 提示词空白处理 | CRLF→LF、去首尾空白、保证一个结尾换行；内部空白保留 |
| `--tools` 是否传给子代理 | 传，作为整棵进程树的有效工具集 |
| 是否重命名旧 `--print*` | 不重命名；只删 `--workspace` |
| 是否冻结工具集 | 是，写入 `session_start.tools` |
| 是否新增 append 文件变体 | 否 |
| 是否新增 `--list-tools` | 是，作为 `--tools` 的检查入口 |

## 3. CLI 表面

### 3.1 新增参数

| 参数 | 值 | 说明 |
| --- | --- | --- |
| `--base-system-prompt <text>` | 文本 | 替换内置固定指令段；不能为空 |
| `--base-system-prompt-file <path>` | 文件路径 | 从 UTF-8 文件读取并替换内置固定指令段；不能为空文件 |
| `--no-agents-md` | — | 不注入 `$AP_CONFIG/AGENTS.md` 与项目 `AGENTS.md` |
| `--no-skills` | — | 不扫描技能、不注入技能清单 |
| `--tools <list>` | 逗号分隔列表 | 覆盖 agent 定义中的工具白名单；支持 `all` / `none` |
| `--list-tools` | — | 列出本次声明生效的工具后退出；不创建 session、不调用模型 |

### 3.2 删除与保留

- 删除 `--workspace`。它只是 `--config-dir` 的别名，容易被误认为项目根目录。
- 保留 `--append-system-prompt`、`--print`、`--print0`、`--print-system-prompt`。
- 不新增 `--append-system-prompt-file`。
- 新增 `--list-tools`，与 `--list-skills` 对称。

### 3.3 语法与校验

所有带值参数继续支持 `--name=value`。

`--base-system-prompt` / `--base-system-prompt-file`：

1. 两者互斥；同时出现 → 退出码 2
2. 可以与 `--append-system-prompt` 同时使用：base 替换内置指令段，append 仍排在最后
3. `--base-system-prompt` 空字符串 → 退出码 2
4. `--base-system-prompt-file` 路径解析规则与 `--input-file` 一致：相对启动目录，支持 `~/...`
5. 文件必须存在、可读、非空、合法 UTF-8；否则退出码 2
6. 文本统一规范化：
   - CRLF / 单独 CR → LF
   - 去掉首尾空白
   - 结尾保证恰好一个 `\n`
   - trim 后为空 → 退出码 2
7. **内部空白保留**：不合并连续空行、不调整缩进，避免破坏 Markdown 列表、代码块与示例
8. 它们不是“用户提示词来源”，不受 `--print` / `--input-file` / `--print0` 互斥规则约束，可以同时使用

`--append-system-prompt`：

- 可以与 `--base-system-prompt` / `--base-system-prompt-file` 同时使用
- 同样做 CRLF→LF 与首尾 trim；不自行补结尾换行，由拼接器统一补
- trim 后为空时视为未提供，不报错（保持现有语义）

`--tools`：

1. 按 `,` 分割，逐项 trim 前后空白
2. 忽略空项（`read_file, , bash` 等价于 `read_file,bash`）
3. 重复项去重，顺序不影响结果（实际顺序按 `ALL_TOOL_NAMES`）
4. `all`：展开为五个工具
5. `none`：零个工具
6. `all` / `none` 必须是唯一 token，不能与其它工具名混写
7. 未知工具名 → 退出码 2
8. 空值（`--tools=` 或 `--tools ""`）→ 退出码 2；要零工具请用 `--tools none`

`--no-agents-md` / `--no-skills`：

- 布尔开关，不接受内联值；`--no-skills=1` → 退出码 2
- 可以重复出现，幂等

`--list-tools`：

- 布尔开关，不接受内联值
- 与 `--list-skills` 互斥；同时出现 → 退出码 2
- 与 `--print-system-prompt` 同时出现时，`--list-tools` 优先（两者都是检查命令，不运行模型）
- 不读 `settings.json`、不需要 API key、不需要提示词
- 受 `--config-dir` / `AP_CONFIG`、`--agent`、`--tools` 影响
- 命令优先级：`--help` / `--version` > `--list-skills` / `--list-tools` > `--print-system-prompt` > 正常运行

### 3.4 帮助文本

新增分组，避免现有 help 继续变长：

```text
提示词与上下文:
  -p, --print <提示词>            直接指定提示词
      --input-file <path>         从文件读取提示词
      --print0                    从 stdin 读取提示词直到 EOF
      --base-system-prompt <text>
                                  替换内置固定指令段（保留自动拼接内容）
      --base-system-prompt-file <path>
                                  从文件替换内置固定指令段
      --append-system-prompt <text>
                                  追加到 system prompt 末尾
      --no-agents-md              不注入 AGENTS.md
      --no-skills                 不注入技能清单
      --print-system-prompt       打印本次使用的 system prompt 后退出

工具:
      --tools <list>              覆盖工具白名单：read_file,bash / all / none
      --list-tools                列出本次声明生效的工具后退出
      --list-skills               列出当前目录可见的技能后退出
```

## 4. 行为规格

### 4.1 新 session 的 system prompt 组装

组装顺序固定，只有第 1 段可被替换：

```text
1. 基础提示词段        ← 内置固定指令，或 --base-system-prompt / --base-system-prompt-file
2. 工具说明            ← 按生效工具集生成
3. 环境信息            ← OS / cwd / 时间 / 是否 git 仓库
4. 可用技能清单        ← --no-skills 跳过
5. 全局记忆 AGENTS.md  ← --no-agents-md 跳过
6. 项目记忆 AGENTS.md  ← --no-agents-md 跳过
7. agent 定义正文
8. 追加指令            ← --append-system-prompt
```

给了 `--base-system-prompt` 或 `--base-system-prompt-file` 时：

- **只替换第 1 段**，其余七段照常拼接
- 文本按 3.3 规范化：CRLF→LF、去首尾空白、结尾恰好一个 `\n`；内部空行与缩进保留
- `--no-agents-md` / `--no-skills` 仍然生效，不是 no-op
- `--tools` 仍然生效，第 2 段的工具说明按覆盖后的工具集生成
- `--append-system-prompt` 仍然生效，位于最后
- 仍然加载 `settings.json` 和 agent 定义；agent 文件非法仍退出 2
- 没有“完全裸 prompt”模式：环境、工具说明等无法用单个开关一次性清空（见第 11 节）

`--print-system-prompt`：

- 新 session：打印**完整组装结果**，不是只打印 base 文本
- 恢复 / fork：打印冻结的 prompt
- 输出仍为纯文本，末尾保证换行
- **新增：将 `resolve_session` 产生的 warning 打到 stderr**（当前被忽略）

### 4.2 `--no-agents-md`

关闭两个来源：

1. `$AP_CONFIG/AGENTS.md`
2. 从 cwd 向上发现的项目 `AGENTS.md`

关闭后：

- 不做向上目录遍历
- 不读取任何 `AGENTS.md`
- prompt 中完全不出现「全局记忆」「项目记忆」小节

不改变：

- `AGENTS.md` 文件本身
- 其它文件读取工具的行为
- 子代理的独立性（见 4.8）

### 4.3 `--no-skills`

只关闭“把技能清单注入 system prompt”：

- 不扫描 `~/.agents/skills` 与 `<cwd>/.agents/skills`
- prompt 中不出现 `<available_skills>` 清单
- `--list-skills` 不受影响，仍正常列出
- 不是安全边界：模型仍可用 `bash` / `read_file` 自行读取 `SKILL.md`

### 4.4 `--tools`

优先级：

```text
CLI --tools  >  agent 定义中的 tools:  >  全部五个工具（默认）
```

实现上在加载 agent 后、组装 prompt 前替换 `Agent_Def.tools`。

规则：

- `--tools none`：工具集为空。provider 请求不发送 `tools` 字段；prompt 工具节写「（本次没有可用工具）」
- `--tools all`：五个全开，可用于覆盖窄 agent
- `task` 是否可用仍由 `max_agent_depth` 决定；即使白名单包含 `task`，`agent_depth >= max_agent_depth` 时也会被移除
- 非法工具名在启动时失败，退出码 2
- `--tools` 不是权限系统：它只限制注册给模型的工具；`bash` 仍然拥有完整进程权限（与 v1 非目标一致）

### 4.5 `--list-tools`

用途：在执行前确认 `--agent` 与 `--tools` 组合后的工具集，避免靠猜。

```sh
ap --list-tools
ap --list-tools --agent scout
ap --list-tools --agent scout --tools all
ap --list-tools --tools none
```

输出格式与 `--list-skills` 对齐，一行一个：

```text
1. read_file: 按行读取 UTF-8 文本文件；单次最多 2000 行，大文件用 start_line/end_line 分页读取，返回首行为元信息。
2. bash: 使用 bash -c <command> 执行 Bash/POSIX 命令；每次独立进程，不保留 cwd/环境变量，stdin 为 NUL。...
```

规则：

- 只列 **声明的工具白名单**：agent 定义 + `--tools` 覆盖后的结果
- 不加载 `settings.json`、不需要 API key、不创建 session、不写 transcript、不调用模型
- 受 `--config-dir` / `AP_CONFIG`（agent 定义位置）和 `--agent` 影响
- 空工具集输出 `No tool found`
- `task` 的“声明存在”与实际可用性不同：实际运行时仍会按 `max_agent_depth` 移除；`--list-tools` 无法预知这一点，文档必须写清
- 与 `--list-skills` 互斥，避免两个检查命令的输出语义混乱
- 与 `--print-system-prompt` 同时出现时以 `--list-tools` 为准

### 4.6 组合矩阵

| 组合 | 结果 |
| --- | --- |
| `--base-system-prompt` + `--no-agents-md` | 自定义基础提示词；不注入任何 `AGENTS.md` |
| `--base-system-prompt` + `--no-skills` | 自定义基础提示词；不注入技能清单 |
| `--base-system-prompt` + `--append-system-prompt` | 自定义基础提示词；追加内容仍排在最后 |
| `--base-system-prompt` + `--tools` | 自定义基础提示词；第 2 段工具说明按 `--tools` 覆盖后的集合生成 |
| `--no-agents-md` + `--no-skills` | 两者都跳过，其余自动小节保留 |
| `--tools none` + `--agent scout` | scout 的工具集被清空 |
| `--tools read_file` + agent 含 `task` | 只保留 `read_file`，不启动子代理 |

### 4.7 恢复与 fork

沿用现有原则：system prompt 与工具集在 `session_start` 冻结。

以下参数在恢复 / fork 时一律 **warning + 忽略**，退出码不变：

- `--base-system-prompt`
- `--base-system-prompt-file`
- `--append-system-prompt`（现有行为）
- `--no-agents-md`
- `--no-skills`
- `--tools`

建议 warning 文案（保持现有英文风格）：

```text
--base-system-prompt ignored on restore: session is frozen to its recorded prompt
--no-agents-md ignored on restore: session prompt is frozen
--no-skills ignored on restore: session prompt is frozen
--tools ignored on restore: session is frozen to its recorded tool set
```

行为变化：

- 以前恢复时会重新加载 agent 定义，改 `agents/<name>.md` 的 `tools:` 会影响恢复后的工具集
- 以后以 `session_start.tools` 为准；改 agent 文件不再改变已有 session 的工具集
- 旧 transcript 没有 `tools` 字段时，回退到当前 agent 定义的 `tools:`，保持兼容

### 4.8 子代理传播

`task` 启动子进程时，按父进程状态追加：

```text
--tools <a,b,c>      仅当父进程显式给了 --tools
--no-agents-md       仅当父进程给了 --no-agents-md
--no-skills          仅当父进程给了 --no-skills
```

不传播：

- `--base-system-prompt` / `--base-system-prompt-file`：子代理有独立 agent 定义
- `--append-system-prompt`：只属于父进程的本次运行

语义：

- `--tools` 是整棵进程树的有效工具集；子代理自己的 agent 定义工具被覆盖，避免用 `task` 绕过限制
- `--no-agents-md` / `--no-skills` 是上下文隐私/裁剪开关，子代理同样遵守
- 深度规则不变：子进程的 `task` 仍按自己的 `agent_depth` 与 `max_agent_depth` 移除

为了让这段可测试，建议把子进程参数组装提取为纯函数：

```odin
task_child_args(ctx: ^Tool_Context, agent_name: string, prompt_max_steps: int) -> []string
```

## 5. 协议与数据模型

### 5.1 `Session_Request`

```odin
Session_Request :: struct {
	// ...现有字段...
	base_system_prompt: Maybe(string), // 替换内置固定指令段；已规范化；文件已在 run.odin 读取为文本
	no_agents_md:       bool,
	no_skills:          bool,
	tools_set:          bool,          // 显式 --tools 时为 true
	tools:              []string,      // tools_set 时有效；--tools none 为空切片
}
```

说明：

- 文件读取放在 CLI/run 层，engine 只接收最终文本，保持 engine 不依赖“参数来源”
- 不使用 `Maybe([]string)`，避免和 `req.model == nil` 这类比较写法产生类型问题；用 `tools_set` 表达“是否显式设置”

### 5.2 `session_start.tools`

`Session_Start_Event` 增加：

```odin
tools: Maybe([]string) `json:"tools"`
```

- 新 session：写入生效后的 **声明工具列表**（CLI `--tools` 已应用；`task` 的深度移除是运行期行为，不参与冻结）
- 恢复 / fork：新追加的 `session_start` 沿用上一次的值
- `--tools none`：写空数组 `[]`，不能省略
- 旧 transcript：字段缺失或 `null` 视为“未冻结”，回退到 agent 定义
- 不使用 `omitempty`，否则空数组会被省略，无法区分 `none` 与“旧格式”

`append_session_start` 需要透传 `start.tools`；`session_system_prompt` 返回的 `Session_Start_Event` 已带该字段，无需改签名。

### 5.3 读取兼容

- 老二进制读取新 transcript：未知字段 `tools` 被标准 JSON 解码忽略（Odin struct 解码不需要 DisallowUnknown）
- 新二进制读取老 transcript：`tools` 为 nil，按第 4.7 节回退
- 前端（ap-tui / ap-web）只透传事件，不需要改

## 6. 代码改动清单

### 6.1 `ap-core/cli.odin`

- `Options` 增加：`base_system_prompt`、`base_system_prompt_file`、`no_agents_md`、`no_skills`、`tools_set`、`tools`
- `parse_args` 增加六个 case
- 删除 `--workspace` case
- 新增 `parse_tool_list(value string) -> ([]string, Error)`
- 新增互斥校验：`--base-system-prompt` 与 `--base-system-prompt-file`（append 不再互斥）
- 新增空值校验
- 新增 `normalize_prompt_block(text: string, ensure_trailing_newline: bool) -> (string, Error)`：CRLF/CR→LF、trim、可选补一个结尾换行、空内容报错
- 新增 `read_base_system_prompt(opts, cwd) -> (Maybe(string), Error)`：校验 UTF-8、路径解析，并调用 `normalize_prompt_block(..., true)`
- `--append-system-prompt` 在传入 `Session_Request` 前调用 `normalize_prompt_block(..., false)`；结果为空时视为未设置

### 6.2 `ap-core/app.odin`

- help 文本新增「提示词与上下文」「工具」分组
- 删除 `--workspace` 行

### 6.3 `ap-core/run.odin`

- 在 `--list-skills` 分支之后增加 `--list-tools` 分支；它在 `load_settings`、`find_bash` 之前处理
- 新增 `list_tools(opts: Options) -> int`：
  - 解析 `--config-dir`（不要求可写）
  - `load_agent(config_dir, agent_name)`
  - `opts.tools_set` 时调用 `apply_tool_override`
  - 打印 `tools_brief(agent.tools)` 后返回 0
- 在构造 `Session_Request` 前调用 `read_base_system_prompt`
- 传入 `base_system_prompt`、`no_agents_md`、`no_skills`、`tools_set`、`tools`
- `--print-system-prompt` 分支打印 `info.warnings` 到 stderr

### 6.4 `ap-core/engine/session.odin`

- `Session_Request` 增加 5.1 字段
- `resolve_session` 新 session 分支，按此顺序：
  1. `load_agent`
  2. `tools_set` 时调用 `apply_tool_override`
  3. `skill_section = "" if no_skills else skills_prompt_block(discover_skills(cwd))`
  4. `build_system_prompt` 传 `base_override = base_system_prompt`（未给时为空）、`include_memory = !no_agents_md`，并传入生效工具集生成的 `tool_section`
  5. 结果写入 `resolved.system_prompt`
- `resolve_session` 恢复 / fork 分支：
  - 对六个参数分别追加 warning（有值 / true 时）
  - 用 `start.tools` 覆盖 reloaded agent 的 `tools`；旧 transcript 无字段时跳过
- `session_open` 新 session：`start.tools = resolved.agent.tools`（包装成 Maybe）
- `append_session_start`：复制 `start.tools`

### 6.5 `ap-core/engine/context.odin`

- `System_Prompt_Options` 增加：
  - `base_override: string`（替换第 1 段；空字符串表示用内置 `SYSTEM_PROMPT`）
  - `include_memory: bool`
- `build_system_prompt`：
  - 第 1 段写 `base_override`（非空）或 `SYSTEM_PROMPT`（默认），**不再提前 return**
  - `include_memory == false` 时跳过全局/项目记忆读取
- 技能清单仍由调用方决定是否传入，保持函数纯粹

### 6.6 `ap-core/engine/config.odin`

- 新增 `tool_name_known(name string) -> bool`
- 新增 `apply_tool_override(agent: ^Agent_Def, names: []string) -> Error`
  - 校验、去重、写回 `agent.tools`
  - `tools_explicit = true`
- `ALL_TOOL_NAMES` 保持现有顺序，作为 `--tools all` 的展开来源

### 6.7 `ap-core/engine/loop.odin` / `tools.odin` / `tool_task.odin`

- `Loop` 增加 `tools_set`、`tools_override`
- `loop_init` 增加对应参数
- `Tool_Context` 增加 `tools_set`、`tools_override`、`no_agents_md`、`no_skills`
- `tool_task` 用 4.8 的 `task_child_args` 组装参数

### 6.8 `ap-core/protocol/events.odin`

- `Session_Start_Event` 增加 `tools: Maybe([]string) \`json:"tools"\``

### 6.9 `ap-core/engine/tools_registry.odin`

- 新增 `tools_brief(names []string) -> string`
  - 按 `ALL_TOOL_NAMES` 顺序输出 `1. <name>: <description>`，一行一个
  - 空列表返回 `No tool found\n`
- `tool_definitions` / `available_tool_names` 不变

### 6.10 不改的部分

- `provider.odin`：工具仍通过 `tools` 字段发送，空集自然省略
- `ap-tui` / `ap-web`：不新增界面开关；它们拉起的 ap 子进程仍使用默认上下文

## 7. 文档改动清单

| 文件 | 改动 |
| --- | --- |
| `docs/cli-and-config.md` | 参数表新增六行、删除 `--workspace`、新增 prompt 覆盖语义、`--list-tools` 查看规则、恢复 warning 列表、退出码说明 |
| `docs/tools.md` | 新增“查看生效工具”小节：输出格式、不读 settings、`task` 与深度的差异 |
| `docs/context-management.md` | 组装顺序图标注 `--no-skills` / `--no-agents-md`；新增 base 覆盖规则；tools 冻结 |
| `docs/react-loop-and-session.md` | `session_start` 示例与字段表新增 `tools`；恢复规则补充“工具集以记录为准” |
| `docs/subagents.md` | 工具集继承规则；启动协议新增条件参数；agent 定义 `tools` 与 CLI 的优先级 |
| `docs/skills.md` | `--no-skills` 的作用与不影响 `--list-skills` |
| `docs/integration.md` | `session_start.tools`；恢复期忽略参数列表补齐 |
| `docs/README.md` | 已定决策表增加“上下文注入可裁剪；默认全量” |
| `README.md` | 功能列表、用法示例（覆盖 prompt / 关闭记忆 / 限定工具） |
| `docs/tui.md`、`docs/web.md` | 无需改动；可在“限制”中注明暂不暴露这些开关 |

## 8. 测试计划

### 8.1 CLI（`ap-core/cli_test.odin`）

- 六个新参数的默认值与解析（含 `--name=value`）
- `--base-system-prompt` 与 `--base-system-prompt-file` 互斥
- base 与 `--append-system-prompt` 可以共存
- 空白规范化：CRLF / CR → LF；首尾空白被去掉；结尾恰好一个换行；内部空行与缩进不变
- 只有空白的 `--base-system-prompt` / 空文件 → 退出码 2
- 空字符串 / 空文件 / 非 UTF-8 文件 → 退出码 2
- `--tools` 展开：`all`、`none`、去重、空白 trim、空项忽略
- `--tools all,read_file` 与 `--tools=` → 退出码 2
- 未知工具名 → 退出码 2
- `--no-skills=1` / `--list-tools=1` → 退出码 2
- `--list-tools` 与 `--list-skills` 互斥 → 退出码 2
- `--list-tools` 与 `--print-system-prompt` 同时出现时，前者优先
- `--workspace` 现在是未知参数 → 退出码 2
- help 文本包含新参数

### 8.2 上下文组装（`ap-core/engine/context_test.odin`、`session_test.odin`）

- `base_override` 非空时只替换第 1 段，工具/环境/技能/记忆/agent/append 仍在
- `base_override` + `--no-agents-md`：自定义核心存在，两个记忆小节都不出现
- `base_override` + `--no-skills`：自定义核心存在，技能清单不出现
- `base_override` + append：追加小节仍位于最后
- `--no-agents-md`：创建全局与项目临时 `AGENTS.md`，断言两者都不出现
- `--no-skills`：创建临时 skill，断言清单不出现；`--list-skills` 仍能列出
- 默认行为回归：现有 prompt 组成测试全部通过

### 8.3 工具集（`config_test.odin`、`tools_test.odin`、`session_test.odin`）

- `apply_tool_override`：替换、去重、非法名报错
- `--tools none`：`tool_definitions` 为空，provider 请求不含 `tools`
- `--tools read_file` + agent 定义含 `bash`：最终只有 `read_file`
- `--tools all` 覆盖窄 agent
- `task` 深度规则不受影响
- `tools_brief`：有工具时按 `ALL_TOOL_NAMES` 顺序输出 `序号. name: description`；空列表输出 `No tool found`

### 8.4 查看工具（`cli_test.odin`、`tools_test.odin` 或新增）

- `--list-tools` 默认列出 `general` 的五个工具
- `--agent scout` 只列 scout 定义中的工具
- `--tools read_file` 覆盖后只列 `read_file`
- `--tools none` 输出 `No tool found`
- 不读 `settings.json`、不需要 API key 也能成功（用不存在的 `--config-dir` 只影响 agent 查找，不报 key 错误）
- 未知 agent → 退出码 2；非法 `--tools` → 退出码 2
- `--list-tools` 不创建 transcript

### 8.5 冻结与恢复（`session_test.odin`）

- 新 session 的 `session_start.tools` 等于生效工具集
- `--tools none` 写入 `[]`，不是省略
- 恢复时修改 agent 文件工具集，仍使用冻结值
- 恢复时传 `--tools` / `--no-skills` / `--no-agents-md` / `--base-system-prompt` 产生对应 warning
- fork 复制冻结工具集
- 旧 transcript（无 `tools` 字段）恢复时回退到 agent 定义
- `--print-system-prompt` 在恢复时打印冻结 prompt，不重算

### 8.6 子代理（`tools_test.odin` 或新增）

- `task_child_args` 在父进程有 `--tools` 时包含 `--tools`
- `--no-agents-md` / `--no-skills` 被传播
- `--base-system-prompt` / `--append-system-prompt` 不被传播
- 子进程收到 `--tools none` 时参数为字面量 `none`

### 8.7 端到端

- `ap --print-system-prompt --no-agents-md --no-skills` 输出不含记忆与技能
- `ap --base-system-prompt "  X  " --print-system-prompt` 输出以 `X\n` 开头，并继续包含 `## 工具`、`## 环境` 等自动小节；内置固定指令原文不再出现
- `ap --list-tools` / `ap --list-tools --tools none` 输出符合预期
- `ap --tools none --print "..." --output-format json` 在真实端点上 provider 不发送 tools
- 现有 e2e 脚本回归

## 9. 兼容性、风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 删除 `--workspace` | 旧脚本失效 | v1 阶段的可接受破坏；文档与 README 同步；报错信息提示用 `--config-dir` |
| 工具集冻结改变恢复行为 | 编辑 agent 文件不再影响旧 session | 文档明确；需要新工具时用 `--fork-session` 或新 session |
| `Maybe([]string)` 的 JSON 编解码 | 可能无法区分 `nil` 与空切片 | 实现前先写最小测试；失败则退化为 `tools: []string` + `tools_frozen: bool` 两个字段 |
| `--base-system-prompt` 与常见工具的 `--system-prompt` 不同 | 用户以为整体替换，实际保留自动小节 | 名字中的 base 已提示这是“基础段”；help 与文档仍写清“替换内置固定指令段”，并用 `--print-system-prompt` 验证完整结果 |
| `--base-system-prompt` 走命令行长度上限 | Windows 长提示词失败 | 提供 `--base-system-prompt-file` |
| 没有完全裸 prompt 模式 | 想彻底控制每一段时做不到 | 文档写明；先用 `--no-agents-md --no-skills` 裁剪，确需裸 prompt 时后续再加开关 |
| `--no-*` 被误当安全边界 | 用户以为禁用技能/记忆=隔离 | 文档写明：不是沙箱，`bash` 仍有完整权限 |
| `--tools` 与 agent 定义冲突 | 用户预期不一致 | 文档与 help 明确 CLI 优先；`--list-tools` 可验证 |
| `--list-tools` 与 `task` 深度规则不一致 | 列表里有 `task`，运行时可能不可用 | 文档明确它列的是“声明工具集”，深度移除是运行期行为；不要为列表读取 settings |
| 子代理传播扩大 CLI 影响面 | 子 agent 定义中的窄工具集被覆盖 | 这是有意设计；文档写清“整棵进程树” |

## 10. 实施顺序

1. 协议与冻结：`Session_Start_Event.tools`、`Session_Request.tools_set/tools`、`append_session_start`、恢复读取；先补 session 测试
2. 基础提示词覆盖：`read_base_system_prompt`、`normalize_prompt_block`、`build_system_prompt.base_override`、`--print-system-prompt` 打印 warning
3. 记忆与技能开关：`include_memory`、`no_skills`、默认行为回归测试
4. 工具覆盖与传播：`apply_tool_override`、`Loop` / `Tool_Context` / `task_child_args`
5. 查看工具：`tools_brief`、`run.odin` 的 `list_tools` 分支
6. CLI 表面：参数解析、help、删除 `--workspace`、CLI 测试
7. 文档与 README
8. 全量测试 + 真实端点 e2e

每一步都应保持可编译、可测试；不要把所有改动堆在一个提交里。

## 11. 非目标（本方案）

- 不新增 `--append-system-prompt-file`
- 不做“完全裸 prompt”模式；`--base-system-prompt` 只替换内置固定指令段
- 不新增 `settings.json` 字段（这些是运行级开关；持久偏好写 `AGENTS.md`）
- 不新增环境变量
- 不给 `ap-tui` / `ap-web` 增加对应 UI 或启动参数
- 不改变 `--print*` 的命名
- 不引入权限/沙箱语义；`--tools` 只是工具白名单
- 不改变 agent 定义 frontmatter 的格式

## 12. 验收标准

1. 新 session 下四种上下文/工具能力都能单独生效，`--list-tools` 能准确反映声明工具集，且组合行为与第 4.6 节一致
2. 恢复 / fork 时六个参数都只警告、不改变冻结值
3. 自定义基础提示词之后，工具/环境/技能/记忆/agent/append 仍按开关正确拼接
4. 提示词首尾空白被清理、CRLF 统一为 LF、结尾恰好一个换行，内部空行与缩进不变
5. `--print-system-prompt` 的结果与模型实际收到的 system prompt 逐字节一致
6. 子代理无法通过 `task` 获得父进程 `--tools` 之外的额外工具
7. 现有测试与新增测试全部通过，文档与 help 同步
