package main

import "core:os"
import magi "../../magi"

main :: proc() {
	os.exit(magi.run(os.args))
}
