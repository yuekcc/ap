# CLI 与配置

`ap` 是单次运行的命令行程序：读取一条提示词，跑完一个 turn，写出结果后退出。
本文件定义参数、提示词来源、输出格式、退出码、`settings.json`、环境变量、存储布局、项目识别，以及恢复、继续和 fork 的 CLI 行为。
事件字段、`turn` 与 `step` 状态机、transcript 结构见 [react-loop-and-session.md](react-loop-and-session.md)。system prompt 的内容见 [context-management.md](context-management.md)。

## 运行形态

`ap` 没有交互式 REPL、TUI 或内置取消键。`ap-tui` 与 `ap-web` 是独立前端，每轮拉起一个 `ap` 子进程，通过 `--output-format stream-json` 交互，见 [tui.md](tui.md)、[web.md](web.md) 与 [integration.md](integration.md)。

一次运行只处理一条提示词，因此一次运行最多产生一个 user turn。脚本、前端和子代理复用同一个入口，差异只在参数和输出格式。ap 不提供 `--headless`，所有运行都是非交互的。

## 参数

带值的长参数接受 `--flag value` 和 `--flag=value` 两种写法。短别名 `-s`、`-p` 只接受分开的值。`--` 与位置参数会被拒绝。

| 参数 | 值 | 作用 |
| --- | --- | --- |
| `-h`, `--help` | — | 打印用法，退出 0 |
| `--version` | — | 打印版本，退出 0 |
| `-s`, `--session <id>` | session_id | 恢复当前项目内的指定 session |
| `-c`, `--continue` | — | 恢复当前项目内最近的根 session |
| `--fork-session` | — | 与 `-s` 或 `-c` 连用，把历史复制到新 session |
| `--agent <name>` | agent 名 | 使用 `$AP_CONFIG/agents/<name>.md`，缺省为内置 `general` |
| `-p`, `--print <prompt>` | 提示词 | 直接提供提示词 |
| `--input-file <path>` | 文件路径 | 从 UTF-8 文件读取提示词 |
| `--print0` | — | 从 fd 0 读取提示词直到 EOF |
| `--config-dir <path>` | 目录 | 设置 `$AP_CONFIG`，默认 `~/.ap` |
| `--model <id>` | model_id | 覆盖 model |
| `--max-steps <n>` | 正整数 | 单个 turn 的最大 step 数 |
| `--max-tokens <n>` | 正整数 | 单次响应的 `max_tokens` |
| `--context-window <n>` | 非负整数 | 覆盖 `context_window_tokens`；`0` 关闭预算与自动交接 |
| `--handoff [提示词]` | 可选文本 | 立即生成交接文档并创建新 session；需与 `-s`、`-c` 或 `--fork-session` 连用 |
| `--no-handoff` | — | 关闭自动交接，`context_too_long` 恢复为退出 3 |
| `--output-format <fmt>` | `text`、`json`、`stream-json` | 输出格式，默认 `text` |
| `--parent-session-id <id>` | session_id | 标记当前进程是某个 session 的子代理 |
| `--parent-tool-call-id <id>` | tool_call_id | 父进程中对应的 `task` 调用 |
| `--agent-depth <n>` | 非负整数 | 当前 agent 深度，默认 0 |
| `--no-agents-md` | — | 不注入全局和项目 `AGENTS.md` |
| `--no-skills` | — | 不扫描、不注入技能清单 |
| `--print-system-prompt` | — | 打印本次 system prompt 后退出 |
| `--list-skills` | — | 列出当前目录可见的技能后退出 |
| `--verbose` | — | 输出 info 及更高级别日志 |
| `--debug` | — | 输出 debug 及更高级别日志 |

约束：

