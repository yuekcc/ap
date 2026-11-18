# 工具

ap 只有五个工具：`read_file`、`write_file`、`edit_file`、`bash`、`task`。
本文件定义它们的参数、结果结构、blob 规则、进程树行为和注册表。错误分类、重试与取消后的事件顺序见 [errors-and-cancellation.md](errors-and-cancellation.md)，事件字段见 [react-loop-and-session.md](react-loop-and-session.md)。

## 实现归属

| 层 | 负责 |
| --- | --- |
| `ap-core/tool` | `Tool`、`Tool_Context`、`Tool_Result`、`Registry`、参数助手、注册表过滤、`tool_execute` 与 blob 文本读取 |
| `ap-core/engine` | 按 step 串行执行、取消检查、写 `tool_execution_start` 与 `tool_execution_end`、blob 阈值、`fatal` 终止 turn、进度回调 |
| `ap-cli/tools` | 五个工具的实现、`Tool_Config`、进程树、子代理命令行与 stream-json 解析 |

SDK 不认识具体工具名、参数或子代理命令行。`Tool.user` 是宿主的 `Tool_Config` 指针，SDK 只透传。

## 公共约束

1. 一个 step 内的多个 tool call 按响应顺序串行执行，不并发。
2. 每次调用是无状态操作。不共享 cwd、环境变量或 shell 变量，`cd` 不跨调用生效。
3. `read_file` 单次最多 2000 行或 50KB，`bash` 单次最多 2000 行。`write_file`、`edit_file`、`task` 没有行数上限。
4. 单次结果超过 `blob_threshold_bytes` 时，完整内容写入 blob，transcript 只存预览和引用。blob 不改写模型已经拿到的结果，`bash` 的 2000 行分页发生在更早的工具层。
5. 单次捕获超过 `max_capture_bytes` 时终止工具并返回 `ok:false`，不做静默截断。
6. 工具失败只作为 tool result 交还模型。只有 `fatal=true` 的基础设施故障才终止 turn。
7. 相对路径相对 ap 启动目录。绝对路径可用。`~` 与 `~/...` 展开为主目录。不展开其它环境变量。Windows 上 `/` 与 `\` 都接受，但不接受 MSYS 的 `/z/...`。
8. `read_file` 的文本路径与 `edit_file` 只接受 UTF-8；`read_file` 的图片路径按格式识别并作为图片附件返回。`bash` 输出先做 UTF-8 清洗，非法字节替换为 `U+FFFD`。
9. 没有沙箱、审批或根目录限制。`--add-dir` 不存在。
10. agent 定义的 `tools:` 只决定注册给模型的工具，不是权限系统。只要 `bash` 还在白名单里，它仍拥有完整进程权限。

## 结果结构

这是 `tool_execute` 返回给 Loop 的内存结构，不是 transcript 事件。事件字段见 [react-loop-and-session.md](react-loop-and-session.md)。

```jsonc
// 成功
{"ok": true, "content": "<文本结果>", "images": [],
 "duration_ms": 12, "exit_code": 0, "metadata": null, "fatal": false}

// 失败
{"ok": false, "error": "<错误信息>", "images": [],
 "duration_ms": 3, "metadata": null, "fatal": false}
