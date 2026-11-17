# 提案：hooks

状态：草案，未实现。实现后正文并入 [cli-and-config.md](../cli-and-config.md)、[tools.md](../tools.md)、[subagents.md](../subagents.md) 与 [architecture.md](../architecture.md)。

## 目标

在 run 的生命周期上提供本地命令挂载点，让使用者用自己的脚本审计、约束和补充 agent 的行为，而不必改 ap 或包一层外壳。典型用途：

- 记录每次 `bash` 命令，或把 `write_file` 的目标路径写进审计日志。
- 在 `bash` 执行前拦截明显危险或超出项目范围的命令。
- 在工具返回后统一格式化、裁剪或补充说明。
- 在一轮开始前把项目状态（分支、未提交改动、CI 结果）注入提示词。

hooks 是**宿主策略**，不是模型能力：它由 `settings.json` 配置，模型、`AGENTS.md`、技能清单都不能触发或改写它。

## 非目标

- 不做审批弹窗、权限模式或沙箱。hook 可以拒绝一次工具调用，但不是安全边界；模型仍可以通过 `bash` 做任何事。见 [15-safety.md](../../15-safety.md)。
- 不支持 hook 修改 transcript、改写历史事件或重放 run。
- 不支持异步或后台 hook。所有 hook 同步阻塞，参与取消。
- 不做 hook 之间的编排语言、条件表达式或模板渲染；匹配只有工具名，其余判断交给脚本自己。
- 不在 `context_build` 里执行 hook，也不让 hook 影响投影结果。
- 不引入插件协议、HTTP 端点或常驻进程。
- `magi-cli` 不启用 hooks。它不走 `ap-cli`，这条正是分层带来的结果，不是遗漏。

## 挂载点

第一版只做 CLI 层能覆盖的五个事件，全部在 `ap-cli`，`ap-core` 一行不改。

| 事件 | 触发位置 | 能否阻断 | 能否改内容 | 实现文件 |
| --- | --- | --- | --- | --- |
| `SessionStart` | `session_open` 成功后、第一个 turn 前 | 否 | 只能追加 context | `ap-cli/run.odin` |
| `UserPromptSubmit` | `turn_run` 之前 | 是 | 可追加上下文 | `ap-cli/run.odin` |
| `PreToolUse` | 每次工具执行前 | 是 | 可改 `tool_input` | `ap-cli/tools/hook_tool.odin` |
| `PostToolUse` | 每次工具执行后 | 否 | 可改 `tool_output` | `ap-cli/tools/hook_tool.odin` |
| `SessionEnd` | turn 结束、`session_close` 之前 | 否 | 否 | `ap-cli/run.odin` |

工具级事件通过包装 `Tool` 实现：`aptools.builtin_tools(&tool_cfg)` 之后逐个套 `hook_wrap`，`Tool.name`、`description`、`parameters_json` 原样透传。`Tool.user` 指向包装器自己的状态（`inner` + `^Hook_Config`），因此不需要改 `ap-core/tool` 的契约。

turn 级事件由 `run.odin` 直接调用执行器，因为 CLI adapter 本来就是 turn 与 session 的组装根；`ap-core` 只负责机制，不知道 hooks 存在。

### 触发边界

| 入口 | SessionStart | UserPromptSubmit | 工具事件 | SessionEnd |
| --- | --- | --- | --- | --- |
| 普通 turn | 是 | 是 | 是 | 是 |
| `--print-system-prompt` | 否 | 否 | 否 | 否 |
| `--list-skills` | 否 | 否 | 否 | 否 |
| `--session-title` | 是 | 否 | 否 | 是 |
| `--handoff` | 是 | 是（新 session 的第一条提示词） | 是 | 是 |
| `--no-hooks` / `AP_NO_HOOKS=1` | 否 | 否 | 否 | 否 |

