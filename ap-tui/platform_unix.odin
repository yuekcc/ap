#+build !windows
package tui

import "../ap/platform"
import "core:os"

setup_console :: proc() {
	platform.setup_console()
}

normalize_args :: proc(args: []string) -> []string {
	return platform.normalize_args(args)
}

mark_non_inheritable :: proc(file: ^os.File) {
}
