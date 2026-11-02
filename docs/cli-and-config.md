# CLI 与配置

## 形态

ap 本体只有一种形态：**一次性 CLI**。ap 读取一条提示词，跑完一个 turn（或达到终止条件），写 `session_end`，退出。ap 自身没有交互式 REPL、TUI 或 Esc 取消；交互界面由独立的 `ap-tui` / `ap-web` 通过 `--output-format stream-json` 调用 ap，见 [tui.md](tui.md) 与 [web.md](web.md)。

脚本化与子代理复用同一套入口，差异只体现在参数上：

- `--output-format json`：给脚本用的单个结果对象
- `--output-format stream-json`：给子代理/流式消费者用的事件流
- `--parent-session-id` / `--parent-tool-call-id` / `--agent-depth`：给子代理用的父子关联

不提供 `--headless`：所有运行都是非交互的，这个开关没有意义。

## 参数

| 参数 | 值 | 说明 |
| --- | --- | --- |
| `-s, --session <id>` | session_id | 恢复当前项目内的指定 session |
| `-c, --continue` | — | 恢复当前项目内最近一次根 session，无需 id |
| `--fork-session` | — | 与 `-s` / `-c` 连用：复制历史到新 session，不污染原记录 |
| `--agent <name>` | agent 名 | 指定 agent。`$AP_CONFIG/agents/<name>.md` 存在时使用该定义；否则只接受内置 `general` |
| `--input-file <path>` | 文件路径 | 从文件读取提示词（UTF-8） |
| `-p, --print <prompt>` | 提示词 | 直接指定提示词 |
| `--print0` | — | 从 fd 0（stdin）读取整条提示词，直到 EOF |
| `--config-dir <path>` | 目录 | 设置 `$AP_CONFIG`，默认 `~/.ap` |
| `--model <id>` | model_id | 覆盖配置文件中的 model；新 session 的优先级是 CLI > agent 定义 > `settings.json`；恢复 session 时只警告，不生效 |
| `--max-steps <n>` | 正整数 | 单个 turn 的最大 step 数；新 session 的优先级是 CLI > agent 定义 > `settings.json` |
| `--max-tokens <n>` | 正整数 | 单次响应的 `max_tokens`，默认取 `settings.json`；agent 定义不覆盖该字段 |
| `--output-format <fmt>` | `text` / `json` / `stream-json` | 输出格式，默认 `text` |
| `--parent-session-id <id>` | session_id | 标记当前进程是某个 session 的子代理；父 transcript 必须存在 |
| `--parent-tool-call-id <id>` | tool_call_id | 父进程中对应的 `task` 调用；必须与 `--parent-session-id` 同时使用 |
| `--agent-depth <n>` | 非负整数 | 当前 agent 深度；默认 0，子代理为父 + 1；恢复时以记录为准 |
| `--no-agents-md` | — | 不注入 `~/.agents/AGENTS.md` 与项目 `AGENTS.md`；只在新 session 生效，恢复时忽略 |
| `--no-skills` | — | 不扫描、不注入技能清单；不影响 `--list-skills`；只在新 session 生效，恢复时忽略 |
| `--verbose` / `--debug` | — | 日志级别，输出到 stderr |
| `--list-skills` | — | 列出当前目录可见的技能后退出；不读配置、不需要 API key |
| `--print-system-prompt` | — | 打印本次运行使用的 system prompt 后退出；不创建 session、不调用模型、不需要 API key |
| `--help` / `--version` | — | 用法与版本 |

不提供 `--add-dir`。所有相对路径只相对启动目录；绝对路径不受限制。

### 提示词来源

`--print`、`--input-file`、`--print0` **三选一**：正常运行必须且只能给一个，同时出现或都没给都退出码 2。不需要提示词的检查命令（`--help`、`--version`、`--list-skills`、`--print-system-prompt`）不受此限制。`-s` 与 `-c` 也互斥；`--fork-session` 必须与其中之一连用。

- `--print`：参数即提示词；空字符串视为用法错误。提示词必须是合法 UTF-8；Windows 上若系统 ANSI 代码页不是 UTF-8，ap 会先按宽字符命令行重建参数并转成 UTF-8，转换不了的参数会直接报用法错误，而不是把乱码写进 transcript
- `--input-file`：文件必须存在、可读、UTF-8；内容为空视为用法错误
- `--print0`：读 fd 0 直到 EOF；帮助文本里明确写「0 = stdin」，避免被误认为 NUL 分隔
- 三者都没给时：退出码 2，并提示可用的三个来源。ap **不再**根据 stdin 是否为 TTY 隐式读取；需要从 stdin 取提示词时必须显式传 `--print0`
- 内嵌/集成场景统一用 `--print0` + stdin：写完提示词后关闭写端，EOF 就是输入结束信号

一次运行只处理一条提示词，因此一次运行最多一个 user turn。