`--print-system-prompt` 只组装提示词、不产生 session，因此不触发任何 hook；这也是唯一一个会在没有 session id 的情况下退出的路径。`--session-title` 会开 session 但不跑 turn，所以只触发首尾两个事件。

## 线协议

### 输入

stdin 一条 JSON（单行，UTF-8，末尾换行）：

```json
{
  "event": "PreToolUse",
  "session_id": "ses_...",
  "cwd": "/path/to/project",
  "transcript_path": "/path/to/session.jsonl",
  "agent_name": "general",
  "agent_depth": 0,
  "tool_name": "bash",
  "tool_call_id": "call_...",
  "tool_input": {"command": "rm -rf build"},
  "tool_output": null
}
```

`tool_name` / `tool_input` / `tool_call_id` 只在工具事件出现；`tool_output` 只在 `PostToolUse` 出现，形状为 `{"ok":true,"content":"...","error":""}`。`UserPromptSubmit` 带 `prompt` 字段。

同样的值也通过环境变量给出，方便不写 JSON 解析的 shell 脚本：

| 变量 | 说明 |
| --- | --- |
| `AP_HOOK_EVENT` | 事件名 |
| `AP_SESSION_ID` | 当前 session id |
| `AP_CWD` | 项目根目录 |
| `AP_TRANSCRIPT_PATH` | transcript 路径 |
| `AP_AGENT_NAME` / `AP_AGENT_DEPTH` | 当前 agent 与深度 |
| `AP_TOOL_NAME` | 工具名，非工具事件为空 |
| `AP_CONFIG_DIR` | `$AP_CONFIG` |

stdin 写入完整 JSON 后立即关闭；hook 不读 stdin 也不会阻塞。

### 输出

stdout 最多读取 `HOOK_MAX_STDOUT_BYTES`（1 MiB），超出部分截断并整条 hook 判定为失败。stdout 非空时按 JSON 解析；解析失败按「只看到退出码」处理。

退出码：

| 退出码 | 含义 |
| --- | --- |
| `0` | 放行。stdout 为空或合法 JSON 时按其字段生效 |
| `2` | 阻断。stderr 作为原因 |
| 其他 | hook 自身失败：写 stderr 日志，**不阻断**，run 继续 |

`2` 只对 `UserPromptSubmit` 和 `PreToolUse` 有意义；出现在其他事件上等价于「失败」。

JSON 字段：

```json
{
  "decision": "allow" | "deny",
  "reason": "写进 tool_result.error 或 stderr 的说明",
  "tool_input": { "...": "仅 PreToolUse，替换后的参数" },
  "tool_output": "仅 PostToolUse，替换后的 content 字符串",
  "additional_context": "仅 UserPromptSubmit / SessionStart，追加到下一次请求的 user 文本"
}
```

字段全部可选，未知字段忽略。`decision` 缺省按 `allow`。

## 配置

`settings.json(c)` 新增顶层 `hooks`：

```json
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "bash", "command": "python3 .ap/hooks/audit_bash.py", "timeout_ms": 30000},
      {"matcher": "*", "command": "hooks/log-tool.sh"}
    ],
    "PostToolUse": [
      {"matcher": "write_file", "command": "hooks/fmt.sh"}
    ],
    "UserPromptSubmit": [
      {"command": "hooks/project-state.sh"}
    ]
  }
}
```

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `matcher` | `*` | 工具名精确匹配，`*` 表示全部；对非工具事件无意义 |
| `command` | 必填 | 交给 `bash -c` 执行，与 `bash` 工具同一套解释器 |
| `timeout_ms` | `60000` | 单条 hook 超时，`0` 表示不限；上限 `600000`，与 `bash` 工具一致 |

规则按数组顺序串行执行，同一事件内遇到 `deny` 立即短路，后续规则不再运行。`cwd` 为项目根目录，环境变量继承父进程（含 `PATH`），但去掉 `AP_PARENT_*` 这类内部变量，避免 hook 误以为自己处在子代理里。