- `-s` 与 `-c` 互斥。`--fork-session` 必须与其中之一连用。
- `--handoff` 必须与 `-s`、`-c` 或 `--fork-session` 之一连用，与 `--print-system-prompt` 互斥，与 `--no-handoff` 互斥。源 session 没有任何 `user_message` 时退出 2。
- `--context-window` 必须是非负整数。`0` 表示显式关闭预算，与不传不等价：不传时取配置值，默认为 `1048576`。
- `--parent-tool-call-id` 必须与 `--parent-session-id` 同时使用。新 session 的父 transcript 必须存在。
- `--session` 与 `--parent-session-id` 的取值不能是 `.`、`..`，也不能包含 `/`、`\` 或 NUL。
- `--max-steps` 与 `--max-tokens` 必须是正整数。`--agent-depth` 必须是非负整数。
- 新 session 的 `model` 与 `max_steps` 优先级是命令行 > agent 定义 > `settings.json`。`max_tokens` 只有命令行与 `settings.json` 两级，agent 定义没有该字段。不传 `--max-tokens` 时取 `settings.json`，两者都没有时为默认值 `65536`。
- 不提供 `--add-dir`。相对路径只相对启动目录，绝对路径不受限制。
- 参数非法、缺值或冲突时退出 2。

## 提示词来源

`--print`、`--input-file`、`--print0` 三选一。正常运行必须且只能给一个。同时出现多个在解析参数时退出 2，一个都不给在读取提示词时退出 2。`--help`、`--version`、`--list-skills`、`--print-system-prompt` 不需要提示词。

- `--print`：参数即提示词。空字符串和非法 UTF-8 都退出 2。Windows 上若系统 ANSI 代码页不是 UTF-8，ap 会先用宽字符命令行重建参数，再转成 UTF-8。
- `--input-file`：路径按启动目录解析，支持 `~`。文件必须存在、可读、非空且是合法 UTF-8。
- `--print0`：从 fd 0 读到 EOF。帮助文本写明 `0 = stdin`，不要把它理解成 NUL 分隔。空输入和非法 UTF-8 都退出 2。
- ap 不再根据 stdin 是否为 TTY 隐式读取。集成方需要从 stdin 取提示词时，必须显式传 `--print0`，写完提示词后关闭写端。

## handoff

`--handoff` 走一条独立路径：先让源 session 生成交接文档，再由 CLI 创建承载它的新 session。

- `ap -s <id> --handoff "<prompt>"`：`<prompt>` 同时是交接的聚焦提示与**新 session** 的第一个 turn，用同一条文本。新 session 跑完这个 turn 后正常输出结果。
- `ap -s <id> --handoff`：只创建新 session 并打印它的 id，不跑 turn。
- 源 session 先写 `handoff` 事件与 `session_end`，再创建新 session。两者的 `session_end.usage` 都包含交接那次调用。
- 新 session 走正常 new session 路径：重新组装 system prompt，用当前工具集、当前模型、当前 `AGENTS.md` 与技能。**不是 fork**。第一条事件是承载交接文档的 `user_message`，首行为 `## 上一会话交接`。
- `text` 格式下交接文档不进 stdout，stderr 写一行 `handoff created session <id>`；`json` 格式新增顶层 `handoff` 对象（见下）；`stream-json` 照常转发 `handoff` 事件。
- 交接成功退出 0，`stop_reason` 为 `handoff`。交接失败按 `--no-handoff` 的行为结束，退出 3。

自动交接（`budget_exhausted`、`context_too_long`）不需要 `--handoff`：预算默认开启，上下文真的不够用时自动发生。`--no-handoff` 关闭它，`context_window_tokens = 0` 把整套上下文管理关掉。

## 上下文开关

`$AP_CONFIG/SYSTEM.md` 存在时替换 system prompt 的 base 段。文件校验、换行规范化、只影响新 session 的规则见 [context-management.md](context-management.md)。ap 不提供 `--append-system-prompt`。要追加提示词，写入 `~/.agents/AGENTS.md` 或项目 `AGENTS.md`。

`--no-agents-md` 关闭全局与项目记忆的读取和注入，不改变磁盘上的文件。`--no-skills` 关闭技能扫描与清单注入。两个开关都只影响新 session，也都不是安全边界。技能规则见 [skills.md](skills.md)。

## 检查命令

`--list-skills` 在加载配置之前处理。它扫描 `~/.agents/skills` 与 `<启动目录>/.agents/skills`，打印人读简表后退出 0。它不读 `settings.json`，不需要 API key，`--config-dir` 对它没有影响，`--no-skills` 也不改变输出。`--help` 与 `--version` 的优先级更高。格式见 [skills.md](skills.md)。

`--print-system-prompt` 把本次运行使用的 system prompt 原文写到 stdout 后退出 0。它不创建 session、不写 transcript、不调用模型，也不需要提示词。

- 新 session 路径会加载 `settings.json`、定位 bash、解析 agent，并按开关重新扫描技能、记忆和 agent 定义。`model` 仍必填，API key 不要求。
- 受 `--config-dir`、`--agent`、`$AP_CONFIG/SYSTEM.md`、`--no-agents-md`、`--no-skills` 影响。
- 与 `-s` 或 `-c` 连用时，打印该 session 在 `session_start` 中冻结的 prompt，不重新解析 agent。
- 输出始终是纯文本，不受 `--output-format` 影响，末尾保证换行。