### system prompt 约定与上下文开关

`$AP_CONFIG/SYSTEM.md`：

1. 存在时替换 system prompt 的第 1 段（内置固定指令）；工具说明、环境、技能、记忆、agent 定义仍按规则拼接
2. 文件必须可读、非空且是合法 UTF-8；否则退出 2
3. 文本统一规范化：CRLF / 单独 CR → LF，去掉首尾空白，结尾保证恰好一个 `\n`；内部空行与缩进保持不变
4. 只影响新 session；恢复 / fork 使用 `session_start` 中冻结的 prompt
5. 不存在“完全裸 prompt”模式：环境与工具说明等自动小节始终保留

需要追加提示词时，写入 `~/.agents/AGENTS.md`（全局）或项目 `AGENTS.md`，不提供 `--append-system-prompt`。

`--no-agents-md`：不读取 `~/.agents/AGENTS.md`，也不从 cwd 向上发现项目 `AGENTS.md`；system prompt 中不会出现「全局记忆」「项目记忆」小节。不改变 `AGENTS.md` 文件本身，也不改变文件工具的读取能力。

`--no-skills`：只关闭“扫描技能并注入清单”；prompt 中不出现 `<available_skills>`，`--list-skills` 仍正常列出。它不是安全边界，模型仍可用 `bash` / `read_file` 读 `SKILL.md`。

### 查看技能

`--list-skills` 在加载配置之前处理，列出 `~/.agents/skills` 与 `<启动目录>/.agents/skills` 中的有效技能后退出（退出码 0）。它不需要 `settings.json` 或 API key，`--config-dir` 对它没有影响；`--help` / `--version` 的优先级更高。`--no-skills` 只影响新 session 的提示词注入，不影响该命令。格式与发现规则见 [skills.md](skills.md)。

### 查看 system prompt

`--print-system-prompt` 把本次运行使用的 system prompt 原文写到 stdout 后退出（退出码 0），不创建 session、不写 transcript、不调用模型，也不需要提示词或 API key。它会正常加载配置、定位 bash 并解析 agent，因此需要可用的 `settings.json`（`model` 仍必填）和 `bash`；受 `--config-dir`、`--agent`、`$AP_CONFIG/SYSTEM.md`、`--no-agents-md`、`--no-skills` 影响。新 session 的组装入口与 `session_open` 共用应用的 `build_prompt_sections`，保证打印结果与模型收到的冻结 prompt 一致。

新 session 按 [context-management.md](context-management.md) 的规则现场组装（技能清单、记忆文件、agent 定义都会重新扫描）。存在 `SYSTEM.md` 时，打印的是**完整组装结果**，不是只打印 base 文本。与 `-s` / `-c` 连用时打印该 session 在 `session_start` 中冻结的 prompt。输出不受 `--output-format` 影响，始终是纯文本，末尾保证有换行。

### 输出格式

stdout 只放结果，所有日志、进度、工具执行信息走 stderr。

stderr 上的进度按 markdown 排版：一次 step 是一行 `## Step N`，一次工具调用是一行 `### <工具名>`，工具输出后跟一行斜体状态 `_<工具名> ok (26ms)_`；标题行与内容块之间各留一个空行，`ap -p ... > out.md 2>&1` 的产物可直接当 markdown 读。

turn 结束、进程退出前，还会向 stderr 打印续聊提示（`---` 分隔线后是 `继续对话，执行：<可执行文件> -s <session_id>`），可直接复制该命令继续同一段对话；三种输出格式下都会打印。

| 格式 | stdout |
| --- | --- |
| `text` | 最后一条包含文本的 assistant 消息，在 turn 结束后一次性输出；不输出中间步骤文本 |
| `json` | 单个 JSON 对象，turn 结束后输出 |
| `stream-json` | 每行一个事件；包含持久事件与临时 stream 事件，见 [react-loop-and-session.md](react-loop-and-session.md) |

`json` 对象：

```jsonc
{
  "session_id": "...",
  "result": "...",
  "stop_reason": "stop",
  "num_steps": 3,
  "usage": {
    "input_tokens": 0,
    "output_tokens": 0,
    "cached_tokens": 0,
    "reasoning_tokens": 0,
    "total_tokens": 0
  }
}
```

`stop_reason` 取值：`stop` / `max_tokens` / `max_steps` / `cancelled` / `context_too_long`。字段未知时写 `null`，不要写 0 冒充真实值。

`usage` 只在正常结束路径（`stop` / `max_tokens` / `max_steps`）填入本 turn 的累加；取消、provider 最终失败、工具基础设施故障等提前退出路径可能返回全 null 的 usage，`stop_reason` 也可能为 `null`。整个 session 的累计始终看 `session_end.usage`。没有任何 assistant 文本时 `result` 为空字符串。

### 恢复时的参数处理