hooks 只从 `$AP_CONFIG/settings.json(c)` 读取，与其余配置同源；不支持项目级自动发现。想做项目本地 hook 就在配置里写相对路径（相对项目根解析）。

## 决策

1. **hooks 全部留在 `ap-cli`。** `ap-core` 是 SDK，`magi` 是第二个宿主；把 hooks 塞进引擎会让两者都被迫接受一种宿主策略。工具级用包装器、turn 级用组装根，都不需要新契约。
2. **hook 是普通子进程，不是常驻服务。** 每次触发 fork 一次，走 `aptools` 现有的 `run_child`，因此天然继承进程树、超时和取消语义。不引入长连接、不引入新的 C 依赖。
3. **deny 表现为工具失败，不是终止 turn。** `PreToolUse` 拒绝时包装器返回 `tool_fail("blocked by hook: <reason>")`，写进正常的 `tool_execution_end`（`ok=false`）。模型看到的是工具报错，可以换路径继续。包装器永远不设 `fatal`，终止 turn 由模型自己的决策或工具自身的致命错误承担，hook 不越权。这样也保住了「完整事件只追加」：被拒调用照样有 start / end 两条事件。
4. **`UserPromptSubmit` 拒绝时整轮不跑。** 提示词没通过本地策略，就不该产生模型调用。CLI 以退出码 `2` 结束，`stream-json` 下写 `session_end(reason="error")`。
5. **hook 输出不进 transcript。** transcript 里只出现事件本身；hook 的判定结果不落盘，stderr 转到 ap 的 stderr（`text` 模式即时可见，其他格式进日志文件）。这样 transcript 不出现无法解析的行，也不让 hook 成为事实来源。
6. **`additional_context` 只能变成 `user_message` 事件。** turn 级 hook 在 `turn_run` 前把追加文本与原始提示词合并成一个 `user_message`（空行分隔，标明来源段），或者在新 session 的第一条消息前写一条独立 `user_message`。绝不出现「构建上下文时再跑一次 hook」——那会破坏 `context_build` 的纯函数要求。
7. **hooks 不冻结进 `session_start`。** 恢复和 fork 都按当前 `settings.json` 重新加载。hooks 是本机策略（日志路径、工具链、审计脚本都在本机），跟着机器走比跟着 session 走更符合直觉；代价是换机器恢复时行为可能不同，文档要写明。
8. **子代理自动继承。** `task` 起的子进程是独立 `ap`，重新读 `settings.json`，hooks 自然生效。`--no-hooks` 与 `AP_NO_HOOKS=1` 在父进程关闭时通过子进程参数传播，避免父子重复触发同一条规则；`agent_depth > 0` 时默认不清空 hooks，由使用者用 `matcher` 或脚本里的 `AP_AGENT_DEPTH` 自行取舍。
9. **超时与取消。** 超时按 `kill_process_tree` 处理，整条 hook 判为失败（不阻断），并写一条 warning。ap 收到 SIGINT/SIGTERM 时，正在运行的 hook 进程树一并终止，`PreToolUse` 不返回结果、`turn_run` 按取消路径退出。
10. **hook 失败默认可容忍。** 脚本写错、解释器不存在、超时都只 warning。理由是 hooks 是辅助设施，不能因为一条审计脚本让 agent 停摆；需要严格性时，脚本自己 exit 2。

## 与现有契约的关系

| 契约 | hooks 下的含义 |
| --- | --- |
| 完整事件只追加 | 包装器只改「即将写入」的 `tool_execution_start.args` 与 `tool_execution_end.content`，已有事件一律不动；deny 也是正常写 start / end |
| transcript 是唯一事实来源 | hook 的输入只来自当前事件与 session 元数据，不引入只存在于 hook 进程里的状态；hook 输出不落盘 |
| `context_build` 是纯函数 | `additional_context` 先写成 `user_message` 再参与投影；投影阶段不执行 hook |
| stdout 是机器通道 | hook 的 stdout 被捕获，stderr 转 stderr / 日志；ap 自身 stdout 行为不变 |
| 取消必须及时 | hook 子进程进同一 job / 进程组，取消时整树终止 |
| 不做隐藏的安全拦截 | hooks 不是内建权限规则：默认没有 hooks 时行为与现在逐字节一致；规则只来自用户自己的 `settings.json`，模型、`AGENTS.md` 与技能都无法写入或触发 |

