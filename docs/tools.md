# 工具

v1 只有五个工具：`read_file`、`write_file`、`edit_file`、`bash`、`task`。没有 grep / glob / ls / webfetch / todo / 原生后台进程工具。

## 整体约束

1. **串行执行**：一个 step 中 LLM 返回多个 tool call 时，按响应顺序逐个执行，不并发
2. **无状态**：每次调用是独立操作，不共享 cwd、环境变量、shell 变量（`cd` 不跨调用生效）
3. **输出可见性**：`read_file` 与 `bash` 各自有 2000 行分页上限；其余工具结果不截断
4. **大输出写 blob**：单次结果超过 `blob_threshold_bytes`（默认 100KB）时，完整内容写入内容寻址 blob，transcript 只存预览与引用；这不改变模型已经拿到的结果（`bash` 可能已按行分页）
5. **硬上限保护进程**：单次捕获超过 `max_capture_bytes`（默认 64MB）时终止工具并返回 `ok:false`，不做静默截断
6. **工具失败不终止循环**：错误作为 tool result 交还 LLM 自行修正；只有 ap 自身基础设施故障才终止（见 [errors-and-cancellation.md](errors-and-cancellation.md)）
7. **路径**：相对路径只相对 ap 启动目录；绝对路径可用；`~` 与 `~/...` 展开为主目录；不展开其它环境变量；Windows 下 `/` 与 `\` 都接受；不接受 MSYS 的 `/z/...` 形式
8. **编码**：文件工具只支持 UTF-8；文本换行统一为 LF
9. **无沙箱**：工具没有根目录限制；`--add-dir` 不存在，绝对路径可以指向任何位置

## 结果结构

工具内部返回：

```jsonc
{"ok": true,  "content": "<文本结果>", "duration_ms": 12,
 "exit_code": 0, "metadata": null, "fatal": false}

