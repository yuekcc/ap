# 变更记录：上下文与工具的命令行开关

状态：**部分落地，部分被取代，部分未实现**。当前行为以 [cli-and-config.md](../cli-and-config.md) 为准。本文记录当时为什么提出这组开关，以及最终哪些留下、哪些没有。

## 结论

| 提案项 | 当前状态 | 依据 |
| --- | --- | --- |
| `--no-agents-md` | 已落地 | `ap-cli/options.odin`、`ap-cli/run.odin` |
| `--no-skills` | 已落地 | 同上 |
| 删除 `--workspace` | 已落地 | 现在作为未知参数退出码 2 |
| `session_start.tools` 冻结工具集 | 已落地 | `ap-core/protocol/events.odin`、`ap-core/engine/session.odin` |
| `--print-system-prompt` 输出 warning | 已落地 | `ap-cli/run.odin` |
| 提示词文本规范化 | 已落地，但入口是 `$AP_CONFIG/SYSTEM.md` | `ap-cli/options.odin` |
| `--base-system-prompt` | 未实现，参数被拒绝 | `parse_args` 返回退出码 2 |
| `--base-system-prompt-file` | 未实现，参数被拒绝 | 同上 |
| `--append-system-prompt` | 未实现，参数被拒绝 | 同上 |
| `--tools` | 未实现，参数被拒绝 | 同上 |
| `--list-tools` | 未实现，参数被拒绝 | 同上 |
| 子代理传播 `--no-agents-md` / `--no-skills` | 已落地 | `ap-cli/tools/tool_task.odin` |

`ap-cli/options_test.odin` 直接断言这些未实现的参数会返回 `.Usage`，帮助文本也不包含它们。不要把本文中的参数当作当前可用开关。

## 当时的问题

在这组开关出现之前，新 session 的上下文由固定规则决定：技能清单默认扫描，记忆文件按规则注入，system prompt 的第一段总是内置文本，工具集只来自 agent 定义或默认全量。用户没有办法在不改配置文件、不改 agent 定义的情况下裁掉一部分上下文，也没有命令能确认某个 agent 最终会拿到哪些工具。

`--workspace` 是另一个问题。它只是 `--config-dir` 的别名，名字却容易被理解成项目根目录。两个概念混在一个参数里，恢复项目和恢复 session 时都会误判。

提案试图用一组运行级开关解决这些问题，同时把生效工具集写进 `session_start`，让恢复不再依赖当前 agent 文件。

## 当时的方案

提案设计了两类开关。

上下文类：

- `--base-system-prompt` / `--base-system-prompt-file` 只替换内置固定指令段，保留工具、环境、技能、记忆、agent 定义与追加指令。
- `--no-agents-md` 跳过全局与项目记忆。
- `--no-skills` 跳过技能扫描与清单注入。
- `--append-system-prompt` 仍排在最后。

工具类：

- `--tools <list>` 覆盖 agent 定义中的工具白名单，支持 `all` 与 `none`。
- `--list-tools` 打印声明工具集后退出，不读配置、不建 session。

配套规则包括：新 session 把生效工具集冻结进 `session_start.tools`，恢复时忽略冲突参数并 warning，子代理继承父进程的裁剪与工具限制。

这套设计的核心判断是：上下文与工具都是运行级策略，不应只藏在文件里。下面看这个判断最后怎样落到代码。

## 落地结果

保留下来的部分有一个共同点：它们只跳过既有段落，不改变段落的来源和拼接格式。

`--no-agents-md` 与 `--no-skills` 是布尔值，不接受内联值。它们只参与新 session 的 sections 组装。恢复时这两个参数没有效果，也没有 warning，因为恢复根本不重建 prompt。实际行为与提案第 4.7 节的 warning 列表不同，以 [cli-and-config.md](../cli-and-config.md) 为准。

`--workspace` 已经删除。现在传入它会得到未知参数错误。

