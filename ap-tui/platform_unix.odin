#+build !windows
package tui

import "../internal"
import "core:os"

setup_console :: proc() {
	internal.setup_console()
}

normalize_args :: proc(args: []string) -> []string {
	return internal.normalize_args(args)
}

mark_non_inheritable :: proc(file: ^os.File) {
}