第六行是本提案唯一需要评审确认的地方。它依赖一个判断：**由用户显式配置、默认关闭、且不作用于模型输入的本地脚本，不等于 ap 内建的审批或沙箱。** 如果评审认为这条仍然越界，退路是把 hooks 降级为「只允许 `PostToolUse` 的观测事件」，去掉所有阻断能力——那样它就只能审计，不能约束。

## 实施批次

每批独立可验证，前一批不通过不进入下一批。

1. **配置与执行器。** `settings.odin` 解析 `hooks`（进 `known_setting_keys`，加 `Hook_Config`），`ap-cli/tools/hooks.odin` 实现 payload 组装、spawn、超时、退出码判定、JSON 解析。此时还没有挂载点，只有测试。
2. **`PreToolUse` / `PostToolUse`。** `hook_tool.odin` 包装器；`run.odin` 在注册表构造后统一套一层。改 args 后要重新校验是 JSON object；`PostToolUse` 只允许修改 `ok=true` 的结果。
3. **`UserPromptSubmit` / `SessionStart` / `SessionEnd`。** 挂在 `run.odin` 的对应位置，处理 `additional_context` 与 `deny` 的退出码。
4. **`--no-hooks` 与子代理传播。** `options.odin`、`tool_task.odin`、`print_usage`。
5. **文档与示例。** 本提案落地时同步改下文清单。

## 测试计划

CLI（`odin test ap-cli`）：

- hooks 配置解析：缺 `command`、非法 `timeout_ms`、未知事件名 → 退出 2 并报字段路径。
- `matcher` 精确匹配与 `*`；同一事件多条规则按顺序执行且 deny 短路。
- 退出码映射：`0` 放行、`2` 阻断、`1` 只 warning 不阻断。
- stdout 非 JSON、超 1 MiB、stderr 有输出但不阻断。
- `PreToolUse` 改 `tool_input` 后实际执行的是新参数，`tool_execution_start.args` 记录新参数。
- `PreToolUse` deny：`tool_execution_end` 为 `ok=false`、`error` 带原因、turn 继续。
- `PostToolUse` 改 `tool_output`：`tool_execution_end.content` 是新值；`ok=false` 时忽略修改。
- 超时：hook 被整棵树杀干净，run 继续并出现 warning。
- 取消：SIGINT 打断正在运行的 hook，退出码 130，transcript 尾部有 `cancel` + `turn_end(cancelled)`。
- `UserPromptSubmit` deny：不发送任何模型请求（用假 provider 计数），退出 2。
- `additional_context` 出现在第一次请求的 `messages` 里，且投影仍是纯函数（同一 transcript 重算两次逐字节相同）。
- `--no-hooks` 时零 spawn；`task` 子进程参数带 `--no-hooks` 且 hooks 不触发。

不新增外网依赖，hook 脚本用仓库内临时目录的小脚本，测试结束清理。

## 需要同步的文档与代码

