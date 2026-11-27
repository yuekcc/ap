package main

import "core:os"
import aptray "../../ap-tray"

main :: proc() {
	os.exit(aptray.run())
}
