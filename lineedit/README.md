# lineedit

Odin 写的独立行编辑器，目标是替代 `ap-tui` 的 prompt，也可以单独作为 readline 的替代品。只依赖 `core:` / `base:`，不依赖 ap 的本地包。

## 用法

```odin
import "core:fmt"
import "core:os"
import lineedit "../lineedit"

main :: proc() {
	le: lineedit.Line_Editor
	if !lineedit.line_editor_init_file(&le, os.stdin, os.stdout) {
		return
	}
	defer lineedit.line_editor_destroy(&le)

	for {
		line, status := lineedit.line_editor_read_line(&le, "> ")
		switch status {
		case .Ok:
			// raw 模式下 OPOST 关闭，打印前先离开 raw。
			lineedit.line_editor_leave_raw(&le)
			fmt.println("echo:", line)
			lineedit.line_editor_enter_raw(&le)
			delete(line)
		case .Eof, .Cancel:
			return
		case .Error:
			return
		}
	}
}
```

示例程序在 `lineedit/example/`，可以手动跑：

```sh
odin run lineedit/example
```

默认配置包含 100 条 history、1 MiB 输入上限、kitty flag 1 和 bracketed paste。历史持久化：

```odin
lineedit.history_add(&le.history, "some command")
lineedit.history_save(&le.history, "history.txt")
lineedit.history_load(&le.history, "history.txt")
```

异步事件循环用 `line_editor_begin` / `feed` / `timeout` / `poll_timeout`；需要在编辑块中间打印输出时用 `hide` / `show`。完整 API 和契约见 [docs/internal/lineedit.md](../docs/internal/lineedit.md)。

## 能力

- 多行编辑、CJK/emoji grapheme 宽度、硬折行、滚动窗口。
- legacy VT100/ANSI 输入永久保留；kitty keyboard protocol 只启用 `flag 1`（disambiguate），不探测、不查询。
- bracketed paste，CRLF/CR 归一成 LF。
- history 上下浏览、草稿恢复、保存/加载。
- mask、hints、token completion、异步 hide/show。
- Windows 使用 VT input + console mode；Unix 使用 termios + poll。

## 测试

```sh
odin test lineedit -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
```

测试通过 `Transport` 注入脚本化输入，并用最小 VT100 `Screen` 模型验证屏幕内容与光标位置，不依赖真实 tty。
