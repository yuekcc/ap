package main

import "core:os"
import ap "../../ap"

main :: proc() {
	os.exit(ap.run(os.args))
}
