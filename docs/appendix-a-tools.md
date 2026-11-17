# 附录 A：五个工具速查

ap 只有五个工具。模型能看到哪些工具由代理定义决定，但工具本身的能力不变。

## read_file

读取文件内容，或把图片作为附件返回。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `file_path` | 是 | 绝对路径或相对启动目录 |
| `offset` | 否 | 起始行号（从 1 开始），默认 1 |
| `limit` | 否 | 最多读取的行数，默认读到文件尾 |

- 文本按原样返回，不加行号，行尾的 `\r` 会去掉；未截断时保留文件末尾换行。
- 单次最多 2000 行或 50KB（先到者为准）。被行数截断时末尾提示 `[Showing lines X-Y of Z. Use offset=N to continue.]`，被字节截断时提示里带实际上限。
- 显式 `limit` 提前结束时，末尾提示剩余行数和下一个 `offset`。
- `offset` 超出文件尾时失败。
- 第一行就超过字节上限时，返回 `sed -n '<offset>p' <path> | head -c <N>` 的 bash 兜底提示。
- 只接受 UTF-8。遇到非 UTF-8、NUL 或超长行时失败，提示改用 `bash`。
- 图片需要 `image_input=true`。支持 PNG、JPEG、GIF、WebP；SVG 按文本读取。
- 图片默认上限 5 MiB，不缩放、不转码。

## write_file

写入完整文件内容。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `file_path` | 是 | 文件路径 |
| `content` | 是 | 完整文件内容 |

- 内容原样写入，不转换换行符。
- 父目录不存在时自动创建。
- 先写同目录临时文件，fsync，再 rename 覆盖。
- 已有文件保留原权限位。
- 不备份、不保留原文件。覆盖就是覆盖。
- 内容超过 `max_capture_bytes` 时失败，不写文件。

## edit_file

用 `edits` 中的精确文本替换编辑单个文件。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `file_path` | 是 | 文件路径 |
| `edits` | 是 | 至少一条 `{oldText, newText}`，所有条目都按原文件匹配 |
| `edits[].oldText` | 是 | 必须唯一、不重叠，且不能为大段未变内容 |
| `edits[].newText` | 是 | 这条编辑的替换文本 |

- 所有 `oldText` 都对同一份原文匹配，不是按前一条的结果递增匹配。
- 精确匹配失败时做容错匹配：忽略行尾空白，把弯引号、Unicode 破折号、特殊空格和全角 ASCII 归一到 ASCII；未改动的行原样保留。
- 保留文件原有的 BOM 和换行风格。
- `oldText` 为空、匹配不到、匹配到多处或彼此重叠时失败。
- 替换结果与原文相同时失败。
- 为了兼容旧调用，也接受顶层 `old_string`/`new_string`（或 `oldText`/`newText`）作为单条编辑，以及字符串形式的 `edits`。
- 大于 `max_capture_bytes` 的文件失败，提示改用 `bash`。

## bash

执行 `bash -c <command>`。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `command` | 是 | POSIX shell 命令，最多 8000 个字符 |
| `timeout_ms` | 否 | 超时毫秒数，默认 `min(tool_timeout_ms, 600000)`，上限 600000 |

- 每次调用是独立进程，不保留 cwd、环境变量或 shell 变量。
- 默认 cwd 是启动目录。
- stdin 接 `/dev/null`，Windows 上接 `NUL`。交互式命令会立即读到 EOF。
- 继承 ap 的环境变量，但剔除 `AP_API_KEY`。
- 注入 `AP_SESSION_ID`、`AP_PARENT_SESSION_ID`、`AP_TRANSCRIPT_PATH`。
- stdout 和 stderr 合并返回，顺序不保证。
- 非 0 退出不算工具失败，返回 `ok:true` 和真实退出码。
- 输出超过 2000 行时只返回前 2000 行，完整输出写到 `blobs/<sha256>.txt`。
- 超时或取消会终止整棵进程树。
- 没有 `run_in_background`、`bash_output` 或 `kill_shell`。需要后台进程时自己写 wrapper 脚本管理 pid。

## task

启动一个独立 ap 子进程完成自包含任务。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `prompt` | 是 | 子代理提示词，必须自包含 |
| `agent_name` | 否 | 代理名，默认 `general` |
| `description` | 否 | 保留字段，当前不读取 |

- 父进程的工具串行执行，同一时刻只有一个子代理。
- 子代理有独立上下文和独立 transcript。
- 父进程只把子代理最后一条含文本的回答放进工具结果。
- 子代理写文件不隔离，和父进程操作同一工作目录。
- 不设 task 超时。子代理自己的 LLM 超时和 bash 超时仍然生效。
- 默认最大嵌套深度是 1。达到上限时 `task` 不可用。
- 子代理的完整过程可以用 `ap -s <child_session_id>` 查看。

## 工具白名单

代理定义里的 `tools:` 只决定模型能看到哪些工具，不是权限系统。

只要 `bash` 还在白名单里，代理就拥有完整的进程权限。需要只读代理时，只保留 `read_file`，或者同时保留 `read_file` 和 `bash` 但明确写清“只读，不要修改”。
