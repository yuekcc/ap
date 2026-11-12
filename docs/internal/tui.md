# ap-tui：终端前端

`ap-tui` 是 `ap` 的终端前端。它不实现 agent、provider、工具或 transcript 写入。每一轮 turn 启动一个新的 `ap` 子进程，读取 `stream-json` 事件并滚动渲染到终端。通用的进程契约、命令行形状和 turn 生命周期见 [integration.md](integration.md)，事件 schema 见 [react-loop-and-session.md](react-loop-and-session.md)。

```text
终端 ── ap-tui ──spawn──► ap --print0 --output-format stream-json [-s <id>]
          │                         │
          │◄──── stdout: 事件 ───────┤
          │◄──── stderr: 日志 ───────┤
          │────── stdin: 提示词 ────►
          ▼
    滚动输出 + raw 多行输入框
```

## 进程模型

`ap-tui` 的运行方式如下。

- 入口在 `cmd/ap-tui`，它只调用 `aptui.run`。`ap-tui/` 是 `package aptui` 库，不定义 `main`。
- 一次只维护一个活动 session。整个进程同一时刻最多有一个 `ap` 子进程。
- 每轮都新建子进程。`ap-tui` 不缓存模型连接，也不把前端状态写进 transcript。
- 可执行文件查找、stdin 写法、stdout 行读取、stderr 尾部缓存和 Windows 管道继承清理都复用 `ap-core/client`。这些通用规则见 [integration.md](integration.md)。
- `--verbose` 打开时，stderr 的每一行以 `[ap]` 前缀实时显示。非 verbose 时只在退出码非 0 时展示缓存。
- 子进程退出码 130 或 143 显示 `agent interrupted`，其他非 0 显示 `agent exited with code <n>`。

## 调用参数

```text
ap-tui [options]
```

| 参数 | 作用 |
| --- | --- |
| `-c`, `--continue` | 启动时恢复当前 project 最近的根 session |
| `-s`, `--session <id>` | 恢复指定 session，启动前校验 transcript 存在 |
| `--agent-bin <path>` | 指定 `ap` 可执行文件 |
| `--config-dir <dir>` | 传给 `ap` 的配置目录 |
| `--model <id>` | 原样传给 `ap --model` |
| `--agent <name>` | 原样传给 `ap --agent` |
| `--max-steps <n>` | 原样传给 `ap --max-steps`，必须是正整数 |
| `--max-tokens <n>` | 原样传给 `ap --max-tokens`，必须是正整数 |
| `--verbose` | 实时显示 `ap` 的 stderr |
| `--no-color` | 关闭 ANSI 颜色 |
| `-h`, `--help` | 显示帮助 |
| `--version` | 显示版本 |

启动参数遵循下面的规则：

- `-s` 和 `-c` 互斥。
- 长选项支持 `--opt value` 和 `--opt=value`。
- `--config-dir`、`--agent-bin`、`--model`、`--agent`、`--max-steps`、`--max-tokens` 会进入 `Turn_Options`。
- 工作目录固定为启动时定位到的 project 根目录。`ap-tui` 没有 `--cwd`。
- `ap-tui` 不暴露 `--no-agents-md` 和 `--no-skills`。它拉起的 `ap` 使用默认上下文，`$AP_CONFIG/SYSTEM.md` 仍会生效。
- 启动失败统一返回 2，包括参数错误、project 定位失败、agent 查找失败和指定 session 不存在。

## Session 管理

- 启动时同时没有 `-c` 和 `-s`：新 session。第一轮不带 `-s`，从 `session_start.session_id` 捕获真实 id。
- 捕获 id 后，后续每轮自动追加 `-s <id>`。
- `-c`：用 `find_latest_root_session` 找当前 project 最近的根 session。找不到时打印提示并转为新 session。
- `-s <id>`：检查 `<project>/<id>.jsonl` 存在。不存在时打印期望路径并返回 2。
- 运行中当前 session id 只存在内存里。`/new` 清空它，下一条提示词新建 session。旧 transcript 留在磁盘。
- 每轮的第一条 `session_start` 之后，如果本轮开始时还没有 id，会打印 `session: <id>`。

