# lineedit：独立 Odin 行编辑器

`lineedit/` 是一个独立包，目标是替代 `ap-tui` 的 prompt 编辑器，也可以单独当作 readline 的替代品使用。它只 import `core:` / `base:` / `vendor:`，不依赖 ap 的本地包，因此以后可以整体迁出仓库。

## 状态

已实现：

- UTF-8、grapheme cluster、CJK、emoji ZWJ、区域旗帜、组合字符的显示宽度。
- 多行编辑、硬折行、可视行滚动、光标列保持。
- legacy VT100/ANSI 输入，永久保留。
- kitty keyboard protocol，仅 push `flag 1`（disambiguate），不 query、不 probe。
- bracketed paste，CRLF/CR 归一成 LF，C0 控制字符（`\n`/`\t` 除外）丢弃，超大粘贴标记 `truncated`。
- 编辑动作：插入、删除、词移动、行首行尾、Ctrl+A/E/K/U/W、Ctrl+C/D/L、上下移动。
- history：添加、上下浏览、草稿恢复、最大长度、文件保存/加载。
- mask 模式：每个 grapheme 显示为一个 `*`。
- hints：右侧提示，提交前自动剥离。
- completion：单候选替换当前 token；多候选插入最长公共前缀。
- Windows VT input / console mode，Unix termios + poll。
- raw 模式生命周期：`line_editor_enter_raw` / `line_editor_leave_raw`。
- 异步事件循环：`line_editor_begin` / `feed` / `timeout` / `poll_timeout` / `resize` / `abort_line`，以及中间打印输出用的 `hide` / `show`。
- `ap-tui` 的 prompt 已迁移到 `lineedit`；旧 `editor*.odin`、`keys.odin`、`term*.odin` 已删除。

未实现（后续）：

- 补全候选菜单与 Shift+Tab 反向循环。
- 持久化 history（`ap-tui` 目前只在进程内保留）。

## 分层

| 文件 | 职责 |
| --- | --- |
| `decoder.odin` | 字节流 → `Key` / `Paste` / `Unsupported` 事件，纯状态机 |
| `editor.odin` | buffer、cursor、编辑动作、token/completion、垂直移动 |
| `layout.odin` | `(buffer, cursor, cols, prefix)` → 行区间与光标列 |
| `render.odin` | 编辑状态 → 终端字节输出；mask、hints、滚动窗口 |
| `history.odin` | 历史条目、浏览位置、文件持久化 |
| `line_editor.odin` | 顶层 `Line_Editor`，组合 decoder/editor/render/history/transport |
| `term.odin` | `Transport` 接口与平台无关契约 |
| `term_windows.odin` / `term_unix.odin` | raw mode、读取、写入、尺寸 |
| `complete.odin` | 补全回调与候选所有权 |

## 输入协议

legacy 是永久路径，kitty 只是渐进增强：

- `line_editor_init` 在 raw 成功后写 `CSI > 1 u` 和 `CSI ? 2004 h`；`leave_raw` 写 `CSI < u` 和 `CSI ? 2004 l`。
- 不做 kitty 探测。终端支持时发 `CSI u`，不支持时发 legacy 字节；解码器同时接受两者。
- 只有 `Decoder` 状态不完整时才使用超时：`ESC_TIMEOUT_MS = 20`，粘贴等待 `PASTE_FLUSH_MS = 150`。
- 无法识别的序列产生 `Unsupported`，绝不会把转义字节插入正文。
- 非 tty（管道/CI）不走 raw 和渲染，按行读取。

## 异步事件循环

`line_editor_read_line` 只是阻塞封装；外部事件循环可以直接用：

1. `line_editor_begin(le, prompt)` 开始一行，复制 prompt 并画出初始帧。
2. stdin 可读时调用 `line_editor_feed(le, bytes)`；返回 `.Submitted` 时 `line` 由调用方释放。
3. poll 超时后调用 `line_editor_timeout(le)`；超时值用 `line_editor_poll_timeout(le)`，`-1` 表示无限等。
4. 窗口变化时调用 `line_editor_resize(le)`。
5. 需要打印异步输出时先 `line_editor_hide(le)`，输出结束后 `line_editor_show(le)`。
6. 信号或外部取消调用 `line_editor_abort_line(le)`。

`begin` 会在需要时自动 `enter_raw`；如果调用方在两轮之间离开 raw，下一次 `begin` 会重新进入。

## 渲染契约

- `layout` 使用 `core:unicode/utf8` 的 grapheme iterator，不自己维护宽度表。
- tab 按 8 列制表位展开，layout 与 render 使用同一规则。
- 折行点上的光标属于下一行；硬换行前的光标留在本行行尾。
- 需要滚动时首行让给 `…`，内容区少一行。
- mask 模式按 grapheme 输出一个 `*`，换行保留，光标列按掩码后的缓冲区计算。
- hints 画在最后一条逻辑行右侧，不参与布局；提交前用不带 hint 的帧重画。
- `Renderer` 只记住上一帧的 `drawn` 和 `cursor_row`，用相对移动清屏重绘。

## 所有权

- `line_editor_read_line` 返回的 string 由调用方 `delete`。
- `Completion.text` / `Completion.description` 由补全回调用 `context.allocator` 分配，编辑器用完后 `delete`。候选按“替换当前 token”解释。
- `Hint_Proc` 返回的 string 只在当前帧内有效，编辑器不释放。
- `Transport.destroy` 由 `line_editor_destroy` 调用；fake transport 可以留空。

## 测试

```sh
odin test lineedit -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
```

测试不依赖真实 tty：

- `screen_test.odin` 是最小 VT100 屏幕模型，验证渲染后的屏幕内容和光标位置。
- `line_editor_test.odin` 用脚本化 fake transport 驱动顶层 API，覆盖提交、编辑、kitty、paste、取消/EOF、history、mask、hints、completion、pipe 模式与 raw 生命周期。
- `odin check lineedit -target:linux_amd64 -no-entry-point` 与 darwin 交叉检查通过。

## 包边界

`lineedit` 不属于 ap 的六包依赖图。它只允许 `core:` / `base:` / `vendor:`，不得 import `ap-core/*`、`ap-cli/*`、`ap-tui/*`、`ap-web/*` 或 `magi/*`。`ap-tui` 可以 import `lineedit`，`ap-web` 不可以。迁移到独立仓库时不需要改 import。