{"ok": false, "error": "<错误信息>", "duration_ms": 3, "fatal": false}
```

- `content` 是完整内容；transcript 落盘时可能被替换成 `content_ref` + 预览
- `exit_code` 仅 `bash` 有
- `metadata` 仅 `task` 使用，写 `{child_session_id, stop_reason, usage, duration_ms}`
- `fatal=true` 表示 spawn 失败等基础设施故障；Loop 会额外写 `error(scope=tool)` 并终止 turn。普通工具错误保持 `false`

## Blob

超过阈值的工具结果或工具参数写入 blob，避免 transcript 膨胀。blob 不是语义截断。

`bash` 超过 2000 行时另写的 `<sha256>.txt` 放在同一 `blobs/` 目录，但它是给模型用 `read_file` 续读的分页产物，不写 transcript 引用。

### 写入

1. blob 路径：`$AP_CONFIG/projects/<project_hash>/blobs/<sha256>`
2. 内容寻址：sha256 相同即去重；已存在则直接复用
3. 先写临时文件、fsync、rename 成最终文件；权限 0600（Windows 尽力）
4. 先写完 blob，再追加引用它的事件
5. 不提供 GC；用户自行清理。删除 blob 会让引用它的 transcript 无法完整恢复

### 引用

事件字段：

```js
{
  content_ref: '<sha256>',
  content_bytes: 123456,
  content_preview: '<前 8KB>'
}
```

- `content_ref` 是 blob 文件名（sha256 hex），读取方在 transcript 同目录的 `blobs/` 下解析
- `content` 与 `content_ref` 二选一；超过阈值时 `content` 为空字符串或 null
- 工具参数同理：`args_ref` / `args_bytes` / `args_preview`
- assistant 的 `tool_use.input`：`input_ref` / `input_bytes` / `input_preview`
- 超大的文本块：`text_ref` / `text_bytes` / `text_preview`
- 超大的 system prompt：`session_start.content_ref` / `content_bytes`

### 读取

- 投影/恢复时必须还原完整内容；预览只用于人读，**不得进入上下文**
- blob 缺失、sha256 不匹配、权限错误 → 恢复失败，退出 2
- 工具执行过程中不读回 blob；内存里已有完整值

### 失败

- 工具结果写 blob 失败 → 该次工具返回 `ok:false`，错误说明 blob 写入失败，循环继续
- 工具参数（assistant 的 `tool_use.input` 或 `tool_execution_start.args`）写 blob 失败 → 终止当前 turn，写 `error(scope=session)`，退出 4
- 新 session 的 system prompt 写 blob 失败 → 启动阶段直接退出 4
- 原因通常是磁盘满、`$AP_CONFIG` 不可写

## read_file

按行读取 UTF-8 文本文件。

参数：

1. `file_path`：文件路径，绝对或相对启动目录
2. `start_line`：起始行号，包含该行，默认 1，最小 1
3. `end_line`：结束行号，包含该行，默认 `start_line + 499`

约束：

1. 单次最多返回 2000 行；请求跨度超过 2000 行时截到 2000 行，并追加提示
2. 文件还有更多行时，结果末尾追加：`[共 N 行，已返回 X-Y；继续请用 start_line=Y+1]`
3. `end_line` 超过文件尾时按实际行数返回，不报错
4. 结果首行固定为元信息：`[<path> lines <start>-<end> of <total>]`
5. 只支持 UTF-8；非 UTF-8 或二进制文件返回 `ok:false`，提示用 bash 处理
6. 换行统一为 LF
7. 文件不存在 / 无权限 / 是目录 → `ok:false`，错误信息说明原因
8. `start_line` 大于文件总行数 → 返回空内容 + 元信息，不报错
9. 单行本身超过 `max_capture_bytes` → `ok:false`，不返回半行

示例：

```
read_file(file_path="cli/main.odin", start_line=1, end_line=500)
```

`read_file` 与 `bash` 的 2000 行分页是唯一的范围限制；`bash` 超出部分写入 `.txt`，模型用 `read_file` 继续读。

## write_file

写入文本文件。

参数：

1. `file_path`：文件路径
2. `content`：完整文本内容

约束：

1. 只支持 UTF-8；内容中的 CRLF 统一为 LF
2. 先写同目录临时文件，fsync，再 rename 覆盖；Windows 使用 `MoveFileExW(..., MOVEFILE_REPLACE_EXISTING)`
3. 父目录不存在时自动创建
4. 不备份、不保留原文件；直接覆盖（无审批设计下的既定行为）
5. 已有文件保留原权限位；新文件按 umask 创建
6. 返回写入字节数与行数
7. `content` 超过 `max_capture_bytes` → `ok:false`，不写文件

示例：

```
write_file(file_path="cli/main.odin", content="...")
```

## edit_file

把文件中的 `old_string` 替换为 `new_string`。

参数：

1. `file_path`：文件路径
2. `old_string`：待替换文本，支持跨行
3. `new_string`：新文本
4. `replace_all`：是否替换全部匹配，默认 false

约束：

1. 只支持 UTF-8
2. 读取时统一 CRLF → LF，写回也是 LF（**副作用**：编辑 CRLF 文件会整文件变 LF）
3. 先写同目录临时文件，fsync，再 rename
4. `old_string` 为空 → `ok:false`
5. 0 处匹配 → `ok:false`，提示「先用 read_file 确认文件内容」，不写文件
6. 多处匹配且 `replace_all=false` → `ok:false`，给出匹配次数，提示补充上下文或显式 `replace_all=true`
7. 文件大于 `max_capture_bytes` → `ok:false`，提示改用 bash
8. 替换后内容与原文相同 → `ok:false`（`replacement produced no change`）
9. 返回实际替换次数

示例：

```
edit_file(file_path="cli/main.odin", old_string="foo", new_string="bar", replace_all=false)
```

## bash

执行 `bash -c <command>`。所有平台统一使用 Bash：Windows 上通过 Git for Windows 的 `bash.exe`（启动时从 PATH 解析，找不到则退出 2）。

参数：

1. `command`：待执行命令，最多 8000 字符
2. `timeout_ms`：超时毫秒数，默认 `tool_timeout_ms`（120000），上限 600000；超过上限返回 `ok:false` 参数错误

约束：

1. 每次调用是独立进程，不保留 cwd / 环境变量 / shell 变量
2. 默认 cwd 为 ap 启动目录；没有 `--add-dir`
3. stdin 接 `/dev/null`（Windows 为 `NUL`），交互式命令会立即读到 EOF
4. 继承 ap 的环境变量，但剔除 `AP_API_KEY`，避免密钥泄露给模型可控命令
5. stdout 与 stderr 合并返回；两者顺序不保证
6. 结果首行：`[exit <code>, <duration>ms]`
7. 非 0 退出不算工具失败：返回 `ok:true` + `exit_code`，由模型判断
8. **超时由 ap 控制**：不要求在命令里调用 `timeout`；Windows 的 `timeout.exe` 语义不同
9. 超时/取消时终止整棵进程树：
   - Unix：通过 PPid 递归扫描当前进程的后代；先对快照发 `SIGTERM`，2s 后发 `SIGKILL`。没有独立进程组
   - Windows：Job Object 或 `taskkill /T /F`；实现方式见 [architecture.md](architecture.md)
10. 正常返回时**不**终止残留后代进程。Windows 上 Job 会登记，ap 退出时统一 `TerminateJobObject`；Unix 上没有运行期登记，ap 退出时不会再次清理正常返回后的后台后代。后台进程请用 wrapper 脚本 + pid 文件管理
11. 输出超过 `max_capture_bytes` → 终止进程树，返回 `ok:false`，错误为 `output exceeded <max_capture_bytes> bytes`
12. 输出超过 2000 行 → 只返回前 2000 行；完整输出写入 `$AP_CONFIG/projects/<project_hash>/blobs/<sha256>.txt`，结果末尾提示用 `read_file(file_path=..., start_line=2001)` 继续读；写入失败时保留前 2000 行并附错误信息
13. 命令按 POSIX shell 语法编写；不保证 `cmd.exe` / PowerShell 内置命令可用

示例：

```
bash(command="git status --short", timeout_ms=120000)
```

Windows 已知坑（不做特殊处理，写进文档避免模型反复踩）：

- 通过 bash 生成的脚本默认 LF；被 Windows 原生工具读取时可能需要 CRLF
- 带 `#!` shebang 的脚本必须保存为 LF，否则 Git Bash 报 bad interpreter
- 盘符路径 `Z:/projects/ap` 与 `/z/projects/ap` 在 Git Bash 内都可用，但传给 ap 的文件工具时必须用 Win32 形式
- `cd Z:` 不行；用 `cd /z/...` 或 `cd "Z:/..."`

