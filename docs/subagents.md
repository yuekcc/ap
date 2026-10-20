# 子代理

子代理是一个独立的 ap 进程：独立上下文、独立 transcript、独立工具集，完成后只把最终结果交回父进程。

## 为什么用独立进程

1. **上下文隔离**：子代理的探索过程不污染父进程上下文，只回传结论
2. **崩溃隔离**：子代理 OOM 或死循环可以单独终止，父进程继续
3. **实现复用**：父进程用同一套 CLI 和事件协议拉起子进程，不需要第二套 agent 运行时

## 定义文件

位置：`$AP_CONFIG/agents/<name>.md`。文件名即 `agent_name`。

格式：YAML frontmatter + 正文。正文是该子代理 system prompt 的附加段落，不替换固定指令、工具说明、环境与记忆（见 [context-management.md](context-management.md)）。

```markdown
---
name: scout
description: 搜索代码库，回答「这个功能实现在哪」这类问题
tools: read_file, bash
model: <可选的 model_id，缺省继承父进程>
max_steps: 30
---

你是一个搜索代理。用 bash 里的 grep/find 定位，用 read_file 确认，
最终回答必须给出具体的文件路径与行号。
```

字段：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `name` | 是 | 必须与文件名一致 |
| `description` | 是 | 一句话说明何时该用它，父进程模型据此选择 |
| `tools` | 否 | 工具白名单，逗号分隔；缺省为全部五个工具 |
| `model` | 否 | 覆盖父进程传入的 model |
| `max_steps` | 否 | 覆盖父进程传入的 step 上限 |

约束：

1. 白名单只能包含 `read_file` / `write_file` / `edit_file` / `bash` / `task`
2. 未知工具名 → 启动失败，退出 2
3. `task` 在 `agent_depth >= max_agent_depth` 时从注册表移除，即使白名单里有
4. 未知 frontmatter 字段忽略并警告；`name` / `description` 缺失 → 退出 2

## 内置代理

只有 `general`：

| 名称 | 工具 | 说明 |
| --- | --- | --- |
| `general` | 全部五个 | 默认值，适合多步骤搜索 + 修改 |

- 不内置 `explore`；需要更窄的工具集时由用户自己写 agent 定义文件（示例见上）
- `general` 允许被 `$AP_CONFIG/agents/general.md` 覆盖
- `--agent` 指定不存在的名称且没有同名文件 → 退出 2

## 启动协议

父进程执行 `task` 时：

```
<self_exe> \
  --agent <agent_name> \
  --output-format stream-json \
  --print0 \
  --parent-session-id <parent_session_id> \
  --parent-tool-call-id <tool_call_id> \
  --agent-depth <parent_depth + 1> \
  --config-dir <parent_config_dir> \
  --model <effective_model> \
  --max-steps <effective_max_steps>
```

约定：

1. `<self_exe>` 用 `argv[0]` 解析成绝对路径：含分隔符的直接转绝对，裸名字则在 PATH 中查找；平台允许时可退化为 `os.get_executable_path()`；不经过 shell
2. **不传 `--session`**：子进程自己生成 `session_id`；父进程从子进程的第一条 `session_start` 读取 `child_session_id`
3. 提示词通过 stdin 传给 `--print0`，不放在命令行里，避免 Windows 命令行长度限制
4. 子进程不继承父进程的技能清单；它按自己的启动目录重新发现（`task` 不改变 cwd，通常得到同一份清单），见 [skills.md](skills.md)
5. cwd 继承父进程；不传 `--add-dir`
6. `$AP_CONFIG` 通过 `--config-dir` 显式继承
7. 环境变量继承父进程（包括 `AP_API_KEY`，子进程需要它调用 LLM）
8. `--model` 传父进程的生效 model；agent 定义里的 `model` 会覆盖它
9. `--max-steps` 传父进程的生效值；agent 定义里的 `max_steps` 会覆盖它
10. 子进程的 `session_start` 写入 `parent_session_id` / `parent_tool_call_id` / `agent_depth`
11. 子 transcript 与父 transcript 落在同一项目目录（cwd 相同）

## 输出协议

`--output-format stream-json`：stdout 每行一个 JSON 对象；stderr 只放人类可读日志。

stdout 包含：

- transcript 事件（带 `seq`）：所有持久事件，包括 `session_start` / `user_message` / `turn_start` / `step_start` / `message_start` / `message_end` / `tool_execution_start` / `tool_execution_end` / `error` / `cancel` / `turn_end` / `session_end`
- stream 事件（不带 `seq`）：`message_update` / `tool_execution_update`

父进程消费规则：

1. 逐行解析 stdout，跳过无法解析的行并计入 debug 日志；跨行缓冲必须保留
2. 第一条 `session_start` → 取 `session_id` 作为 `child_session_id`
3. `message_update` 的文本 delta → 转发到父进程 stderr，前缀 `[subagent]`；不写父 transcript
4. `message_end`（role=assistant）→ 暂存为候选结果
5. `turn_end` → 记录 `stop_reason` 与 usage
6. `session_end` + 子进程退出码 0 → 取最后一个 assistant 文本作为 `content`
7. 退出码非 0 → `ok:false`，`error` 取最后一条 `error` 事件或 stderr 尾部 2000 字符
8. 子进程 stderr 全部转发到父 stderr，同时保留一个 8KB 环形缓冲用于失败摘要
9. 没收到 `session_start` 就退出 → `ok:false`，不伪造 `child_session_id`

子进程必须保证 `stream-json` 下 stdout 只有 JSON 行，所有人类可读日志走 stderr。

## 结果契约

```jsonc
{
  "ok": true,
  "content": "<子代理最终回答>",
  "child_session_id": "<id>",
  "stop_reason": "stop",
  "usage": {"input_tokens": 0, "output_tokens": 0,
            "cached_tokens": 0, "reasoning_tokens": 0, "total_tokens": 0},
  "duration_ms": 0
}
```

父进程只把 `content` 放进 tool result 的正文；`child_session_id` / `stop_reason` / `usage` 放进 `tool_execution_end.metadata`，供用户和后续审计使用。用户可以用 `ap -s <child_session_id>` 在同一项目内查看完整过程。

`stop_reason=max_steps` 仍算 `ok:true`（子进程正常退出）；父进程模型根据 metadata 决定是否继续。

## 限制与失败处理

| 情况 | 行为 |
| --- | --- |
| 嵌套 | `max_agent_depth` 默认 1；子代理达到上限时工具集移除 `task` |
| 并发 | 串行，父进程一次只跑一个子代理 |
| 超时 | **不设超时**；子代理自己的 LLM 超时与 bash 超时仍然生效；父进程靠 SIGINT 取消 |
| 子代理失败 | `ok:false` + 错误摘要，父进程继续循环，由模型决定重试或改策略 |
| 父进程被中断 | 先终止子进程树，再记录父进程的 `cancel` / `tool_execution_end` / `turn_end` |
| 子代理写文件 | 不做隔离，与父进程操作同一工作目录（风险由用户承担） |
| 子代理自行恢复 | 允许，但只在同一项目内；`-s <child_id>`，父链字段保留 |
| 子代理调用 task | 达到深度上限时不可用；未达上限时可继续嵌套 |

## 未来

- 后台子代理：父进程不等结果，稍后取回
- 一次 `task` 并行多个子代理（与「工具串行」决策冲突，需要先改执行模型）
- session 列表与清理命令（v1 的 `-c` 已按 `parent_session_id` 排除子代理）
- 每个 agent 的工具白名单之外的运行预算
