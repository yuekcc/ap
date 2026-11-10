# 子代理

子代理（subagent）是一个独立的 ap 进程：独立上下文、独立 transcript、独立工具集，完成后只把最终结论交回父进程。
本文件定义 agent 定义文件、内置 `general`、启动命令行、stdout 消费规则和结果契约。`task` 的参数表见 [tools.md](tools.md)，agent 正文在 system prompt 中的位置见 [context-management.md](context-management.md)。

## 进程模型

`task` 属于应用层（`ap-cli/tools/tool_task.odin`）。子进程命令行、stream-json 解析、stderr 转发和结果组装都由应用层实现。SDK 只执行注册表里名为 `task` 的工具，不感知子代理机制。

用独立进程而不是同进程内的第二个循环，换来三点：子代理的探索过程不进入父 transcript，子代理崩溃或被取消时可以单独终止，父进程也复用同一套 CLI 和事件协议。

## 定义文件

位置是 `$AP_CONFIG/agents/<name>.md`。文件名就是 `agent_name`。

格式是简化的 frontmatter 加正文。frontmatter 按行解析 `key: value`，不使用完整 YAML：

```markdown
---
name: scout
description: 搜索代码库，回答“这个功能实现在哪”这类问题
tools: read_file, bash
model: <可选的 model_id>
max_steps: 30
---

你是一个搜索代理。用 bash 里的 grep 和 find 定位，用 read_file 确认。
最终回答必须给出具体的文件路径与行号。
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `name` | 是 | 必须与文件名一致 |
| `description` | 是 | 一句话说明何时该用它 |
| `tools` | 否 | 逗号分隔的工具白名单。缺省时使用全部已注册工具 |
| `model` | 否 | 直接运行该 agent 且命令行没有 `--model` 时覆盖 model。通过 `task` 启动时被子进程命令行覆盖 |
| `max_steps` | 否 | 直接运行该 agent 且命令行没有 `--max-steps` 时覆盖 step 上限。通过 `task` 启动时被子进程命令行覆盖 |

解析规则：

1. 文件必须以单独一行 `---` 开头。当前实现不跳过 UTF-8 BOM。
2. 结束行必须是 `---`，行尾的 `\r` 会被去掉。缺少结束行时退出 2。
3. frontmatter 内以 `#` 开头的行忽略。没有冒号的行忽略并 warning。
4. 只按第一个冒号分隔键和值。值两侧空白会去掉。
5. 值可以不加引号，也可以用单引号或双引号包裹。匹配的引号会去掉，双引号内不做转义还原。
6. `name` 与 `description` 缺失、`name` 与文件名不一致、文件不可读或不是合法 UTF-8 时，退出 2。
7. `max_steps` 必须是正整数，否则退出 2。
8. 未知字段忽略并 warning。`name`、`description`、`tools`、`model`、`max_steps` 以外的字段都算未知，例如 `max_tokens`。
9. `--agent` 的名称只接受字母、数字、`-`、`_`。空名称、`.` 和 `..` 非法。
10. 正文是结束 `---` 之后的全部内容，去掉开头的空行。正文为空是允许的。

正文作为 `## Agent 定义 (<name>)` 段落追加到 system prompt。它不替换固定指令、工具说明、环境或记忆。

## 工具集

子代理的工具集完全来自它自己的 agent 定义。父进程不传工具白名单，也不覆盖它。

1. `tools:` 存在时，只使用列出的工具。值为空时得到零工具。
2. `tools:` 不存在时，使用当前注册表的全部工具。
3. 列表中出现未知工具名时，子进程启动失败，退出 2。
4. `agent_depth >= max_agent_depth` 时，子进程在建 session 前从工具集移除 `task`，结果直接写入 `session_start.tools`。
5. 恢复或 fork 时以 `session_start.tools` 为准，不重新读取 agent 文件。

## 内置 general

只有 `general` 一个内置代理。

| 名称 | 工具 | 说明 |
| --- | --- | --- |
| `general` | 全部五个 | 默认值，适合多步骤搜索与修改 |

- `general` 没有正文，`model` 与 `max_steps` 为空。
- `$AP_CONFIG/agents/general.md` 存在时覆盖内置定义。
- `--agent` 指定的名称没有同名文件且不是 `general` 时，退出 2。
- 不内置 `explore`。需要更窄的工具集时，由用户自己写定义文件。

## 启动命令行

父进程执行 `task` 时组装以下命令：

```text
<self_exe> \
  --agent <agent_name> \
  --output-format stream-json \
  --print0 \
  --parent-session-id <parent_session_id> \
  --parent-tool-call-id <tool_call_id> \
  --agent-depth <parent_depth + 1> \
  --config-dir <parent_config_dir> \
  --model <parent_model> \
  --max-steps <parent_max_steps> \
  [--no-agents-md] \
  [--no-skills]
```

约定：