## 输出

stdout 是机器通道，只放结果或事件。日志、进度和工具输出全部走 stderr。三种格式都遵守这一条。

| 格式 | stdout | stderr |
| --- | --- | --- |
| `text` | 最后一条含文本的 assistant 消息，turn 结束后一次性输出 | ap-tui 风格进度 |
| `json` | 单个结果对象，turn 结束后输出 | markdown 风格进度 |
| `stream-json` | 每行一个事件，包含持久事件与临时 stream 事件 | markdown 风格进度 |

`stream-json` 的事件类型与字段见 [react-loop-and-session.md](react-loop-and-session.md)。临时 stream 事件不落盘，也不能用于恢复。

### stderr 排版

`text` 模式：

- 工具开始是一行 `◆ <工具名> (<参数摘要>)`。参数压成一行，超过 240 字节截断。
- 工具输出缩进两格并显示为暗色。成功且没有增量输出时补一段结果预览，超过 200 行或 20000 字节时截断并提示 `… (truncated; full content is in the transcript)`。实时 bash 流不截断。
- 工具结束是一行 `✓ <耗时>ms exit <code>` 或 `✗ <耗时>ms <错误>`。`exit` 只在工具返回退出码时出现。
- 可重试错误是 `… [<scope>] <消息>`，不可重试错误是 `! [<scope>] <消息>`。取消提示是 `cancelled [<scope>]`。非 `stop` 结束时再打一行 `turn ended: <stop_reason>`。
- assistant 文本不流式写到 stderr，答案仍只在 turn 结束后写 stdout。
- ANSI 颜色只在 stderr 是 TTY 且 `NO_COLOR` 未设置或为空时开启。

`json` 与 `stream-json` 模式用 markdown 排版。块与块之间留一个空行：

- 一个 step 是 `## Step N`。
- 一次工具调用是 `### <工具名>`，随后是工具输出。
- 工具结束是斜体状态行 `_<工具名> ok (<N>ms)_` 或 `_<工具名> failed (<N>ms)_`。
- 重试提示是 `[retry] ...`。`text` 模式不重复打印重试提示，因为 `error` 事件已经显示过。
- 上下文管理提示是 `[context] ...`：省略时写 `elided N tool results, ~M tokens saved`，provider 拒绝后可重算时写 `provider rejected request as too long; recomputing with tighter budget`。

turn 结束、进程退出前，三种格式都会向 stderr 打印续聊提示：

```text
---

continue with -s <session_id>
```

创建了交接 session 时，这一行换成 `handoff created session <id>`，指向新 session。

### json 结果

