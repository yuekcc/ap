#+build windows
package main

import "../internal"

setup_console :: proc() {
	internal.setup_console()
}

normalize_args :: proc(args: []string) -> []string {
	return internal.normalize_args(args)
}