恢复以 transcript 为准，`session_start` 中冻结的 system prompt、model、provider、agent_name、agent_depth、cwd 与工具集不再重算。`$AP_CONFIG/SYSTEM.md` 只在新 session 生效；恢复时不会重新读取，也不再重新加载 agent 文件。以下输入与冻结值冲突时**在 stderr 打 warning 并忽略**，退出码不受影响：

- `--model`（与记录不同值时）
- `--agent`（与记录不同值时）
- SDK 的 `base_system_prompt` 输入（CLI 通过 `$AP_CONFIG/SYSTEM.md` 提供等价内容）
- 应用层 prompt sections
- 工具集覆盖
- `--parent-session-id` / `--parent-tool-call-id` / `--agent-depth`

warning 文案（宿主通过 SDK 传入这些输入时由 session 层产生；`ap-cli` 在恢复时不会构造 base/sections/tools，因此正常 CLI 恢复通常只看到 `--model` / `--agent` / 父链参数相关 warning）：

```text
--base-system-prompt ignored on restore: session prompt is frozen
prompt sections ignored on restore: session prompt is frozen
tool set ignored on restore: session is frozen to its recorded tool set
--agent ignored on restore: session is frozen to "<name>"
```

`--no-agents-md` / `--no-skills` 在恢复时不影响冻结 prompt，也不会产生 warning；它们只在新建 session 时参与 sections 组装。

恢复后的工具集以 `session_start.tools` 为准：改 `agents/<name>.md` 中的 `tools:` 或注册表新增工具都不再影响已有 session。冻结列表里在当前注册表中不存在的工具会跳过并 warning。旧 transcript 没有 `tools` 字段时不再回退到 agent 定义：使用当前注册表的全部工具并 warning。

以下参数在恢复时照常生效：

- `--max-steps`、`--max-tokens`
- `--output-format`、`--verbose` / `--debug`
- 提示词来源
- `--fork-session`
- `--config-dir`（必须先于查找生效，否则找不到 transcript）

冻结的是 `session_start` 中的字段；`max_steps` / `max_tokens` 不在其中。恢复时若没有传 `--max-steps`，采用 `settings.json` 的值；`--max-tokens` 同理取配置或命令行。不再重新加载 agent 定义，因此 agent 文件里的 `max_steps` 不会影响已有 session。

找不到 session 时退出码 2，并打印期望路径，例如：

```
session "abc" not found in project <hash> (expected .../projects/<hash>/abc.jsonl)
hint: run ap from the directory where the session was created
```

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 正常结束（含 `stop_reason: max_steps` / `max_tokens`；具体原因看输出） |
| 1 | 内部错误（panic、不可恢复的断言失败、transcript 写入/flush 失败、event 序列化失败） |
| 2 | 用法或配置错误（参数非法、模型未配置、`$AP_CONFIG` 不可写、找不到 `bash`、session 不存在） |
| 3 | provider 错误（鉴权失败、模型不存在、重试耗尽、`context_too_long`） |
| 4 | 工具基础设施故障（无法 spawn shell、工具参数/system prompt 的 blob 写入失败等） |
| 130 | 被 SIGINT 中断 |
| 143 | 被 SIGTERM 中断 |

`text` 格式下 stdout 只有最终文本，脚本若需要区分「正常说完」与「被 max_steps 截断」，应使用 `json`。

## 配置文件

配置文件固定为 `$AP_CONFIG/settings.json`，由 `--config-dir` / `AP_CONFIG` 决定。文件只由 `ap` 进程（`ap-cli`）读取与校验；`ap-core` 的 SDK 门面只接收解析后的 `Settings`，不打开这个文件，也不读 `AP_*` 环境变量。

```jsonc
{
  "model": "<model_id>",                 // 必填
  "base_url": "https://api.openai.com/v1", // 可选，默认官方
  "api_key": "<api_key>",                // 与环境变量二选一

  "max_steps": 100,                      // 单个 turn 的最大 step 数
  "max_agent_depth": 1,                  // 子代理最大嵌套深度
  "max_tokens": 8192,                    // 单次响应上限
  "tool_timeout_ms": 120000,             // bash 默认超时
  "llm_timeout_ms": 600000,              // 单次 LLM 请求总超时
  "blob_threshold_bytes": 102400,        // 超过则写 blob
  "max_capture_bytes": 67108864,         // 单次工具输出硬上限（64MB）
  "stream_include_usage": true           // 请求 stream_options.include_usage
}
```

约束：

1. `model` 必填；`base_url` 缺省为官方地址；`api_key` 必须由配置或 `AP_API_KEY` 提供
2. `api_key` 支持用环境变量 `AP_API_KEY` 覆盖；日志与 transcript 中不记录
3. 未知字段忽略并警告；类型错误按配置错误处理（退出码 2）
4. 文件格式与字段名不变；`ap-cli/settings.odin` 一次读取后拆成 SDK `Settings` 与 `aptools.Tool_Config`
5. 不再有 `context_window`、`auto_compact_threshold`、`output_limit_bytes` 等字段