`ap-tui` 没有 `/resume` 列表、`/fork` 或 session 删除入口。

## 历史重放

指定 `-c`、`-s` 或启动时带有 id 时，`ap-tui` 在进入输入循环前重放 transcript：

```text
<config-dir>/projects/<project_path_hash>/<session_id>.jsonl
```

重放做下面几步：

1. 打印 `── resumed <id> ──`。
2. 逐行解析 v1 transcript。
3. `user_message` 用 `› ` 前缀显示。
4. `message_end` 的 `text` 块显示为 assistant 文本。
5. `tool_execution_start` 画一行工具调用，`tool_execution_end` 另起一行缩进两格补上状态；工具结果本身不重放。
6. `error`、`cancel` 和异常的 `turn_end` 按实时规则显示。
7. `message_update` 在历史模式忽略，因为最终文本已经在 `message_end` 里；`tool_execution_update` 在两种模式下都不渲染。

大字段从同目录 `blobs/` 解析：

- `message_end` 文本块的 `text_ref`。
- `tool_execution_start.args_ref`。

工具结果不参与渲染，所以重放不读 `tool_execution_end.content_ref`。

展示层缺少 blob 时退化为对应的 `*_preview`，并在界面上标记。这只是历史重放的降级规则。`ap` 自己恢复上下文时 blob 缺失会退出 2。重放只读文件，不调用模型，不执行工具，也不写 transcript。

## 渲染

- 使用普通终端滚动区，不使用 alternate screen。输出保留在 scrollback 中。
- 用户消息和输入框使用 `› ` 前缀。非 TTY 回退路径打印 `> `。
- assistant 文本使用 `● ` 前缀。文本 delta 实时输出。
- 工具调用使用 `◆ ` 前缀，后接工具名和参数。参数压成单行并截到约 240 字节。
- 工具结束另起一行并缩进两格，写 `✓` 或 `✗`、耗时、退出码，失败时再附错误信息。错误压成单行并截到 200 字节。一次工具调用占调用行和状态行两行。状态行不随参数行一起折行，避免长参数被终端硬折行后状态落在行首。
- 工具输出不渲染：`tool_execution_update` 增量被忽略，`tool_execution_end` 的结果（含图片）也不展示。完整结果留在 transcript，由 web 界面和 `ap` 恢复使用。
- `message_end` 只在没有收到过文本 delta 时补全文，避免重复。
- `error` 中 `retryable=true` 显示为黄色警告，否则显示为红色错误，并带上 `scope`。
- `cancel` 显示为 `cancelled [<scope>]`。
- `turn_end.stop_reason` 为空或 `stop` 时不提示。`tool_use` 也按正常结束处理，这是防御性兼容；正常的 `turn_end` 不会带 `tool_use`。其他值打印 `turn ended: <reason>`。
- 每轮 turn 结束后先空一行，再画下一条提示符。
- ANSI 颜色在 stdout 不是 TTY、设置了 `NO_COLOR` 或传了 `--no-color` 时关闭。
- reasoning delta 不展示。

## 输入

stdin 是 TTY 时，`ap-tui` 把行编辑交给 `lineedit`。每轮 prompt 前进入 raw mode，提交后、turn 开始前离开 raw，把终端交还内核。非 TTY 时 `lineedit` 使用 pipe 模式按行读取，`ap-tui` 自己打印 `> ` 提示符。

`ap-tui` 配置了斜杠命令 completer；hints 和持久化 history 未启用，history 只保存在当前进程内。编辑块首行前缀是 `› `，续行缩进两格。超过屏幕高度时保留光标所在行，裁掉的内容用首行 `  …` 提示。编辑块不进入滚动区。

编辑框支持下面的按键。

