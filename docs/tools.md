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
3. `read_file` 与 `bash` 各有 2000 行分页上限。`write_file`、`edit_file`、`task` 没有行数上限。
4. 单次结果超过 `blob_threshold_bytes` 时，完整内容写入 blob，transcript 只存预览和引用。blob 不改写模型已经拿到的结果，`bash` 的 2000 行分页发生在更早的工具层。
5. 单次捕获超过 `max_capture_bytes` 时终止工具并返回 `ok:false`，不做静默截断。
6. 工具失败只作为 tool result 交还模型。只有 `fatal=true` 的基础设施故障才终止 turn。
7. 相对路径相对 ap 启动目录。绝对路径可用。`~` 与 `~/...` 展开为主目录。不展开其它环境变量。Windows 上 `/` 与 `\` 都接受，但不接受 MSYS 的 `/z/...`。
8. `read_file` 与 `edit_file` 只接受 UTF-8。`bash` 输出先做 UTF-8 清洗，非法字节替换为 `U+FFFD`。
9. 没有沙箱、审批或根目录限制。`--add-dir` 不存在。
10. agent 定义的 `tools:` 只决定注册给模型的工具，不是权限系统。只要 `bash` 还在白名单里，它仍拥有完整进程权限。

## 结果结构

这是 `tool_execute` 返回给 Loop 的内存结构，不是 transcript 事件。事件字段见 [react-loop-and-session.md](react-loop-and-session.md)。

```jsonc
// 成功
{"ok": true, "content": "<文本结果>", "duration_ms": 12,
 "exit_code": 0, "metadata": null, "fatal": false}

// 失败
{"ok": false, "error": "<错误信息>", "duration_ms": 3,
 "metadata": null, "fatal": false}
```

- `content` 是给模型的完整文本。落盘时超过阈值会替换成 `content_ref` 加预览。
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
- 工具参数写 blob 失败时，终止当前 turn，写 `error(scope=session)`，跳过本 step 剩余 tool call，退出 4。
- 新 session 的 system prompt 写 blob 失败时，启动阶段退出 4。
- 常见原因是磁盘满或 `$AP_CONFIG` 不可写。

`bash` 超过 2000 行时还会另写 `<sha256>.txt`。它放在同一个 `blobs/` 目录，供模型用 `read_file` 续读。这个 `.txt` 文件不在 transcript 中引用。

## read_file

按行读取 UTF-8 文本文件。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `file_path` | 是 | 绝对路径或相对启动目录 |
| `start_line` | 否 | 起始行号，包含该行，默认 1 |
| `end_line` | 否 | 结束行号，包含该行，默认 `start_line + 499` |

行为：

1. 单次最多返回 2000 行。请求跨度更大时截到 2000 行，并追加 `[请求跨度超过 2000 行，已截断到 2000 行]`。
2. 结果首行是 `[<path> lines <start>-<end> of <total>]`。
3. 其后每行是 `<NNN>\t<content>`。`NNN` 是该行在文件中的实际行号，从 1 开始，不补零、不对齐。行号前缀计入 `max_capture_bytes`。
4. 文件还有更多行时，末尾追加 `[共 N 行，已返回 X-Y；继续请用 start_line=Y+1]`。
5. `start_line` 大于总行数时返回空内容和元信息，不报错。
6. `end_line` 超过文件尾时按实际行数返回。
7. `start_line < 1` 或 `end_line < start_line` 返回 `ok:false`。
8. 文件不存在、是目录或不是普通文件时返回 `ok:false`。
9. 读取到的行不是合法 UTF-8、含 NUL 或单行超过 `max_capture_bytes` 时返回 `ok:false`，提示改用 bash。
10. 本次请求的累计输出超过 `max_capture_bytes` 时返回 `ok:false`，提示缩小范围。

示例：

```text
[Z:/projects/ap/ap-core/engine/loop.odin lines 1-3 of 824]
1	package engine
2	
3	import "../platform"
```

## write_file

写入文本文件。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `file_path` | 是 | 文件路径 |
| `content` | 是 | 完整文件内容 |

行为：

1. 父目录不存在时自动创建。
2. 内容按 UTF-8 文本处理。实现不做编码校验，只把 CRLF 归一为 LF，其余字节原样写入。
3. 先写同目录临时文件 `.ap-tmp-<pid>-<nano>`，`fsync`，关闭，再 rename 覆盖。Windows 的 rename 会替换已有文件。
4. 已有文件保留原权限位。新文件按默认权限创建。
5. 不备份、不保留原文件。
6. `content` 超过 `max_capture_bytes` 时返回 `ok:false`，不写文件。
7. 返回 `wrote <bytes> bytes (<lines> lines) to <path>`。

## edit_file

把文件中的 `old_string` 替换为 `new_string`。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `file_path` | 是 | 文件路径 |
| `old_string` | 是 | 待替换文本，可跨行 |
| `new_string` | 是 | 新文本 |
| `replace_all` | 否 | 是否替换全部匹配，默认 `false` |

行为：

1. 读入整份文件后先把 CRLF 归一为 LF。替换结果原样写回，所以编辑 CRLF 文件会让旧内容整份变成 LF，`new_string` 中的换行则保持原样。
2. 文件大于 `max_capture_bytes` 时返回 `ok:false`，提示改用 bash。
3. 非 UTF-8 或目标是目录时返回 `ok:false`。
4. `old_string` 为空时返回 `ok:false`。
5. 0 处匹配时返回 `ok:false`，提示先用 `read_file` 确认内容，不写文件。
6. 多处匹配且 `replace_all=false` 时返回 `ok:false`，给出匹配次数。
7. 替换结果与原文相同时返回 `ok:false`，错误为 `replacement produced no change`。
8. 写入方式与 `write_file` 相同：同目录临时文件、`fsync`、rename。
9. 返回 `replaced <N> occurrence(s) in <path> (<lines> lines)`。

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
10. 输出超过 2000 行时只返回前 2000 行。完整输出写入 `blobs/<sha256>.txt`，结果末尾给出路径和 `read_file(..., start_line=2001)` 续读提示。写入失败时保留前 2000 行并附错误信息。
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
- 正常返回时不立即终止残留后代。Windows 上 Job 会在 turn 结束后由 `cleanup_jobs` 统一终止。Unix 上没有运行期登记，ap 退出后不再跟踪后台后代。

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
3. 不设超时。子代理自己的 `llm_timeout_ms` 和 bash 超时仍然生效，父进程靠取消终止子进程树。
4. 子代理输出超过 `max_capture_bytes` 时终止子进程树并返回 `ok:false`。
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
8. 工具 schema 由注册表生成，同时用于 system prompt 的工具段和 provider 请求的 `tools`。顺序按注册表声明顺序。

## 查看生效工具

使用 `--print-system-prompt`。其中 `## 工具` 小节按生效工具集生成，每个工具给出名称、说明和参数 JSON Schema。零工具时该节写 `（本次没有可用工具）`，provider 请求也不发送 `tools` 字段。

## 相关文档

- [subagents.md](subagents.md)：`task` 的启动命令行、stdout 解析和结果契约。
- [errors-and-cancellation.md](errors-and-cancellation.md)：工具错误分类、取消和超时。
- [react-loop-and-session.md](react-loop-and-session.md)：`tool_execution_start` 与 `tool_execution_end` 的字段。
- [context-management.md](context-management.md)：工具段在 system prompt 中的位置。
- [cli-and-config.md](cli-and-config.md)：`tool_timeout_ms`、`max_capture_bytes`、`max_agent_depth` 与 `--print-system-prompt`。