字段归属：

| 字段 | 归属 |
| --- | --- |
| `model`、`base_url`、`api_key` | SDK / provider |
| `max_steps`、`max_tokens`、`blob_threshold_bytes`、`stream_include_usage` | SDK / loop |
| `llm_timeout_ms` | SDK / provider |
| `tool_timeout_ms`、`max_capture_bytes`、`max_agent_depth` | 应用层 / `aptools.Tool_Config` |

`path`（配置文件路径）不再属于 SDK `Settings`，由 `ap-cli` 自己持有。

## 环境变量

| 变量 | 说明 |
| --- | --- |
| `AP_CONFIG` | 配置根目录，默认 `~/.ap`；`--config-dir` 优先 |
| `AP_API_KEY` | 覆盖 settings.json 中的 `api_key` |
| `AP_BASH` | 指定 `bash` 可执行文件的绝对路径；设置后不再搜索 PATH 和常见安装位置 |

父子关联只走命令行参数，不使用 `AP_PARENT_*` 环境变量。`bash` 工具执行命令时会剔除 `AP_API_KEY`，避免把密钥暴露给模型可控的命令。

## 工作区布局

```
$AP_CONFIG/
  settings.json
  SYSTEM.md                          # 存在时替换内置固定指令段
  agents/
    <name>.md                        # 子代理定义
  projects/
    <project_path_hash>/
      path.txt                       # 规范化后的项目路径，便于反向排查
      blobs/
        <sha256>                     # 内容寻址的大块数据，用户自行清理
      <session_id>.jsonl             # transcript，一行一个事件

~/.agents/
  AGENTS.md                          # 全局记忆 / 追加提示词
```

transcript 一行一个事件，完整事件只追加；恢复时若发现崩溃留下的不完整尾行，会先截掉它再追加新事件。blob 由用户自行清理。

技能不在 `$AP_CONFIG` 下，固定从两处发现：`~/.agents/skills/<name>/SKILL.md` 与 `<启动目录>/.agents/skills/<name>/SKILL.md`。见 [skills.md](skills.md)。

## 项目识别

1. 以启动目录为项目根；解析为绝对路径
2. 规范化：解析 `.` / `..` / 符号链接 / junction，去掉尾部分隔符，把 `\` 统一成 `/`
3. Windows 上把整条路径转小写（不能只小写盘符，`Z:\Projects\AP` 与 `Z:\projects\ap` 必须落到同一目录）
4. `project_path_hash = fnv32a(规范化路径)`，取 8 位 hex
5. `path.txt` 存规范化路径；若同一 hash 对应的 `path.txt` 内容不同，视为冲突并退出 2
6. `-s` / `-c` **只在当前项目目录内查找**，不跨项目、不扫描其它 hash；从子目录启动会落到不同项目，找不到原 session

`--config-dir` 只改变存储根目录，不改变 project hash。

## 恢复、继续与 fork

### `-s <id>`

读取 `projects/<hash>/<id>.jsonl`，按文件行序重放（正常写入下即 `seq` 递增），重建消息与 usage，然后以追加方式继续写同一文件。恢复时追加一个新的 `session_start`：

- `session_id` 不变
- `resumed_from` 指向自身
- `content` / `model` / `provider` / `agent_name` / `agent_depth` / `cwd` / `tools` 与上一次 `session_start` 完全一致
- 读取方以最后一个 `session_start` 为准

### `-c`

在当前项目内选择最近修改的根 session（最后一个 `session_start` 的 `parent_session_id` 为 null）。子代理 session 不参与 `-c`。

### `--fork-session`

必须与 `-s` / `-c` 连用。行为：

1. 生成新的 `session_id`（`ses_<本地时间 YYYYMMDD_HHmmss>_<UUID 前 12 位十六进制>`）
2. 复制源 transcript 的全部事件到同项目目录下的新文件
3. 追加新的 `session_start`：
   - `session_id` = 新 id
   - `resumed_from` = 源 id
   - `parent_session_id` / `parent_tool_call_id` = null（fork 后是独立根 session）
   - `agent_depth` = 0
   - `content` / `model` / `provider` / `agent_name` / `cwd` / `tools` 沿用源
4. `seq` 从源文件最大 seq + 1 继续
5. blob 不复制，按 sha256 共享；删除 blob 会同时破坏源 session 和 fork
6. 新文件写在**源 session 所在的项目目录**（与当前项目相同）

## 交互命令

无。v1 不支持 `/clear`、`/compact`、`/model`、`/cost`、`/resume`、`/help` 等交互命令。所有行为通过命令行参数与输出格式表达。