| 按键 | 行为 |
| --- | --- |
| Enter | 提交。缓冲区 trim 后为空时 `ap-tui` 忽略并重新提示 |
| Ctrl+Enter、Shift+Enter、Alt+Enter | 插入换行。Ctrl/Shift+Enter 需要 Kitty keyboard protocol；Alt+Enter 在 legacy 下也可用 |
| ←、→ | 按 rune 移动 |
| Ctrl+←、Ctrl+→、Alt+←、Alt+→ | 按空白分词移动到前一个或后一个词边界 |
| ↑、↓ | 按可视行移动，尽量保持列号；在首/末行继续按则浏览 history |
| Ctrl+P、Ctrl+N、PageUp、PageDown | history 上一条/下一条 |
| Home、End、Ctrl+A、Ctrl+E | 到当前逻辑行首或行尾 |
| Ctrl+Home、Ctrl+End | 到整个缓冲区开头或结尾 |
| 小键盘方向键 | NumLock 关闭时发的是普通方向键；NumLock 打开时按小键盘规则插入数字 |
| Backspace、Delete、Ctrl+H | 删除前一个或后一个 rune，跨行时合并行 |
| Ctrl+K | 删到逻辑行尾 |
| Ctrl+U | 删到逻辑行首 |
| Ctrl+W | 删除前一个空白分隔的词。`a/b` 算一个词 |
| Tab、Shift+Tab | 补全斜杠命令；菜单打开时切换候选 |
| Ctrl+L | 用当前尺寸重绘编辑块 |
| Ctrl+C | 缓冲区非空时清空。缓冲区为空时退出 `ap-tui` |
| Ctrl+D | 缓冲区非空时删除光标下的字符。缓冲区为空时退出 `ap-tui` |
| Esc | 清空缓冲区 |

输入层还有下面的规则：

- Enter 在 trim 后为空时 `lineedit` 返回空行，`ap-tui` 忽略并重新提示。提交内容保留原始空白和多行换行。
- bracketed paste 的内容原样插入；CRLF 和孤立 CR 归一成 `\n`，不当作按键。超过 8 MiB 时只保留前 8 MiB 并标记 `truncated`，`ap-tui` 不额外提示。
- 粘贴内容里的 C0 控制字符（`\n`、`\t` 除外）会被丢弃，避免 ESC 注入终端。
- legacy 模式下孤立的 ESC 用约 20ms 超时消歧。粘贴终止符被截断时，用 150ms 超时把已收到的内容落地。
- 长行按显示宽度硬折行。CJK、emoji ZWJ、区域旗帜和组合字符使用 grapheme 宽度；tab 按 8 列制表位展开。逻辑行内的 `\n` 强制换行。
- raw 模式下 OPOST 关闭，编辑块内部用 `\r\n`；turn 期间离开 raw，流式输出使用普通 `\n`。
- 多候选时首次 Tab 插入最长公共前缀并在输入块下方显示菜单；再次 Tab/Shift+Tab/↑/↓ 切换并应用候选，Esc 只关菜单，其他按键关闭菜单。菜单最多占终端一半高度，围绕选中项滚动。

### Kitty keyboard protocol

`lineedit` 只用 kitty keyboard protocol 扩展按键信息，不实现 win32-input-mode。完整外部规格见 [refs/keyboard-protocol.rst](refs/keyboard-protocol.rst)，实现细节见 [lineedit.md](lineedit.md)。

进入 raw 时发送 `CSI > 1 u`，打开 disambiguate 位并压栈；退出 raw 时发送 `CSI < u` 弹栈。不发送 `CSI ? u` 查询，也不做 120ms 探测：支持 kitty 的终端发 `CSI u`，不支持的终端继续发 legacy 字节，解码器同时接受两者。legacy 下 Ctrl+Enter/Shift+Enter 不可用；把 Alt 编码为 ESC 前缀的终端可以用 Alt+Enter 插入换行。

解码器需要解析的按键编码只有下面几类。

| 编码 | 含义 |
| --- | --- |
| `CSI <code> ; <mods> u` | 非文本键。`code` 是 Unicode 码点，或 PUA（57344-63743）里的功能键码 |
| `CSI 1 ; <mods> [ABCDEFHPQS]` | 方向键、Home、End 等；无修饰时省略 `1;` |
| `CSI <code> ; <mods> ~` | Delete、Home、End、Insert、PgUp/PgDn 等 |
| `\r`、`0x7f`/`0x08`、`\t` | Enter、Backspace、Tab 的兼容编码 |

