# 10. 终端界面 ap-tui

`ap-tui` 是 ap 的终端前端。它不实现 agent，只负责启动 `ap` 子进程、读取事件、渲染到终端。每轮对话都会新建一个 `ap` 子进程。

## 启动

```sh
# 新会话
./build/ap-tui

# 恢复当前项目最近的根会话
./build/ap-tui -c

# 恢复指定会话
./build/ap-tui -s ses_20261022_120000_abcdef123456
```

常用参数：

| 参数 | 作用 |
| --- | --- |
| `-c`, `--continue` | 恢复当前项目最近的根会话 |
| `-s`, `--session <id>` | 恢复指定会话，启动前校验文件存在 |
| `--agent-bin <path>` | 指定 `ap` 可执行文件 |
| `--config-dir <dir>` | 传给 `ap` 的配置目录 |
| `--model <id>` | 传给 `ap --model` |
| `--agent <name>` | 传给 `ap --agent` |
| `--max-steps <n>` | 传给 `ap --max-steps` |
| `--max-tokens <n>` | 传给 `ap --max-tokens` |
| `--verbose` | 实时显示 `ap` 的 stderr |
| `--no-color` | 关闭 ANSI 颜色 |

工作目录固定为启动时定位到的项目根目录。`ap-tui` 没有 `--cwd`。

## 界面怎么读

- `›`：用户消息和输入框。
- `●`：assistant 文本。
- `◆`：工具调用，后面是工具名和参数。
- `✓`、`✗`：工具结果状态，带耗时和退出码，失败时再附错误信息。
- `cancelled [scope]`：已取消。
- `turn ended: <reason>`：本轮不是正常结束。
- `turn 3.4s`：本轮执行时间，从启动 `ap` 子进程算到它退出。首轮并入新 session 提示，显示为 `using session: <id> (3.4s)`。按长度显示为毫秒、秒、分或小时；取消的轮次也会显示。

一次工具调用占两行：第一行是工具名和参数，第二行缩进两格显示状态。

```text
◆ bash (command=npm test)
  ✓ 4210ms exit 0
```

工具输出不在终端渲染，只保留命令行、耗时和结果状态。完整结果在 transcript 里，需要时用 [浏览器界面](11-web.md) 查看。

## Markdown 渲染（glow）