```

- `content` 是给模型的完整文本。落盘时超过阈值会替换成 `content_ref` 加预览。
- `images` 是图片附件列表，每项包含 `name`、`mime_type` 与原始字节。引擎把字节写入 blob 后释放，事件里只保留引用。
- `exit_code` 只由 `bash` 设置。
- `metadata` 只由 `task` 设置，内容见 [subagents.md](subagents.md)。
- `duration_ms` 由 `tool_execute` 统一计时。
- `fatal=true` 表示 spawn 失败、管道读写失败等基础设施故障。Loop 会额外写 `error(scope=tool)` 并终止 turn。普通工具错误保持 `false`。

## Blob

超过阈值的工具结果和工具参数写入 blob。blob 是存储优化，不是语义截断。

### 写入

1. 路径是 `$AP_CONFIG/projects/<project_hash>/blobs/<sha256>`。
2. 内容寻址。sha256 相同即去重，已存在时直接复用。
3. 先写同目录临时文件，`fsync`，关闭，再 rename 成最终文件。
4. 权限 0600，Windows 上由运行时尽力映射。
5. 先写完 blob，再追加引用它的事件。
6. 没有 GC。删除 blob 会让引用它的 transcript 无法完整恢复。

### 引用字段

| 内容 | 引用字段 |
| --- | --- |
| 工具结果 | `content_ref`、`content_bytes`、`content_preview` |
| 工具结果图片 | `images[].ref`、`images[].bytes`、`images[].mime_type` |
| 工具参数 | `args_ref`、`args_bytes`、`args_preview` |
| assistant 的 `tool_use.input` | `input_ref`、`input_bytes`、`input_preview` |
| assistant 文本块 | `text_ref`、`text_bytes`、`text_preview` |
| 新 session 的 system prompt | `session_start.content_ref`、`content_bytes` |

`content_ref` 是 blob 文件名，也就是 sha256 十六进制。读取方在 transcript 同目录的 `blobs/` 下解析。原文与引用字段二选一。预览最多取前 8192 字节，只用于人读，不得进入上下文。

### 读取

- 投影与恢复必须还原完整内容。
- blob 缺失、sha256 不匹配或权限错误都让恢复失败，退出 2。
- 工具执行过程中不读回 blob，内存里已有完整值。

### 失败

- 工具结果写 blob 失败时，该次工具返回 `ok:false`，错误为 `failed to persist output blob`，循环继续。
- 工具结果图片写 blob 失败时，该次工具返回 `ok:false`，错误为 `failed to persist image blob`，循环继续。
- 工具参数写 blob 失败时，终止当前 turn，写 `error(scope=session)`，跳过本 step 剩余 tool call，退出 4。
- 新 session 的 system prompt 写 blob 失败时，启动阶段退出 4。
- 常见原因是磁盘满或 `$AP_CONFIG` 不可写。

`bash` 超过 2000 行时还会另写 `<sha256>.txt`。它放在同一个 `blobs/` 目录，供模型用 `read_file` 续读。这个 `.txt` 文件不在 transcript 中引用。

## read_file

读取文件内容，或把图片作为多模态附件返回。行为对齐 pi 的 `read`。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `file_path` | 是 | 绝对路径或相对启动目录 |
| `offset` | 否 | 起始行号（从 1 开始），默认 1 |
| `limit` | 否 | 最多读取的行数，默认读到文件尾 |

行为：

1. 文本按原样返回，不加行号。未截断时保留文件末尾换行；CRLF 的行尾 `\r` 在输出中去掉。
2. 单次最多 2000 行或 50KB（与 `max_capture_bytes` 取小）。
3. 被行数截断时追加 `[Showing lines X-Y of Z. Use offset=N to continue.]`。
4. 被字节截断时追加 `[Showing lines X-Y of Z (<size> limit). Use offset=N to continue.]`。
5. 显式 `limit` 提前结束时追加 `[<n> more lines in file. Use offset=N to continue.]`。
6. 第一行就超过字节上限时，内容替换为 `[Line N is <size>, exceeds <limit> limit. Use bash: sed -n 'Np' <path> | head -c <bytes>]`。
7. `offset` 超出文件尾时返回 `ok:false`；`offset < 1` 或 `limit < 1` 同样失败。
8. 文件不存在、是目录或不是普通文件时返回 `ok:false`。
9. 读取到的行不是合法 UTF-8、含 NUL 或单行超过 `max_capture_bytes` 时返回 `ok:false`，提示改用 bash。
10. 行计数与 pi 一致：文件以换行结尾时不额外算一个空行。

### 图片

按魔数识别 PNG、JPEG、GIF、WebP。SVG 仍按文本文件读取。

1. `image_input = false`（默认）时，图片文件返回 `ok:false`，提示开启配置，不按二进制错误处理。
2. `image_input = true` 时，返回一行文本 `Read image file [<mime>]`，并把原始字节放进 `images`。`offset` / `limit` 对图片不生效。
3. 图片超过 `image_max_bytes`（默认 `5242880`）时返回 `ok:false`，不自动缩放或转码。
4. 只支持原样透传，不处理 EXIF 旋转、动画帧或色彩空间。
5. 引擎把图片写入 blob，`tool_execution_end.images` 只记录 `name`、`mime_type`、`ref` 与 `bytes`。投影时 provider 把图片展开成紧随 tool 消息的 user 消息；具体见 [provider.md](provider.md)。

示例：

```text
package engine

