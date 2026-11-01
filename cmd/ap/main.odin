package main

import "core:os"
import apcli "../../ap-cli"

main :: proc() {
	os.exit(apcli.run(os.args))
}