1. `<self_exe>` 优先取 `os.get_executable_path()`。失败时把 argv[0] 转成绝对路径。仍失败时使用原始 argv[0]。不经过 shell。
2. 不传 `--session`。子进程生成自己的 `session_id`。
3. 提示词通过 stdin 传给 `--print0`，不放在命令行里，避免 Windows 命令行长度限制。
4. cwd 是父 session 的项目根。`task` 不改变工作目录。
5. `$AP_CONFIG` 通过 `--config-dir` 显式继承。
6. 环境变量继承父进程，包括 `AP_API_KEY`。子进程需要它调用 LLM。
7. `--max-tokens` 不传，子进程使用自己的 `settings.json`。
8. 父进程开启 `--no-agents-md` 或 `--no-skills` 时，对应开关追加给子进程。父进程恢复 session 时这两个开关不生效，也不传播。
9. `$AP_CONFIG/SYSTEM.md` 由子进程按自己的 `--config-dir` 读取。基础段属于子代理自己的上下文，不从父进程复制。
10. 子进程按自己的启动目录重新发现技能。`task` 不改变 cwd，通常得到与父进程相同的清单。
11. 子进程的 `session_start` 写入 `parent_session_id`、`parent_tool_call_id` 和 `agent_depth`。
12. 子 transcript 与父 transcript 落在同一项目目录。

`model` 与 `max_steps` 的传参有一个实际效果需要说明。子进程收到的 `--model` 和 `--max-steps` 来自父 session 的生效值，而子进程的优先级是命令行 > agent 定义 > `settings.json`。因此由 `task` 拉起的子代理不会使用自己定义文件里的 `model` 与 `max_steps`。这两个字段只在该 agent 通过 `ap --agent <name>` 直接运行、且命令行没有覆盖时生效。

## 输出协议

子进程使用 `--output-format stream-json`。stdout 每行一个 JSON 对象，stderr 只放人类可读日志。

stdout 包含两类事件：

- 持久事件，带 `seq`：`session_start`、`user_message`、`turn_start`、`step_start`、`message_start`、`message_end`、`tool_execution_start`、`tool_execution_end`、`error`、`cancel`、`turn_end`、`session_end`。
- stream 事件，不带 `seq`：`message_update` 与 `tool_execution_update`。

父进程逐行解析 stdout：

1. 跨 `read` 的片段进入行缓冲。空行和无法解析的行直接跳过。
2. 收到 `session_start` 时，取其 `session_id` 作为 `child_session_id`。后到的会覆盖先到的。
3. `message_update.delta.text` 是文本增量。父进程按行加 `[subagent] ` 前缀转发到自己的 stderr，不写父 transcript。
4. `message_end` 且 `role=assistant` 且 `stop_reason` 不是 `cancelled` 时，把其中的文本块用换行连接，暂存为候选结果。`text_ref` 会先解析成完整文本。
5. `turn_end` 时记录 `stop_reason` 与 `usage`。
6. `error` 时记录最后一条错误消息。
7. `session_end` 只标记子进程正常收尾。
8. 子进程 stderr 原样转发到父 stderr，同时保留一个 8KB 环形缓冲，用于失败摘要。
9. `tool_execution_update` 不转发，父进程只展示子代理的文本和 stderr。

`message_update` 只用于实时展示。父进程的最终结果取自持久事件。

## 结果契约

子进程退出码为 0、收到 `session_start` 且收到 `session_end` 时，`task` 返回：

```jsonc
{
  "ok": true,
  "content": "<子代理最终回答>",
  "metadata": {
    "child_session_id": "ses_...",
    "stop_reason": "stop",
    "usage": {
      "input_tokens": 0,
      "output_tokens": 0,
      "cached_tokens": 0,
      "reasoning_tokens": 0,
      "total_tokens": 0
    },
    "duration_ms": 0
  }
}
```

- `content` 是最后一条含文本的 assistant 消息。所有 assistant 消息都没有文本时写 `(subagent returned no text)`。
- 父进程只把 `content` 放进 tool result 正文。其余字段进入 `tool_execution_end.metadata`。
- `stop_reason=max_steps` 仍算 `ok:true`，因为子进程正常退出。父进程模型根据 metadata 决定是否继续。
- 用户可以在同一项目内用 `ap -s <child_session_id>` 查看子 session 的完整过程。

## 深度、并发与失败

| 情况 | 行为 |
| --- | --- |
| 嵌套 | `max_agent_depth` 默认 1。达到上限时从工具集移除 `task`，直接调用也会返回 `max_agent_depth reached; task is not available` |
| 并发 | 父进程的工具串行执行，一次只跑一个子代理 |
| 超时 | 不设超时。子代理自己的 LLM 超时与 bash 超时仍然生效，父进程靠取消终止子进程树 |
| 子进程没写 `session_start` | `ok:false`，错误附 stderr 尾部最多 2000 字节，不伪造 `child_session_id` |
| 子进程退出码非 0 | `ok:false`，错误取最后一条 `error` 消息，没有时取 stderr 尾部 |
| 子进程没有 `session_end` | `ok:false`，错误为 `subagent exited without session_end` |
| spawn 或管道失败 | `ok:false` 且 `fatal=true`，Loop 终止 turn |
| 输出超过 `max_capture_bytes` | 终止子进程树，`ok:false` |
| 父进程被取消 | 先终止子进程树，再写父进程的 `cancel`、`tool_execution_end`、`turn_end` |
| 文件写入 | 不做隔离，与父进程操作同一工作目录 |
| 子代理恢复 | 允许，只在同一项目内使用 `-s <child_id>`，父链字段保留 |
| 子代理再调用 `task` | 未达深度上限时允许继续嵌套 |

## 相关文档

- [tools.md](tools.md)：`task` 的参数、结果结构和注册表过滤。
- [react-loop-and-session.md](react-loop-and-session.md)：事件字段与 session 冻结规则。
- [skills.md](skills.md)：子进程如何重新发现技能。
- [context-management.md](context-management.md)：agent 正文在 system prompt 中的位置。
- [errors-and-cancellation.md](errors-and-cancellation.md)：取消与进程树终止。
