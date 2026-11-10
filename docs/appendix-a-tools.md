# 附录 A：五个工具速查

ap 只有五个工具。模型能看到哪些工具由代理定义决定，但工具本身的能力不变。

## read_file

按行读取 UTF-8 文本文件，或把图片作为附件返回。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `file_path` | 是 | 绝对路径或相对启动目录 |
| `start_line` | 否 | 起始行号，包含该行，默认 1 |
| `end_line` | 否 | 结束行号，包含该行，默认起始行加 499 |

- 单次最多返回 2000 行。请求跨度更大时截断。
- 每行前面带实际行号。
- 文件还有更多行时，末尾提示下一页的 `start_line`。
- 只接受 UTF-8。遇到非 UTF-8、NUL 或超长行时失败，提示改用 `bash`。
- 图片需要 `image_input=true`。支持 PNG、JPEG、GIF、WebP；SVG 按文本读取。
- 图片默认上限 5 MiB，不缩放、不转码。

## write_file

写入完整文件内容。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `file_path` | 是 | 文件路径 |
| `content` | 是 | 完整文件内容 |

- 父目录不存在时自动创建。
- CRLF 归一为 LF。
- 先写同目录临时文件，fsync，再 rename 覆盖。
- 已有文件保留原权限位。
- 不备份、不保留原文件。覆盖就是覆盖。
- 内容超过 `max_capture_bytes` 时失败，不写文件。

## edit_file

把文件中的 `old_string` 替换成 `new_string`。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `file_path` | 是 | 文件路径 |
| `old_string` | 是 | 待替换文本，可跨行 |
| `new_string` | 是 | 新文本 |
| `replace_all` | 否 | 是否替换全部匹配，默认 `false` |

- 读入整份文件后先把 CRLF 归一为 LF。
- `old_string` 为空时失败。
- 0 处匹配时失败，提示先用 `read_file` 确认内容。
- 多处匹配且 `replace_all=false` 时失败，并给出匹配次数。
- 替换结果与原文相同时失败。
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