`session_start.tools` 已经落地，类型是 `Maybe([]string)`。新 session 写入生效后的声明工具集。恢复时以冻结值为准，冻结列表里当前注册表不存在的工具名会跳过并 warning。旧 transcript 没有 `tools` 字段时，使用当前注册表的全部工具并 warning。这条规则让修改 agent 文件不再影响已有 session。

`--print-system-prompt` 在恢复或 fork 时会把 `resolve_session` 的 warning 写到 stderr。新 session 仍打印完整组装结果。

## 被取代的部分

基础提示词覆盖没有采用命令行参数，而是落在配置文件约定上：`$AP_CONFIG/SYSTEM.md` 存在时替换内置固定指令段。文件内容走与提案相同的规范化规则：CRLF 与单独 CR 转 LF，去首尾空白，结尾恰好一个换行，内部空行与缩进保留。文件为空、不是 UTF-8 或只有空白时退出码 2。

这个入口与提案的参数有三点不同：

- 文本放在配置目录，不受命令行长度限制。
- 只能整段替换，不能同时给多个来源。
- 恢复时不会重新读取。已有 session 使用冻结 prompt。

`--append-system-prompt` 也没有落地。当前文档给出的追加方式是写 `~/.agents/AGENTS.md` 或项目 `AGENTS.md`。应用层的 `Prompt_Options.append_prompt` 字段仍然存在，但 `run` 不设置它，正常运行时不会出现「追加指令」一节。

`--tools` 与 `--list-tools` 都没有落地。工具集仍按以下顺序决定：

```text
agent 定义中的 tools:  >  全部已注册工具
task 在 agent_depth >= max_agent_depth 时移除
```

`--tools all`、`--tools none` 和工具白名单覆盖都不存在。`ap-cli/tools/config.odin` 保留了 `tools_set` 与 `tools` 两个字段，但当前没有任何 CLI 路径写入它们。这是提案留下的未使用结构，不是可用功能。

## 与提案文本的其他差异

提案写作时，CLI 代码还叫 `ap-core/cli.odin`、`ap-core/run.odin`、`ap-core/app.odin`。现在这些职责在 `ap-cli/options.odin`、`ap-cli/run.odin`、`ap-cli/app.odin`，工具在 `ap-cli/tools/`。阅读旧路径时按当前包布局换算。

提案把全局记忆写成 `$AP_CONFIG/AGENTS.md`。当前实现读取 `~/.agents/AGENTS.md`，项目记忆从启动目录向上发现。关闭开关覆盖这两个来源，但路径本身与提案不同。

提案中的恢复 warning 列表包括 `--no-agents-md`、`--no-skills`、`--tools`。当前只有真正传给 SDK 的冲突输入才产生 warning。CLI 在恢复路径不会传 `--no-agents-md`、`--no-skills` 或工具集，因此这三个参数不会触发 warning。

## 迁移与现状

当前用户能做的是：

- 用 `$AP_CONFIG/SYSTEM.md` 替换基础提示词段。
- 用 `--no-agents-md` 关闭记忆注入。
- 用 `--no-skills` 关闭技能清单。
- 用 agent 定义文件控制工具集。
- 用 `--print-system-prompt` 查看完整结果。

想限制工具时，只能改 agent 定义。想追加提示词时，写 `AGENTS.md`。这两个替代方案都不提供运行级覆盖，也不改变已冻结 session。

如果以后要补完 `--tools` / `--list-tools`，提案里的冻结、恢复与子代理传播规则仍然适用。补完前需要先定两件事：工具白名单是否允许整棵进程树覆盖，以及 `--list-tools` 如何处理 `task` 的深度移除。当前 `Tool_Config` 的未使用字段可以先删除，也可以留到那时再接上。

## 相关文档

- [cli-and-config.md](../cli-and-config.md)：当前参数、`SYSTEM.md`、恢复 warning 与退出码
- [context-management.md](../context-management.md)：system prompt 的组装顺序与 section 归属
- [tools.md](../tools.md)：工具集如何决定，`task` 如何受深度限制
- [subagents.md](../subagents.md)：子代理参数传播