import "../platform"
```

## write_file

写入完整文件内容。行为对齐 pi 的 `write`。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `file_path` | 是 | 文件路径 |
| `content` | 是 | 完整文件内容 |

行为：

1. 父目录不存在时自动创建。
2. 内容原样写入，不做编码校验，也不转换换行符。
3. 先写同目录临时文件 `.ap-tmp-<pid>-<nano>`，`fsync`，关闭，再 rename 覆盖。Windows 的 rename 会替换已有文件。
4. 已有文件保留原权限位。新文件按默认权限创建。
5. 不备份、不保留原文件。
6. `content` 超过 `max_capture_bytes` 时返回 `ok:false`，不写文件。
7. 返回 `Successfully wrote to <path>`。

## edit_file

用 `edits` 里的精确文本替换编辑单个文件。行为对齐 pi 的 `edit`。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `file_path` | 是 | 文件路径 |
| `edits` | 是 | 至少一条 `{oldText, newText}` |
| `edits[].oldText` | 是 | 必须唯一、不重叠 |
| `edits[].newText` | 是 | 这条编辑的替换文本 |

行为：

1. 所有 `oldText` 都按原文件匹配，不是按前一条的结果递增匹配。
2. 精确匹配失败时做容错匹配：逐行去掉行尾空白，把弯引号、Unicode 破折号、特殊空格归一到 ASCII；全角 ASCII（`U+FF01..U+FF5E`）也归一。不做完整 NFKC。
3. 容错匹配只重写被改动的行，其余行原样保留。
4. 读入时去掉 BOM 再匹配，写回时按原文件恢复 BOM 与换行风格（`\r\n` 或 `\n`）。
5. `oldText` 为空时返回 `ok:false`，错误为 `oldText must not be empty in <path>.`。
6. `oldText` 匹配不到时返回 `ok:false`，不写文件。
7. 同一 `oldText` 匹配到多处时返回 `ok:false`，给出匹配次数并要求补充上下文。
8. 多条编辑的范围重叠时返回 `ok:false`，要求合并成一条。
9. 替换结果与原文相同时返回 `ok:false`。
10. 文件大于 `max_capture_bytes`、非 UTF-8 或目标是目录时返回 `ok:false`。
11. 写入方式与 `write_file` 相同：同目录临时文件、`fsync`、rename。
12. 返回 `Successfully replaced <N> block(s) in <path>.`。
13. 兼容宽松输入：`edits` 可以是 JSON 字符串；旧式顶层 `old_string`/`new_string`（或 `oldText`/`newText`）视为单条编辑。`replace_all` 不再支持。

### 与 pi 的有意差异

- 图片不缩放、不转码，也不识别 BMP；开关沿用 `image_input` 与 `image_max_bytes`。
- 容错匹配不做完整 NFKC，只覆盖全角 ASCII、弯引号、Unicode 破折号与特殊空格。
- `edit_file` 不生成 diff/patch，结果只有一行状态文本；ap 的 tool result 没有 details 通道。
- 写入仍走同目录临时文件 + `fsync` + rename，而不是直接覆盖。

## bash

执行 `bash -c <command>`。所有平台统一使用 Bash。启动时按 `AP_BASH`、PATH、常见安装位置查找，找不到时退出 2。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `command` | 是 | POSIX shell 命令，最多 8000 个字符 |
| `timeout_ms` | 否 | 超时毫秒数，默认取 `min(tool_timeout_ms, 600000)`，上限 600000 |

行为：

1. 每次调用是独立进程，不保留 cwd、环境变量或 shell 变量。默认 cwd 是启动目录。
2. stdin 接 `/dev/null`，Windows 上接 `NUL`，交互式命令会立即读到 EOF。
3. 继承 ap 的环境变量，但剔除 `AP_API_KEY`，并注入当前会话信息：

   | 变量 | 值 |
   | --- | --- |
   | `AP_SESSION_ID` | 当前 session id |
   | `AP_PARENT_SESSION_ID` | 父 session id；根 session 为空字符串 |
   | `AP_TRANSCRIPT_PATH` | 当前 transcript 的绝对路径 |

   这些变量只描述当前 bash 调用所属的会话，脚本只能读取。通过 `bash` 再启动 `ap` 时，新进程仍按自己的会话重新注入。继承来的同名变量会先被剔除，不会读到外层会话的陈旧值。
4. stdout 与 stderr 合并返回，两者顺序不保证。输出先做 UTF-8 清洗。
5. 结果首行是 `[exit <code>, <duration>ms]`。
6. 非 0 退出不算工具失败，返回 `ok:true` 和 `exit_code`，由模型判断。
7. 超时由 ap 控制。不要求在命令里调用 `timeout`。
8. `timeout_ms <= 0`、超过 600000、命令为空、命令超过 8000 个字符或超过 32000 字节时返回 `ok:false`。
9. 输出超过 `max_capture_bytes` 时终止整棵进程树，返回 `ok:false`，错误为 `output exceeded <max_capture_bytes> bytes`。
10. 输出超过 2000 行时只返回前 2000 行。完整输出写入 `blobs/<sha256>.txt`，结果末尾给出路径和 `read_file(..., offset=2001)` 续读提示。写入失败时保留前 2000 行并附错误信息。
11. 命令按 POSIX shell 语法编写。不保证 `cmd.exe` 或 PowerShell 的内置命令可用。

示例：

```text
[exit 0, 42ms]
 M ap-cli/options.odin