`<mods>` 是 `1 + 位掩码`：shift(1)、alt(2)、ctrl(4)、super(8)、hyper(16)、meta(32)、caps_lock(64)、num_lock(128)。编辑器只映射 shift/alt/ctrl；caps_lock/num_lock 接受并忽略；super/hyper/meta 整键按 `Unsupported` 丢弃，不能退化成无修饰插入。参数里用 `:` 分隔的 alternate key、event type、text 子字段对编辑器没有意义，解析时跳过；空字段按默认值处理。

- 方向键和 Home/End 的修饰键按 `CSI 1;<modifier>` 解码，Delete/Home/End 的 `CSI <code>;<modifier> ~` 形式用同一套 modifier 解码。Shift+方向键没有选中语义，按无修饰处理；Ctrl/Alt 参与按词移动和缓冲区首尾跳转。
- 数字小键盘：NumLock 打开且终端处于 application keypad 模式时，数字和 `.` `-` `+` `,` `/` `*` `=`、Enter 走 SS3 序列，按对应字符和提交处理；kitty 打开 disambiguate 后，非文本的小键盘按键改用 PUA 功能键码（`CSI 57414u` = 小键盘 Enter，`CSI 57417-57420u` = 小键盘方向键，`CSI 57423/57424/57426u` = Home/End/Delete），按主键盘对应键处理。NumLock 关闭时的小键盘方向键、Home、End、Delete 与主键盘一致，Insert、PgUp、PgDn 和 Begin 忽略。未识别的 PUA 功能键码丢弃，不能当正文插入。

## 交互命令

| 命令 | 行为 |
| --- | --- |
| `/new` | 丢弃当前 session id，下一条提示词新建 session |
| `/session` | 显示当前 session id。没有 id 时显示“尚未发送提示词” |
| `/help` | 显示命令列表 |
| `/quit`、`/exit` | 退出 |

未知的 `/...` 不当作命令，按普通提示词发送。因此可以直接发送绝对路径等内容。

## 构建与运行

```sh
./build.sh
./build/ap-tui
```

Windows 在 Git Bash 中执行同一个脚本，产物是 `build/ap-tui.exe`：

```powershell
.\build\ap-tui.exe
```

常用启动方式如下。

```sh
./build/ap-tui --agent-bin /path/to/ap
./build/ap-tui -c
./build/ap-tui -s ses_20261022_120000_abcdef123456
```

## 测试

```sh
odin test ap-tui -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
```

测试覆盖下面几类行为。

- `lineedit`：decoder（Kitty/legacy/分片/粘贴/非法 UTF-8/超时）、编辑模型、grapheme 折行、渲染、history、completion、mask/hints、异步 `feed`。
- `ap-tui`：实时流、历史重放、工具输出截断、错误与 turn 结束、session 解析、`prompt_gap`。

真实终端行为（Windows Terminal、Ghostty 等）靠手动验收。

## 已知限制

当前实现有下面的限制。

- 终端 reflow（窗口缩放、重新布局已画内容）可能让编辑块错位。`lineedit` 在每次重绘时重新取尺寸；空闲时不主动重绘。
- turn 运行期间不读 stdin。这期间的按键由终端留在输入缓冲里，turn 结束后会被当成下一条提示词。
- turn 运行期间 Ctrl+C 是内核 `SIGINT`，会同时终止 `ap-tui` 和 `ap`。`ap-tui` 不会回到输入框。
- 不显示 reasoning，也没有 token 或 usage 状态行。
- 输入框没有持久化 history、选中、撤销和鼠标支持。补全只覆盖斜杠命令。

## 相关文档

- [integration.md](integration.md)：进程契约、三个流、turn 生命周期、取消
- [react-loop-and-session.md](react-loop-and-session.md)：事件 schema、恢复与 fork
- [cli-and-config.md](cli-and-config.md)：`ap` 的参数、输出和退出码
- [web.md](web.md)：同为前端的 HTTP/SSE 实现
- [architecture.md](architecture.md)：模块职责与依赖方向
