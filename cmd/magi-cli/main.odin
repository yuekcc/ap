package main

import "core:os"
import magicli "../../magi-cli"

main :: proc() {
	os.exit(magicli.run(os.args))
}
