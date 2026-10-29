# ap-tui

`ap-tui` 是 ap 的交互层，**不是** ap 的一部分。它本身不实现 agent、provider、工具或 transcript 写入；每个用户 turn 都启动一个新的 `ap` 子进程，通过 `stream-json` 读取事件并在终端里滚动渲染。

```
终端 ── ap-tui ──spawn──► ap --print0 --output-format stream-json [-s <id>]
          │                         │
          │◄──── stdout: 事件 ───────┤
          │◄──── stderr: 日志 ───────┤
          │────── stdin: 提示词 ────►
          ▼
    滚动输出 + raw 多行输入框
```

## 为什么是独立进程

ap 的 CLI 契约是「一条提示词进，一个 turn 出，进程退出」。TUI 利用这一契约复用同一套 session、工具和 transcript 逻辑，不把交互状态塞进 ap：

- ap 仍可被脚本、子代理和 TUI 共用
- 路径、project hash、session 发现、blob 读取、spawn/事件泵共用 `ap-core/client` + `ap-core/protocol`，不会各写一套
- TUI 崩溃或重启不会破坏 ap 的写入路径
- 每轮都能看到真实的退出码与 `session_end`

代价是每轮重新启动进程、重新加载配置；phase 1 接受这一点。

## 调用协议

### 命令

```text
ap --print0 --output-format stream-json [ -s <session_id> ] <透传参数>
```

- 提示词走 stdin，以 `--print0` 读取到 EOF；避免 Windows 命令行长度和编码问题
- stdout 解析 `stream-json`：transcript 事件 + `message_update` / `tool_execution_update`
- stderr 在 `--verbose` 时实时显示，否则缓存，只在本轮异常退出时展示
- `--config-dir`、`--model`、`--agent`、`--max-steps`、`--max-tokens` 原样透传

Windows 上 `os.pipe` 两端默认都可继承。启动子进程前必须清掉 stdin 写端、stdout/stderr 读端的继承标志（`ap-core/platform/process_windows.odin` 的 `mark_non_inheritable`，由 `ap-core/client/turn.odin` 调用），否则 ap 会继承 stdin 写端，读 stdin 时永远等不到 EOF。

### 可执行文件查找

按以下顺序找 agent：

1. `--agent-bin <path>`
2. `AP_AGENT_BIN`，其次 `AP_BIN`
3. `ap-tui` 同目录的 `ap.exe`（非 Windows 为 `ap`）
4. PATH 中的 `ap`

找不到时退出码 2。

## Session 管理

ap 一次只处理一个 session，`ap-tui` 也只有一个活动 session。

- 启动不带 `-c` / `-s`：新 session；第一轮不带 `-s`，从 `session_start` 事件拿到 `session_id`
- 之后每轮自动追加 `-s <id>`
- `-c`：在启动时定位当前项目最近的根 session，之后使用显式 `-s`
- `-s <id>`：恢复指定 session
- `/new`：清空当前 id，下一条提示词新建 session；旧 transcript 保留在磁盘上

### 历史重放

启动时如果进入已有 session，`ap-tui` 直接读取：

```text
$AP_CONFIG/projects/<project_path_hash>/<session_id>.jsonl
```

按 v1 transcript 事件重放 `user_message`、`message_end` 的 text 块、工具调用与结果、错误事件。`text_ref` / `content_ref` / `args_ref` 从同目录 `blobs/` 解析；缺失时退化为 `*_preview`。

TUI 与 ap 共用 `ap-core/platform` 的 project 识别规则（绝对路径 → 解析链接 → 反斜杠转 `/` → Windows 小写 → FNV-1a 32 位），通过 `ap-core/client` 暴露给前端。路径规则只维护一份，避免两边漂移后找不到 transcript。

重放只读文件，不重新调用模型、不重新执行工具。

## 渲染

- 普通终端滚动区，**不使用 alternate screen**，输出保留在 scrollback 里
- 每轮结束回到 `› ` 行输入；`› ` 同时用于输入框和 History 重放，提交后无需重画（非 TTY 回退路径仍打印 `> `，保持管道行为不变）
- turn 运行时 TUI 不读 stdin；这期间的按键由终端留在输入缓冲里，turn 结束后会被当成下一条提示词
- ANSI 颜色在 stdout 不是 TTY、`NO_COLOR` 或 `--no-color` 时关闭
- assistant 文本按 delta 实时输出；`message_end` 只在没有 delta 时补文本，避免重复
- 工具调用显示名称和参数；`bash` 的增量输出按两格缩进暗色实时显示；工具结束时显示 `✓/✗`、耗时和退出码
- 非流式工具结果（以及历史重放里的工具结果）最多展示 200 行 / 20000 字节，超出提示完整内容在 transcript；实时 `bash` 流不截断
- reasoning delta 在 phase 1 不展示
- 异常终止（`max_steps` / `max_tokens` / `cancelled` / `context_too_long`）会打印 `turn ended: ...`

