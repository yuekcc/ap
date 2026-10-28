package main

import "core:os"
import aptui "../../ap-tui"

main :: proc() {
	os.exit(aptui.run(os.args))
}
