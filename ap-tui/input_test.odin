package aptui

import lineedit "../lineedit"

import "core:testing"

clear_completions :: proc(out: ^[dynamic]lineedit.Completion) {
	for c in out^ {
		delete(c.text)
		delete(c.description)
	}
	clear(out)
}

@(test)
test_tui_complete_commands :: proc(t: ^testing.T) {
	out: [dynamic]lineedit.Completion
	defer {
		clear_completions(&out)
		delete(out)
	}

	tui_complete(nil, "/", 1, &out)
	testing.expect_value(t, len(out), len(TUI_COMMANDS))

	clear_completions(&out)
	tui_complete(nil, "/h", 2, &out)
	testing.expect_value(t, len(out), 1)
	if len(out) == 1 {
		testing.expect_value(t, out[0].text, "/help")
		testing.expect(t, len(out[0].description) > 0)
	}

	clear_completions(&out)
	tui_complete(nil, "/s", 2, &out)
	testing.expect_value(t, len(out), 1)
	if len(out) == 1 {
		testing.expect_value(t, out[0].text, "/session")
	}

	clear_completions(&out)
	tui_complete(nil, "hello", 5, &out)
	testing.expect_value(t, len(out), 0)

	clear_completions(&out)
	tui_complete(nil, "/h foo", 6, &out)
	testing.expect_value(t, len(out), 0)
}