[glow](https://github.com/charmbracelet/glow) 是一个终端 Markdown 渲染器。`ap-tui` 不内置渲染，而是调用 `PATH` 中的 `glow` 命令渲染 assistant 的 Markdown。

默认情况下，assistant 文本按模型返回的原始文本显示。想让 Markdown 经过 `glow` 渲染，在 `$AP_CONFIG/settings.json` 里开启：

```json
{
  "tui": {
    "enable_glow": true
  }
}
```

`tui` 段只由 `ap-tui` 读取，`ap` 和 `magi` 会忽略它。`glow` 需要自行安装并能在 `PATH` 中找到，安装方式见 [glow 首页](https://github.com/charmbracelet/glow)。

开启后的行为：

- assistant 文本等到消息完整结束后再交给 `glow` 渲染，因此不再逐 token 流式出现。工具调用和工具状态仍然实时显示。
- 终端可查询宽度时，渲染宽度跟随终端宽度；否则用 glow 的默认宽度。
- `--no-color` 或 `NO_COLOR` 生效时，`glow` 使用无色样式。
- `glow` 不存在或渲染失败时，退回原始文本，并在本次 `ap-tui` 进程内关闭 glow，不会影响会话和工具执行。

工具输出仍然不在终端渲染，见上一节。

## 输入框按键

| 按键 | 行为 |
| --- | --- |
| Enter | 提交。缓冲区只有空白时不提交 |
| Ctrl+Enter、Shift+Enter、Alt+Enter | 插入换行。Ctrl/Shift+Enter 需要 Kitty keyboard protocol；Alt+Enter 在把 Alt 编码为 ESC 前缀的终端上可用 |
| ←、→ | 按字符移动 |
| Ctrl+←、Ctrl+→、Alt+←、Alt+→ | 按词移动 |
| ↑、↓ | 按可视行移动；在首/末行继续按浏览 history |
| Ctrl+P、Ctrl+N、PageUp、PageDown | history 上一条/下一条 |
| Home、End、Ctrl+A、Ctrl+E | 到当前逻辑行首或行尾 |
| Ctrl+Home、Ctrl+End | 到整个输入内容开头或结尾 |
| Backspace、Delete、Ctrl+H | 删除前一个或后一个字符 |
| Ctrl+K | 删到行尾 |
| Ctrl+U | 删到行首 |
| Ctrl+W | 删除前一个词 |
| Tab、Shift+Tab | 补全斜杠命令；菜单打开时切换候选 |
| Ctrl+L | 按当前窗口尺寸重绘输入框 |
| Ctrl+C | 缓冲区非空时清空；为空时退出 |
| Ctrl+D | 缓冲区非空时删除光标下的字符；为空时退出 |
| Esc | 清空缓冲区 |

输入 `/` 后按 Tab 会列出可用命令。多候选时先插入公共前缀并显示菜单；继续按 Tab、Shift+Tab 或 ↑/↓ 切换候选，Enter 提交当前内容，Esc 只关闭菜单。输入其他字符会关闭菜单并继续编辑。

终端支持 Kitty keyboard protocol 时，Ctrl+Enter 和 Shift+Enter 可以插入换行；不支持时可用 Alt+Enter（终端把 Alt 编码为 ESC 前缀时）。

数字小键盘可以直接输入数字和运算符，小键盘 Enter 同样提交。NumLock 关闭时，小键盘的方向键、Home、End、Delete 与主键盘上的对应键一致。

粘贴内容会插入输入框；CRLF 和孤立 CR 归一成换行，C0 控制字符（换行和制表符除外）会被丢弃。超过 8 MiB 的粘贴只保留前 8 MiB，当前界面不额外提示。

## 五个命令

| 命令 | 行为 |
| --- | --- |
| `/new` | 丢弃当前 session id，下一条提示词新建会话 |
| `/session` | 显示当前 session id |
| `/copy` | 把最后一条 assistant 消息复制到系统剪贴板 |
| `/help` | 显示命令列表 |
| `/quit`、`/exit` | 退出 |

`/copy` 复制的是模型返回的原始 Markdown，不是开启 glow 后的渲染结果。它通过 OSC 52 序列把文本交给终端，由终端写入剪贴板，因此终端和终端复用器需要支持 OSC 52（例如 Windows Terminal、Ghostty、iTerm2；tmux 需要 `set-clipboard on`）。stdout 不是终端时 `/copy` 只提示无法复制。复制成功与否由终端决定，`ap-tui` 只负责发出序列。每个进程内的复制目标都是最近一条有正文的 assistant 消息，即使随后切换到了新会话。

未知的 `/...` 不当作命令，会作为普通提示词发送。因此可以直接发绝对路径。

`ap-tui` 没有 `/resume` 列表、`/fork` 和删除会话的入口。

## 历史重放

用 `-c` 或 `-s` 启动时，`ap-tui` 会在进入输入循环前重放 transcript：

- 用户消息加 `›` 前缀。
- assistant 文本和工具调用行（含状态）按原顺序显示。
- 流式增量不重放，因为最终文本已经在持久事件里。
- 大字段从 `blobs/` 读取。blob 缺失时退化为预览并标记。

重放只读文件，不调用模型，不执行工具，也不写 transcript。

## 已知限制

- 运行中的 turn 不读 stdin。这期间按的键会留在终端缓冲里，turn 结束后可能变成下一条提示词。
- 运行中按 Ctrl+C 是内核信号，会同时终止 `ap-tui` 和 `ap`，不会回到输入框。
- 不显示 reasoning，也没有 token 或 usage 状态行。
- 不显示工具输出，需要看结果时去 web 界面或 transcript。
- 开启 `tui.enable_glow` 后，assistant 文本在消息结束后才出现，不再实时流式输出。
- `/copy` 不检查终端是否真的写入了剪贴板；部分终端对 OSC 52 有长度上限，超长消息可能被静默丢弃。
- 输入框没有持久化 history、选中、撤销和鼠标支持。补全只覆盖斜杠命令；history 只在当前进程内保留。
- 终端缩放可能导致编辑块错位。下一次按键重绘时会按新尺寸重新布局。

## 什么时候用它

需要连续追问、想保留滚动历史、又不想开浏览器时，用 `ap-tui`。需要脚本、批处理或精确的 JSON 输出时，用一次性命令行。需要多标签页、多工作空间时，用 [浏览器界面](11-web.md)。