## 输入（raw mode 编辑框）

stdin 与 stdout 都是 TTY 时，每轮 turn 前进入 raw mode，用自绘的多行编辑框读取提示词；提交后、turn 开始前离开 raw，把终端交还内核。非 TTY（管道、测试）或 raw mode 进入失败时保留 `bufio` 行输入路径，行为不变。

- 提交：Enter；Ctrl+Enter 插入换行；缓冲区 trim 后为空时不提交，只重绘空提示符
- 移动：←→ 按 rune，↑↓ 按可视行并尽量保持列号，Home/End 与 Ctrl+A/E 到当前逻辑行首尾，Delete/Backspace 删前/后一个 rune（跨行时合并行）
- 删除：Ctrl+K 到逻辑行尾，Ctrl+U 到逻辑行首，Ctrl+W 删前一个空白分隔的词（`a/b` 算一个词）
- Ctrl+C：缓冲区非空时清空并重绘；缓冲区为空时退出 ap-tui。turn 期间 raw 已关闭，Ctrl+C 仍是内核 SIGINT，同时终止 ap-tui 与 ap（下次用 `-c` 继续）
- Esc：清空缓冲区
- 粘贴：bracketed paste，内容原样插入（`\r` 删除、`\n` 保留），不当作按键；整段粘贴只触发一次重绘；超过 1 MiB 截断并插入提示

按键解码优先识别 Kitty keyboard protocol（`CSI u`）。启动时写 `CSI > 1 u` push flags、再写 `CSI ? u` 探测；120ms 内收到 `CSI ? <flags> u` 且 flags & 1 才算支持。探测失败时留在 raw：方向键、Home/End、Delete 与 legacy 控制字节仍可用，但拿不到 Ctrl+Enter，启动时提示一次 `terminal does not report kitty keyboard protocol: Ctrl+Enter unavailable`。legacy 下孤立的 ESC 用 ~20ms 超时消歧。

长行按显示宽度硬折行（`unicode.normalized_east_asian_width`：CJK/全角 2 列，组合字符 0 列），逻辑行内的 `\n` 强制换行。首行前缀 `› `（加粗青色），续行缩进两格。超过屏幕高度时保留光标所在行，裁掉的内容用首行 `  …` 提示；不进入滚动区（DECSTBM）。

已知限制：

- 终端 reflow（窗口缩放、重新布局已画内容）可能让编辑块错位；编辑块会在下一次按键重绘时按新尺寸重新 layout，空闲时不主动重绘，也不修复终端已改写的 scrollback
- emoji 的 ZWJ 序列与变体选择符按 1 列处理，光标可能视觉偏移
- 粘贴内容中的控制字符（如 ESC）会原样进入缓冲区并显示；不要粘贴不可信内容

## 交互命令

| 命令 | 行为 |
| --- | --- |
| `/new` | 丢弃当前 session id，下一条提示词开新 session |
| `/session` | 显示当前 session id |
| `/help` | 显示命令 |
| `/quit` / `/exit` | 退出 |

未知的 `/...` 不作为命令，按普通提示词发送，因此可以直接发绝对路径等内容。

## 构建与运行

入口在 `cmd/ap-tui`（`os.exit(aptui.run(os.args))`）；`ap-tui/` 本身只是 `package aptui` 库，不定义 `main`。

```sh
./build.sh
./bin/ap-tui

# 或显式指定 agent
./bin/ap-tui --agent-bin /path/to/ap

# 继续当前项目最近的 session
./bin/ap-tui -c

# 恢复指定 session
./bin/ap-tui -s ses_20261022_120000_abcdef123456
```

Windows：

```powershell
.\build.ps1
.\ap-tui.exe
```

## 测试

```sh
odin test ap-tui -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
```

覆盖：事件解析、参数格式化、工具输出截断、live/history 渲染、project hash、最近根 session 定位、transcript 重放与 blob 解析；输入层另有按键解码（Kitty / legacy / 分片 / 粘贴 / 非法 UTF-8）、编辑模型（插入删除、跨行、↑↓ 保列、Ctrl 键、1 MiB 上限）、折行排版（CJK 双宽、空行、折行点）与重绘输出。真实终端行为（Windows Terminal / Ghostty）靠手动验收。

## Phase 2 待做

1. 运行中显示输入框 / 排队下一条提示词（当前 turn 进行时不能输入）
2. Ctrl+C 的 TUI 侧处理：取消当前 turn 后回到输入框，而不是退出 ap-tui
3. 更好的工具展示：可折叠、按工具类型定制、diff 着色
4. `/resume` 列表、`/fork`、session 删除/清理
5. reasoning 展示开关、token/usage 状态行
6. 输入框增强：方向键 history、选中/撤销、鼠标、组合输入法预编辑
