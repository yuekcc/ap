# 18. 命令与参数速查

这一章只列事实，不解释用法。需要步骤时回到前面的章节。

## ap

```text
ap [options]
```

| 参数 | 值 | 作用 |
| --- | --- | --- |
| `-h`, `--help` | — | 打印用法，退出 0 |
| `--version` | — | 打印版本，退出 0 |
| `-s`, `--session <id>` | session id | 恢复当前项目内的指定会话 |
| `-c`, `--continue` | — | 恢复当前项目内最近的根会话 |
| `--fork-session` | — | 与 `-s` 或 `-c` 连用，复制历史到新会话 |
| `--agent <name>` | 代理名 | 使用 `$AP_CONFIG/agents/<name>.md`，默认 `general` |
| `-p`, `--print <prompt>` | 提示词 | 直接提供提示词 |
| `--input-file <path>` | 文件路径 | 从 UTF-8 文件读取提示词 |
| `--print0` | — | 从 fd 0 读取提示词直到 EOF |
| `--config-dir <path>` | 目录 | 设置配置根目录，默认 `~/.ap` |
| `--model <id>` | 模型 id | 覆盖模型 |
| `--max-steps <n>` | 正整数 | 单个 turn 的最大 step 数 |
| `--max-tokens <n>` | 正整数 | 单次响应的 `max_tokens` |
| `--context-window <n>` | 非负整数 | 覆盖上下文窗口；`0` 关闭预算和自动交接 |
| `--handoff [提示词]` | 可选文本 | 生成交接文档并创建新会话 |
| `--no-handoff` | — | 关闭自动交接 |
| `--output-format <fmt>` | `text`、`json`、`stream-json` | 输出格式，默认 `text` |
| `--no-agents-md` | — | 不注入全局和项目 `AGENTS.md` |
| `--no-skills` | — | 不扫描、不注入技能清单 |
| `--print-system-prompt` | — | 打印本次 system prompt 后退出 |
| `--list-skills` | — | 列出当前目录可见的技能后退出 |
| `--verbose` | — | 输出 info 及更高级别日志 |
| `--debug` | — | 输出 debug 及更高级别日志 |
| `--parent-session-id <id>` | session id | 标记当前进程是子代理，内部使用 |
| `--parent-tool-call-id <id>` | tool call id | 父进程中的 `task` 调用，内部使用 |
| `--agent-depth <n>` | 非负整数 | 当前代理深度，内部使用 |

约束：

- 带值的长参数支持 `--flag value` 和 `--flag=value`。`-s` 和 `-p` 只接受分开的值。
- `--` 和位置参数会被拒绝。
- `-s` 与 `-c` 互斥。
- `--fork-session` 必须与 `-s` 或 `-c` 连用。
- `--handoff` 必须与 `-s`、`-c` 或 `--fork-session` 之一连用，与 `--print-system-prompt` 和 `--no-handoff` 互斥。源会话必须至少有一条用户消息。
- `--parent-tool-call-id` 必须与 `--parent-session-id` 同时使用。
- `--max-steps` 和 `--max-tokens` 必须是正整数。`--context-window` 必须是非负整数。
- 参数非法、缺值或冲突时退出 2。

提示词来源三选一：`--print`、`--input-file`、`--print0`。同时给多个退出 2，一个都不给也退出 2。`--help`、`--version`、`--list-skills`、`--print-system-prompt` 不需要提示词。

## 输出格式

| 格式 | stdout |
| --- | --- |
| `text` | 最后一条含文本的 assistant 消息 |
| `json` | 单个结果对象 |
| `stream-json` | 每行一个事件 |

`stream-json` 同时包含持久事件和流式增量。持久事件带 `v`、`seq`、`ts`、`type`；流式增量不带。

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 正常结束，包括 `max_steps`、`max_tokens`、`handoff` |
| 1 | 内部错误 |
| 2 | 用法、配置或恢复错误 |
| 3 | 模型接口错误，或关闭交接后的上下文超限 |
| 4 | 工具基础设施故障 |
| 130 | SIGINT 或 Ctrl+C |
| 143 | SIGTERM |

## ap-tui

```text
ap-tui [options]
```

| 参数 | 作用 |
| --- | --- |
| `-c`, `--continue` | 恢复当前项目最近的根会话 |
| `-s`, `--session <id>` | 恢复指定会话，启动前校验文件存在 |
| `--agent-bin <path>` | 指定 `ap` 可执行文件 |
| `--config-dir <dir>` | 传给 `ap` 的配置目录 |
| `--model <id>` | 传给 `ap --model` |
| `--agent <name>` | 传给 `ap --agent` |
| `--max-steps <n>` | 传给 `ap --max-steps`，必须是正整数 |
| `--max-tokens <n>` | 传给 `ap --max-tokens`，必须是正整数 |
| `--verbose` | 实时显示 `ap` 的 stderr |
| `--no-color` | 关闭 ANSI 颜色 |
| `-h`, `--help` | 显示帮助 |
| `--version` | 显示版本 |

`-s` 和 `-c` 互斥。工作目录固定为启动时定位到的项目根目录。启动失败统一返回 2。

## ap-web

```text
ap-web [--port 8417] [--host 127.0.0.1] [--web-root <dir>]
       [--agent-bin <path>] [-s <id>] [-c] [--model ...] [--agent ...]
       [--max-steps ...] [--max-tokens ...] [--config-dir <dir>] [--cwd <dir>]
```

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--port <n>` | `8417` | 监听端口，范围 1 到 65535 |
| `--host <addr>` | `127.0.0.1` | 监听地址。非回环地址会打印安全警告 |
| `--web-root <dir>` | 空 | 非空时静态资源从磁盘读取 |
| `--agent-bin <path>` | 空 | 指定 `ap` 可执行文件 |
| `--config-dir <dir>` | `~/.ap` | 传给 `ap` 的配置目录 |
| `--model <id>` | 空 | 传给 `ap --model` |
| `--agent <name>` | 空 | 传给 `ap --agent` |
| `--max-steps <n>` | 空 | 传给 `ap --max-steps` |
| `--max-tokens <n>` | 空 | 传给 `ap --max-tokens` |
| `--cwd <dir>` | 启动目录 | 初始工作目录，同时作为默认项目 |
| `-c`, `--continue` | 关 | 恢复当前项目最近的根会话 |
| `-s`, `--session <id>` | 空 | 恢复指定会话 |
| `-h`, `--help` | — | 显示帮助 |
| `--version` | — | 显示版本 |

`-s` 和 `-c` 互斥。`ap-web` 不暴露 `--no-agents-md` 和 `--no-skills`。

## 环境变量

| 变量 | 作用 |
| --- | --- |
| `AP_CONFIG` | 配置根目录，默认 `~/.ap`。`--config-dir` 优先 |
| `AP_API_KEY` | 覆盖配置文件中的 `api_key` |
| `AP_BASH` | 指定 bash 可执行文件的绝对路径 |
| `NO_COLOR` | 非空时关闭 `text` 模式 stderr 的 ANSI 颜色 |

`bash` 工具还会向子进程注入只读变量：`AP_SESSION_ID`、`AP_PARENT_SESSION_ID`、`AP_TRANSCRIPT_PATH`。它们只描述当前会话，不参与进程间通信。