```jsonc
{
  "session_id": "ses_...",
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

`stop_reason` 的取值是 `stop`、`max_tokens`、`max_steps`、`cancelled`、`context_too_long`、`handoff`。字段没有值时写 `null`，不要用 0 冒充真实值。`tool_use` 只出现在 provider 结束原因里，不是最终 turn 的 `stop_reason`。

有交接时新增顶层字段，没有时为 `null`：

```json
"handoff": {
  "reason": "budget_exhausted",
  "session_id": "ses_...",
  "content": "...",
  "usage": { "...": "..." }
}
```

`session_id` 是承载交接文档的新 session，`content` 是交接文档正文，`usage` 是生成它那次调用的用量。`reason` 取 `budget_exhausted`、`context_too_long` 或 `manual`。

`usage` 只在 `stop`、`max_tokens`、`max_steps` 三条正常结束路径填入本 turn 的累加。交接成功时本 turn 的 `usage` 仍可能是 `null`（预算耗尽路径没有发出主请求），交接那次调用的用量看 `handoff.usage` 与 `session_end.usage`。取消、`context_too_long`、provider 最终失败和工具基础设施故障的 usage 各字段为 `null`。取消的 `stop_reason` 是 `cancelled`。provider 最终失败和工具基础设施故障可能让 `stop_reason` 为 `null`。整个 session 的累计看 `session_end.usage`。

没有任何 assistant 文本时，`result` 是空字符串。`text` 格式下 stdout 不写任何字节。

## 日志

诊断日志追加到 `$AP_CONFIG/logs/app-YYYY-MM-DD.log`，按本地日期一天一个文件。

- 默认级别是 warning。`log_error` 始终输出，`log_warn` 在 warning 及以上输出。`--verbose` 加上 info，`--debug` 再加上 debug。
- 一条日志一行：`YYYY-MM-DD HH:MM:SS [level] message`。消息自带换行时，续行保留同一前缀并缩进两格。
- 进程内第一条日志才创建 `logs/` 和文件。整次运行没有日志就不留空文件。
- 目录不可写、磁盘满等写入失败一律吞掉，不影响退出码和 stderr。
- 子代理是独立进程，和父进程写同一个文件，靠追加模式拼接。跨天时各自切到新文件。
- 日志不记录 `api_key`。

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 正常结束，包括 `stop_reason` 为 `max_steps`、`max_tokens` 或 `handoff` |
| 1 | 内部错误，例如 transcript 写入或 flush 失败、事件序列化失败 |
| 2 | 用法或配置错误，例如参数非法、模型未配置、`$AP_CONFIG` 不可写、找不到 bash、session 不存在 |
| 3 | provider 错误，例如鉴权失败、模型不存在、重试耗尽，以及关闭或退出的 `context_too_long` |
| 4 | 工具基础设施故障，例如无法 spawn shell、工具参数或 system prompt 的 blob 写入失败 |
| 130 | 收到 SIGINT 或 Windows Ctrl+C |
| 143 | 收到 SIGTERM |

`text` 格式的 stdout 只有最终文本。要区分“正常说完”和“被 max_steps 截断”，使用 `json`。

## 配置文件

配置文件是 `$AP_CONFIG/settings.json` 或 `$AP_CONFIG/settings.jsonc`。探测顺序是 `settings.jsonc` 优先：两者同时存在时只用 `.jsonc`，另一个文件既不参与合并也不参与校验。两个都不存在时按配置错误退出 2，报错指向 `settings.json`，因为示例和文档都从它出发。

不论后缀，内容都按 JSON5 规格解析，所以注释和尾逗号合法。JSON5 比 JSONC 宽：除注释与尾逗号外还接受单引号字符串、十六进制数字、`NaN`/`Infinity`。注释只被扫描丢弃、不保留，因此配置文件只能手写，没有回写路径。

`ap-cli` 与 `magi` 用同一套探测与解析规则，前者读取完整字段，后者只读取 provider 相关字段。`ap-core` 的 SDK 门面只接收解析后的 `Settings`，不打开这个文件，也不读 `AP_*` 环境变量。

```jsonc
{
  "model": "<model_id>",                    // 必填
  "base_url": "https://api.openai.com/v1",  // 可选，默认官方地址
  "api_key": "<api_key>",                   // 与环境变量二选一

  "max_steps": 100,                         // 单个 turn 的最大 step 数
  "max_agent_depth": 1,                     // 子代理最大嵌套深度
  "max_tokens": 65536,                     // 单次响应上限
  "tool_timeout_ms": 120000,                // bash 默认超时
  "llm_timeout_ms": 600000,                 // 单次 LLM 请求总超时
  "blob_threshold_bytes": 102400,           // 超过则写 blob
  "max_capture_bytes": 67108864,            // 单次工具输出硬上限
  "image_input": false,                     // read_file 是否返回图片附件
  "image_max_bytes": 5242880,               // 单张图片上限
  "stream_include_usage": true,             // 请求 stream_options.include_usage
  "context_window_tokens": 1048576,         // 模型上下文窗口，0 表示不设预算
  "context_reserve_percent": 5,             // 余量占窗口的百分比，0 表示不留
  "handoff_max_tokens": 16384               // 生成交接文档那次调用的 max_tokens
}
```

约束：

1. `model` 必填。即使命令行传了 `--model`，配置文件里仍必须有 `model`。
2. `api_key` 可以由 `AP_API_KEY` 覆盖。两处都没有时退出 2，`--print-system-prompt` 除外。
3. `base_url` 缺省为官方地址，末尾斜杠会被去掉，空值报错。
4. 未知字段忽略并警告。类型错误、非法取值都按配置错误退出 2。显式 `null` 按缺失处理。
5. 整数字段接受整数值的浮点数。`max_steps`、`max_tokens`、两个超时和三个尺寸上限（`blob_threshold_bytes`、`max_capture_bytes`、`image_max_bytes`）必须为正。`max_agent_depth` 必须非负。
6. `context_window_tokens` 必须非负；`0` 表示不设预算，此时另外两个字段不参与计算。非零时必须大于 `max_tokens` 与 `handoff_max_tokens`，并且 `max_tokens + reserve` 必须小于窗口（`reserve = context_window_tokens * context_reserve_percent / 100`），否则预算公式的前两项必为负。`context_reserve_percent` 取 `0`–`100`，`handoff_max_tokens` 必须为正。这些冲突在启动时按配置错误退出 2。
7. `ap-cli/settings.odin` 一次读取后拆成 SDK `Settings` 与 `aptools.Tool_Config`。

默认值按 1M 上下文、64K 单次输出的模型规格取：`max_tokens` 为 `65536`，`context_window_tokens` 为 `1048576`，`context_reserve_percent` 为 `5`（余量占窗口的 5%，1M 窗口下是 `52428`），`handoff_max_tokens` 为 `16384`。`max_tokens` 与 `context_window_tokens` 是模型能力的上限声明，不是每轮都会用到的量：前者是单次响应的天花板，后者是预算计算的输入。只有 `context_window_tokens` 有命令行覆盖（`--context-window`）；`max_tokens` 用 `--max-tokens` 覆盖；余量比例与交接上限只能改配置。

字段归属：

| 字段 | 归属 |
| --- | --- |
| `model`、`base_url`、`api_key` | SDK provider |
| `max_steps`、`max_tokens`、`blob_threshold_bytes`、`stream_include_usage`、`context_window_tokens`、`context_reserve_percent`、`handoff_max_tokens` | SDK loop |
| `llm_timeout_ms` | SDK provider |
| `tool_timeout_ms`、`max_capture_bytes`、`image_input`、`image_max_bytes`、`max_agent_depth` | 应用层 `Tool_Config` |

配置文件路径不属于 SDK `Settings`，由 `ap-cli` 自己持有。

`image_input` 默认 `false`。开启后 `read_file` 才会把 PNG、JPEG、GIF、WebP 作为图片附件交给模型；文本模型保持关闭可避免请求被 provider 拒绝。`image_max_bytes` 只限制单张图片，ap 不做缩放或转码。

## 环境变量

| 变量 | 作用 |
| --- | --- |
| `AP_CONFIG` | 配置根目录，默认 `~/.ap`。`--config-dir` 优先 |
| `AP_API_KEY` | 覆盖 `settings.json` 中的 `api_key` |
| `AP_BASH` | 指定 bash 可执行文件的绝对路径。设置后不再搜索 PATH 和常见安装位置 |
| `NO_COLOR` | 非空时关闭 `text` 模式 stderr 的 ANSI 颜色 |

`bash` 工具还会向子进程注入只读快照：`AP_SESSION_ID`、`AP_PARENT_SESSION_ID`（根 session 为空字符串）和 `AP_TRANSCRIPT_PATH`。它们只供脚本读取当前会话信息，不参与进程间通信。

父子关联只走命令行参数，不使用 `AP_PARENT_*` 环境变量。`bash` 工具执行命令时会剔除 `AP_API_KEY`，避免把密钥暴露给模型可控的命令；继承来的三个会话变量也会先剔除再写入当前值。

bash 查找顺序是 `AP_BASH`、PATH、常见安装位置。Windows 跳过路径中含 `system32` 或 `windowsapps` 的 `bash.exe`，避免选中 WSL 的 bash。

## 工作区布局

```text
$AP_CONFIG/
  settings.json                      # 或 settings.jsonc，同时存在时后者优先
  SYSTEM.md                          # 存在时替换内置固定指令段
  agents/
    <name>.md                        # agent 定义
  logs/
    app-YYYY-MM-DD.log               # 诊断日志，按本地日期一天一个
  projects/
    <project_path_hash>/
      path.txt                       # 规范化后的项目路径
      blobs/
        <sha256>                     # 内容寻址的大块数据
        <sha256>.txt                 # bash 分页续读用的完整输出
      <session_id>.jsonl             # transcript，一行一个事件

