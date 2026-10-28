package main

import "core:os"
import apweb "../../ap-web"

main :: proc() {
	os.exit(apweb.run(os.args))
}
