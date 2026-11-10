# 17. 出错了怎么办

先看退出码，再看 stderr 最后几行，最后查日志。大部分问题能在这三步内定位。

## 先看退出码

| 码 | 含义 | 先查 |
| --- | --- | --- |
| 0 | 正常结束 | 看 `stop_reason`，可能只是步数或 token 用完 |
| 1 | 内部错误 | 磁盘是否可写，transcript 是否损坏 |
| 2 | 用法、配置或恢复错误 | 参数、`settings.json`、session 路径 |
| 3 | 模型接口错误 | 网络、密钥、模型名、上下文长度 |
| 4 | 工具基础设施故障 | 能否启动 bash，磁盘是否可写 |
| 130 | Ctrl+C 或 SIGINT | 检查已产生的副作用 |
| 143 | SIGTERM | 检查已产生的副作用 |

退出码 0 不代表模型正常说完。`max_steps` 和 `max_tokens` 也返回 0。要区分，用 `--output-format json` 看 `stop_reason`。

## 安装与启动

**提示找不到 bash。** 安装 Git for Windows，或设置 `AP_BASH` 指向 `bash.exe` 的绝对路径。不要指向 `C:\Windows\System32` 下的 WSL bash。

**提示配置文件不存在。** 创建 `~/.ap/settings.json`，或把 `settings.example.json` 复制过去。也可以设置 `AP_CONFIG` 或传 `--config-dir`。

**提示模型未配置。** `model` 必填，即使命令行传了 `--model`。

**`build.sh` 在前端构建处停下。** 先跑 `npm --prefix ap-web install`，或使用已提交的 `ap-web/dist/`。

**端口被占用。** 换一个端口：

```sh
./build/ap-web --port 8420
```

## 模型连接

**401 或 403。** key 无效、过期或没有该模型的权限。检查 `api_key`，确认 `AP_API_KEY` 没有覆盖成旧值。

**404 或模型不存在。** 检查 `base_url` 是否指向兼容 OpenAI chat completions 的地址，模型 id 是否拼对。

**一直超时。** 检查网络和代理。必要时调大 `llm_timeout_ms`，但先确认接口本身可达。

**模型不调用工具。** 换一个支持 tool calls 的模型。ap 依赖结构化工具调用，纯文本模型无法可靠执行操作。

**重试很多次后退出 3。** 看 stderr 里的 `[retry]` 和错误信息。429 会退避重试，鉴权失败和参数错误不会。

## 上下文太长

现象：

- `stop_reason` 为 `context_too_long`。
- stderr 提示 `context too long; start a new session or reduce input`。

处理顺序：

1. 开新会话，把当前结论带过去。
2. 用 `--handoff` 生成交接文档。
3. 确认自动交接没有被 `--no-handoff` 关掉。
4. 确认 `--context-window` 不是 `0`。
5. 调大 `context_window_tokens`，但要符合配置约束。

如果省略发生，stderr 会显示 `[context] elided N tool results`。这是正常行为，不是错误。

## 会话找不到

```text
session "abc" not found in project <hash> (expected .../projects/<hash>/abc.jsonl)
```

原因通常是启动目录变了。`-s` 和 `-c` 只在当前项目内查找，不跨目录。

处理：

- 回到创建会话时的目录再试。
- 确认 session id 没有抄错。
- 用 `-c` 找当前项目最近的根会话。

## blob 缺失

恢复时报 blob 缺失或哈希不匹配，说明会话引用的某个大文件被删了或损坏了。

ap 不会静默降级。这个会话无法完整恢复。能做的只有：

- 从备份恢复 `projects/<hash>/blobs/`。
- 或者放弃该会话，开新会话。

平时不要把 blob 当作可随意清理的缓存。

## 终端和界面

**中文参数乱码。** Windows 控制台代码页不是 UTF-8 时可能出现。改用 `--input-file` 传提示词，或把终端切到 UTF-8。

**TUI 运行中按 Ctrl+C 后整个界面退出。** 这是当前行为。运行中的 Ctrl+C 是内核信号，会同时终止 `ap-tui` 和 `ap`。

**TUI 不显示 reasoning 和 usage。** 当前版本不支持。需要 token 数据时用 `--output-format json`。

**网页目录选择提示不支持。** Unix 没有统一的原生目录对话框，接口返回 501。Windows 才支持。

**网页刷新后状态不对。** 页面会重新读 history 再订阅事件。断线期间没有 `Last-Event-ID` 补发，只能靠重放和 `seq` 去重。

## 工具一直失败

看 stderr 里的 `✗` 行和错误文本：

- 路径不存在：确认相对路径是相对启动目录。
- 文件不是 UTF-8：用 `bash` 处理二进制或换编码。
- `edit_file` 未匹配：先 `read_file` 确认原文，注意 CRLF 会归一为 LF。
- 多处匹配：加更多上下文，或设 `replace_all`。
- `bash` 超时：命令被终止，进程树也被清理。调大 `timeout_ms`，或拆小命令。
- 输出超限：缩小命令输出，或用 `grep`、`head` 过滤。

## 日志

warning 及以上会写到：

```text
$AP_CONFIG/logs/app-YYYY-MM-DD.log
```

同时输出到 stderr。需要更详细的信息时：

```sh
./build/ap --verbose --print "..."
./build/ap --debug --print "..."
```

## 报告问题时带上这些

- 完整命令和参数。
- 退出码。
- stderr 最后 20 到 50 行。
- 当天日志中相关片段。
- session id。
- 操作系统和 ap 版本。
- 是否能稳定复现。

不要粘贴真实 API key、客户数据或完整隐私文件。