~/.agents/
  AGENTS.md                          # 全局记忆
```

transcript 只追加完整事件。恢复时若发现崩溃留下的不完整尾行，会先截掉它再追加新事件。blob 由用户自行清理，删除 blob 会让引用它的 session 无法完整恢复。blob 规则见 [tools.md](tools.md)。

技能不在 `$AP_CONFIG` 下。发现位置见 [skills.md](skills.md)。

## 项目识别

1. 以启动目录为项目根，解析为绝对路径。
2. 清理 `.`、`..`，解析符号链接和 Windows junction。
3. 去掉尾部分隔符，把 `\` 统一成 `/`。
4. Windows 上把整条路径转小写。`Z:\Projects\AP` 与 `Z:\projects\ap` 必须落到同一目录。
5. `project_path_hash = fnv32a(规范化路径)`，取 8 位十六进制。
6. `path.txt` 保存规范化路径。同一 hash 对应的 `path.txt` 内容不同时视为冲突，退出 2。
7. `-s` 与 `-c` 只在当前项目目录内查找，不跨项目，不扫描其它 hash。从子目录启动会落到不同项目。

`--config-dir` 只改变存储根目录，不改变 project hash。

## 恢复、继续与 fork

### `-s <id>`

读取 `projects/<hash>/<id>.jsonl`，按文件行序重放事件，重建消息与 usage，然后以追加方式继续写同一文件。新 `session_start` 沿用原 id 与冻结值，`resumed_from` 指向自身。写入细节见 [react-loop-and-session.md](react-loop-and-session.md)。

### `-c`

在当前项目内选择最近修改的根 session。判断依据是文件修改时间，以及最后一个 `session_start` 的 `parent_session_id` 为空。子代理 session 不参与 `-c`。

### `--fork-session`

必须与 `-s` 或 `-c` 连用。CLI 侧可见的行为是：

1. 生成新的 `session_id`，格式是 `ses_<本地时间 YYYYMMDD_HHmmss>_<UUID 前 12 位十六进制>`。
2. 复制源 transcript 的全部完整事件到当前项目目录下的新文件。末尾半行不进入 fork。
3. 新 session 是独立根 session，`resumed_from` 指向源 id，`agent_depth` 为 0，prompt、model、provider、agent、cwd 和工具集沿用源 session。
4. blob 不复制，按 sha256 共享。删除 blob 会同时破坏源 session 和 fork。

新 `session_start` 的字段与 `seq` 规则见 [react-loop-and-session.md](react-loop-and-session.md)。

### 恢复时的参数

恢复以 transcript 为准。`session_start` 中冻结的 system prompt、model、provider、agent_name、agent_depth、cwd 与工具集不再重算。`$AP_CONFIG/SYSTEM.md` 只在新 session 生效，恢复时不重新读取，也不重新加载 agent 定义。

以下输入与冻结值冲突时，在 stderr 打 warning 并忽略，退出码不受影响：

- `--model` 与记录不同时，warning 为 `--model ignored on restore: session is frozen to "<model>"`。
- `--agent` 与记录不同时，warning 为 `--agent ignored on restore: session is frozen to "<agent>"`。
- `--parent-session-id`、`--parent-tool-call-id` 或大于 0 的 `--agent-depth`，warning 为 `parent/agent-depth arguments ignored on restore`。

`--no-agents-md` 与 `--no-skills` 在恢复时既不影响冻结 prompt，也不产生 warning。

以下参数在恢复时照常生效：

- `--max-steps` 与 `--max-tokens`。没有传时取 `settings.json`。
- `--output-format`、`--verbose`、`--debug`。
- 提示词来源。
- `--fork-session`。
- `--config-dir`，它必须先于查找生效。

恢复后的工具集以 `session_start.tools` 为准。改 agent 文件里的 `tools:` 或注册表新增工具都不再影响已有 session。冻结列表里在当前注册表中不存在的工具会跳过并 warning。旧 transcript 没有 `tools` 字段时，使用当前注册表的全部工具并 warning。

恢复时若发现上一次运行没有写 `session_end`，会 warning 并继续恢复。完整判断与恢复顺序见 [react-loop-and-session.md](react-loop-and-session.md)。

找不到 session 时退出 2，并打印期望路径：

```text
session "abc" not found in project <hash> (expected .../projects/<hash>/abc.jsonl)
hint: run ap from the directory where the session was created
```

## 相关文档

- [react-loop-and-session.md](react-loop-and-session.md)：turn/step、事件 schema、恢复与 fork 的写入细节。
- [context-management.md](context-management.md)：system prompt 的组装与消息投影。
- [tools.md](tools.md)：五个工具的参数、blob 与进程树。
- [skills.md](skills.md)：技能发现、`SKILL.md` 格式与 `--list-skills` 输出。
- [integration.md](integration.md)：新前端如何拼命令行并消费三个输出流。