后台运行（v1 不提供原生后台工具）：

- 长驻进程写成 wrapper 脚本：启动、写 pid 文件、提供停止入口
- Windows 上本次运行启动的 Job 会在 ap 退出时统一终止；Unix 上正常返回后 ap 不再跟踪后代，需要 wrapper 自己负责停止
- 原生 `run_in_background` / `bash_output` / `kill_shell` 留到后续版本

## task

启动一个子代理完成特定任务。

参数：

1. `prompt`：子代理的提示词，**必须自包含**（子代理看不到父进程上下文）
2. `agent_name`：子代理名称，默认 `general`
3. `description`：3-5 词的任务概括，用于展示进度

约束：

1. 子代理通过启动新的 ap 进程实现，使用独立的 session
2. 子代理继承父进程 cwd 与 `$AP_CONFIG`；不传 `--add-dir`
3. 启动命令见 [subagents.md](subagents.md)：传 `--parent-session-id`、`--parent-tool-call-id`、`--agent-depth`，**不传 `--session`**
4. 子进程自己生成 `session_id`；父进程从第一条 `session_start` 读取 `child_session_id`
5. 最大嵌套深度由 `max_agent_depth` 控制；达到上限时子代理的工具集里移除 `task`
6. 串行：同一时刻只运行一个子代理
7. **不设超时**：`task` 不受 `tool_timeout_ms` 约束；子代理自己的 `llm_timeout_ms` 与 bash 超时仍然生效；父进程靠 SIGINT 取消
8. 执行期间子代理的文本增量实时转发到父进程 stderr；不写父 transcript
9. 返回：最终文本 + `child_session_id` + `stop_reason` + `usage` + `duration_ms`；写入 `tool_execution_end.metadata`
10. 子代理异常退出时返回 `ok:false` + 错误摘要 + stderr 尾部（最多 2000 字符）
11. 子代理写文件不隔离，与父进程操作同一工作目录
12. 工具白名单由 agent 定义文件控制，是当前唯一的能力隔离手段

示例：

```
task(prompt="找出 config 加载路径并给出文件与行号", agent_name="general", description="定位配置加载")
```

## 工具注册

1. 五个工具始终注册，除非被 agent 白名单排除
2. `task` 在 `agent_depth >= max_agent_depth` 时从注册表移除
3. 白名单里出现未知工具名 → 启动失败，退出 2
4. 工具 schema 由 Registry 生成，作为 system prompt 的工具说明与 provider 请求的 `tools` 来源

## 候选工具（v1 不做）

| 工具 | 理由 |
| --- | --- |
| grep / glob / ls | 用 bash 覆盖，减少 schema 与实现量 |
| webfetch / websearch | 网络出口与缓存策略另开一章 |
| todo_write | CLI 下用文本计划替代 |
| 原生后台 bash | 需要进程管理工具族；v1 用 wrapper 脚本 |
| 并行工具 | v1 串行；transcript 已按 `tool_call_id` 关联，后续可扩展 |
