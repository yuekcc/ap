package main

import "core:fmt"
import "core:os"
import lineedit ".."

main :: proc() {
	le: lineedit.Line_Editor
	if !lineedit.line_editor_init_file(&le, os.stdin, os.stdout) {
		fmt.eprintln("lineedit: failed to initialize")
		os.exit(1)
	}
	defer lineedit.line_editor_destroy(&le)

	fmt.println("lineedit demo：Ctrl+D 退出")
	for {
		line, status := lineedit.line_editor_read_line(&le, "> ")
		switch status {
		case .Ok:
			// raw 模式下 OPOST 关闭，先离开 raw 再普通打印，下一轮再进入。
			if le.raw {
				lineedit.line_editor_leave_raw(&le)
				fmt.printf("line: %q\n", line)
				if !lineedit.line_editor_enter_raw(&le) {
					delete(line)
					return
				}
			} else {
				fmt.printf("line: %q\n", line)
			}
			delete(line)
		case .Eof, .Cancel:
			return
		case .Error:
			return
		}
	}
}
