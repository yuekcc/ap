# 20. 文件布局与术语

这一章是查表用的。路径和术语以当前实现为准。

## 目录结构

```text
$AP_CONFIG/
  settings.json                   # 或 settings.jsonc
  SYSTEM.md                       # 替换基础提示词
  agents/
    <name>.md
  logs/
    app-YYYY-MM-DD.log
  projects/
    <project_hash>/
      path.txt
      blobs/
        <sha256>
        <sha256>.txt
      <session_id>.jsonl

~/.agents/
  AGENTS.md                       # 全局记忆
  skills/
    <name>/
      SKILL.md
```

`$AP_CONFIG` 默认是 `~/.ap`，可以用 `--config-dir` 或 `AP_CONFIG` 改变。

## 术语

| 术语 | 含义 |
| --- | --- |
| session | 一次逻辑对话，由 `session_id` 标识，可跨多次运行恢复 |
| transcript | 会话的事件记录，落盘为只追加的 JSONL 文件 |
| turn | 从一条用户提示词开始，到循环终止为止的一段执行 |
| step | 一个 turn 内的一次逻辑 LLM 调用；重试不增加 step |
| message | 提交给模型的一条对话记录 |
| tool call | 模型要求执行工具的请求 |
| 工具 | ap 在本地执行的动作，例如读文件、写文件、跑 bash |
| blob | 内容寻址的大块数据文件，按 sha256 引用 |
| 子代理 | 由 `task` 启动、有独立 session 的 ap 进程 |
| 技能 | 放在 `SKILL.md` 里的 Markdown 指令包 |
| 代理 | 预设的提示词和工具白名单，定义文件在 `agents/` |
| handoff | 把当前上下文交给新会话时生成的交接文档 |
| provider | 模型接口适配层，当前只支持 OpenAI chat completions |
| stream event | 只写 stdout、不落盘的临时事件 |
| transcript event | 追加到 transcript 的持久事件 |

## 路径规则

- 相对路径相对启动目录。
- 绝对路径可用。
- `~` 和 `~/...` 展开为主目录。
- 不展开其他环境变量。
- Windows 上 `/` 和 `\` 都接受，但不接受 MSYS 的 `/z/...` 这种形式给文件工具。
- 没有 `--add-dir`，文件工具不限制在项目目录内。

## 当前不支持的功能

以下功能在规划中或明确不做：

- 审批、权限规则、沙箱。
- 对话压缩和消息级淘汰。只做工具结果省略和 handoff。
- 向量检索和外部记忆库。
- 自动删减 system prompt 或工具 schema。
- hooks、plan mode、MCP、插件系统。
- grep、glob、ls、webfetch 等额外工具。搜索和列目录交给 `bash`。
- `--add-dir`。
- blob 自动回收。
- 技能脚本执行、参数传入、远程安装。
- 远程会话共享和服务端部署。
- 浏览器界面的 session fork、删除和文件上传。

## 相关文档

- 维护者规格：[docs/internal/README.md](internal/README.md)
- 安装与第一次运行：第 2 章到第 4 章。
- 参数速查：第 18 章。
- 配置速查：第 19 章。
