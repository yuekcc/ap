package main

import "core:os"
import apcore "../../ap-core"

main :: proc() {
	os.exit(apcore.run(os.args))
}
