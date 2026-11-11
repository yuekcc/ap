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

一次工具调用只占一行，状态直接追加在调用行末尾：

```text
◆ bash (command=npm test) ✓ 4210ms exit 0
```

工具输出不在终端渲染，只保留命令行、耗时和结果状态。完整结果在 transcript 里，需要时用 [浏览器界面](11-web.md) 查看。

## 输入框按键

| 按键 | 行为 |
| --- | --- |
| Enter | 提交。缓冲区只有空白时不提交 |
| Ctrl+Enter | 插入换行。需要终端支持 Kitty keyboard protocol |
| ←、→ | 按字符移动 |
| ↑、↓ | 按可视行移动 |
| Home、End、Ctrl+A、Ctrl+E | 到当前逻辑行首或行尾 |
| Backspace、Delete | 删除前一个或后一个字符 |
| Ctrl+K | 删到行尾 |
| Ctrl+U | 删到行首 |
| Ctrl+W | 删除前一个词 |
| Ctrl+C | 缓冲区非空时清空；为空时退出 |
| Esc | 清空缓冲区 |

终端不支持 Kitty keyboard protocol 时，Ctrl+Enter 不可用，启动时会提示一次。

粘贴内容会原样插入。整段粘贴超过 1 MiB 时截断并插入 `[input truncated]`。

## 四个命令

| 命令 | 行为 |
| --- | --- |
| `/new` | 丢弃当前 session id，下一条提示词新建会话 |
| `/session` | 显示当前 session id |
| `/help` | 显示命令列表 |
| `/quit`、`/exit` | 退出 |

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
- 输入框没有方向键 history、选中、撤销、鼠标和输入法预编辑。
- 终端缩放可能导致编辑块错位。下一次按键重绘时会按新尺寸重新布局。
- emoji 的 ZWJ 序列和变体选择符按 1 列处理，光标可能视觉偏移。

## 什么时候用它

需要连续追问、想保留滚动历史、又不想开浏览器时，用 `ap-tui`。需要脚本、批处理或精确的 JSON 输出时，用一次性命令行。需要多标签页、多工作空间时，用 [浏览器界面](11-web.md)。