| 位置 | 改动 |
| --- | --- |
| `ap-cli/settings.odin`、`settings.example.json` | `hooks` 字段、`known_setting_keys`、校验 |
| `ap-cli/tools/hooks.odin`、`hook_tool.odin` | 新增 |
| `ap-cli/tools/config.odin` | `Tool_Config` 增加 `*Hook_Config` |
| `ap-cli/run.odin`、`options.odin`、`app.odin` | 挂载点、`--no-hooks`、usage |
| `ap-cli/tools/tool_task.odin` | `--no-hooks` 传播 |
| `docs/01-what-is-ap.md`、`docs/20-files-and-terms.md`、`docs/internal/README.md`、`README.md` | 非目标清单删除 hooks，改为「已支持工具级 hook，不支持审批」 |
| 新增 `docs/hooks.md` | 使用说明、协议、示例、风险 |
| `docs/README.md` | 用户手册目录登记 `hooks.md` |
| `docs/internal/README.md` | 文档地图把本提案标为「已实现」，并改写「与 Claude Code 的关系」中「没有采纳 hooks」一句；另见上行非目标清单 |
| `docs/15-safety.md` | 明确 hook 不是沙箱，只是本地脚本钩子 |
| `docs/19-config-reference.md`、`docs/18-cli-reference.md` | `hooks` 字段、`--no-hooks` |
| `docs/internal/tools.md` | 工具执行管线多了包装层 |
| `docs/internal/subagents.md` | hooks 继承与去重 |
| `docs/internal/context-management.md` | `additional_context` 的合法路径 |
| `docs/internal/architecture.md`、`docs/internal/cli-and-config.md` | 组装根职责、hooks 不入 SDK |
| 根 `AGENTS.md` 改动地图 | 新增 hooks 一行 |

## 风险与待定

1. **待定：是否对齐 Claude Code 的 hook 协议。** 本文的 exit code 2 与 `decision` 字段沿用了它的约定，但事件名、`additional_context` 与 `tool_output` 是自定的。如果目标是「Claude Code 的 hook 脚本能直接复用」，需要在实现前逐字段对齐，并接受它的多行 JSON 格式；如果目标是 ap 自己够用，就维持本文的精简协议。**建议先按本文实现，等真实脚本出现再决定是否加兼容层。**
2. **待定：`PreToolUse` 能否改参数。** 允许改 `tool_input` 会带来一个隐患——模型看到的参数和实际执行的参数不同，事后审计要靠 `tool_execution_start.args`（已记录实际值）。本文选择允许，因为「统一改写 `bash` 命令前缀」是最常见需求；若要收紧，删掉该字段即可，其他语义不受影响。
3. **待定：hook 的发现范围。** 目前只认 `$AP_CONFIG/settings.json`。项目级 `.ap/hooks.json` 会让仓库自带策略，但也意味着执行仓库里的任意命令，安全边界更模糊。**建议保持只认配置目录**，项目脚本用路径引用。
4. **待定：`Stop` 事件。** 「turn 结束后自动继续」需要重新进入 loop，与一次性 CLI 的语义冲突，容易造成死循环。本提案不做。
5. **性能。** 每条规则一次进程启动，Windows 上开销明显。缓解办法是按 `matcher` 收窄，并在文档里给出「不要给 `read_file` 挂重型脚本」的提醒。不做常驻服务是因为它与取消、进程树、资源清理的组合复杂度不成比例。
6. **风险：hook 与模型争用同一批文件。** `PostToolUse` 里跑格式化会改文件，而模型随后可能基于旧内容继续编辑，导致 `edit_file` 的 `oldText` 失配。文档要写明：改文件的 hook 只应在 `write_file` 后使用，或在 `reason` 里明确提示模型重新读文件。
7. **风险：日志写入与 stdout 混淆。** 如果 hook 把调试信息写到 stdout，会被当成 JSON 解析失败并整条忽略。协议里必须给脚本作者一条硬规则：**stdout 只放判定 JSON，日志一律 stderr**。

## 相关文档

- [architecture.md](../architecture.md)：SDK 与应用层的分工
- [cli-and-config.md](../cli-and-config.md)：参数、配置与退出码
- [tools.md](../tools.md)：工具执行管线与 `Tool_Context`
- [subagents.md](../subagents.md)：子代理参数传播
- [errors-and-cancellation.md](../errors-and-cancellation.md)：取消与进程树
- [context-management.md](../context-management.md)：`context_build` 纯函数