```

### 进程树

超时或取消时终止整棵进程树：

- Unix 通过 PPid 递归收集当前进程及其后代。先对快照发 `SIGTERM`，2 秒后发 `SIGKILL`。没有独立进程组。
- Windows 优先用 Job Object 的 `TerminateJobObject`。Job 不可用时退化为 `taskkill /PID <pid> /T /F`，最后再调用 `process_kill`。
- 正常返回时不立即终止残留后代。Windows 上没有残留后代的 Job 在调用结束时立刻归还句柄；仍有后台进程时继续登记，等 `cleanup_jobs` 在 ap 退出前统一终止。Unix 上没有运行期登记，ap 退出后不再跟踪后台后代。

需要长期驻留的后台进程时，写 wrapper 脚本，自己记录 pid 并负责停止。当前没有 `run_in_background`、`bash_output` 或 `kill_shell`。

Windows 上的 Bash 注意事项：

- 通过 bash 生成的脚本默认 LF。带 `#!` 的脚本必须保存为 LF，否则 Git Bash 报 bad interpreter。
- 盘符路径 `Z:/projects/ap` 与 `/z/projects/ap` 在 Git Bash 内都可用，但传给 ap 的文件工具时必须用 Win32 形式。
- `cd Z:` 不行，用 `cd /z/...` 或 `cd "Z:/..."`。

## task

启动一个独立 ap 子进程完成自包含任务。深度限制、启动协议和结果元数据见 [subagents.md](subagents.md)。这里列出工具侧参数和边界。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `prompt` | 是 | 子代理提示词，必须自包含 |
| `agent_name` | 否 | agent 名称，默认 `general` |
| `description` | 否 | schema 保留，当前实现不读取 |

行为：

1. `prompt` 为空时返回 `ok:false`。
2. 工具串行执行，因此同一时刻只有一个子代理。
3. 墙钟上限取 `task_timeout_ms`（默认 30 分钟）；超时终止子进程树并返回 `ok:false`。子代理自己的 `llm_timeout_ms` 和 bash 超时仍然生效。
4. 子代理输出超过 `max_capture_bytes` 时终止子进程树并返回 `ok:false`。提示词通过平台临时目录里的独占只读文件传给子进程（不落 cwd），调用结束即删除。
5. 返回的 `content` 是子代理最后一条含文本的 assistant 消息。其余元数据放进 `metadata`，字段见 [subagents.md](subagents.md)。
6. 子代理写文件不隔离，与父进程操作同一工作目录。

## 注册表与白名单

1. `ap-cli` 用 `aptools.builtin_tools(&Tool_Config)` 构造五个工具，按 `read_file`、`write_file`、`edit_file`、`bash`、`task` 的声明顺序显式传给 `apcore.env_open`。SDK 不使用全局可变注册表。
2. 注册时拒绝空工具名与重复工具名。
3. 注册表在 session 生命周期内不可变。白名单规则在应用层：agent 定义的 `tools:` 优先，缺省时使用全部已注册工具。
4. `tools:` 一旦出现就是显式白名单，即使值为空，也不会回退到全部工具。
5. `task` 在 `agent_depth >= max_agent_depth` 时从生效集合移除。移除发生在建 session 之前，因此 `session_start.tools` 直接反映最终结果。
6. 白名单里出现未知工具名时，新 session 启动失败，退出 2。
7. 恢复与 fork 以 `session_start.tools` 为准。冻结工具在当前注册表中不存在时跳过并 warning。
8. 工具 schema 由注册表生成，同时用于 system prompt 的工具段和 provider 请求的 `tools`。顺序按注册表声明顺序。工具 `description`、参数 `description` 与工具结果中的提示行都用英文并符合 ASD-STE100。

## 查看生效工具

使用 `--print-system-prompt`。其中 `## Tools` 小节按生效工具集生成，每个工具给出名称、说明和参数 JSON Schema。零工具时该节写 `(No tools are available)`，provider 请求也不发送 `tools` 字段。

## 相关文档

- [subagents.md](subagents.md)：`task` 的启动命令行、stdout 解析和结果契约。
- [errors-and-cancellation.md](errors-and-cancellation.md)：工具错误分类、取消和超时。
- [react-loop-and-session.md](react-loop-and-session.md)：`tool_execution_start` 与 `tool_execution_end` 的字段。
- [context-management.md](context-management.md)：工具段在 system prompt 中的位置。
- [cli-and-config.md](cli-and-config.md)：`tool_timeout_ms`、`task_timeout_ms`、`max_capture_bytes`、`max_agent_depth` 与 `--print-system-prompt`。
