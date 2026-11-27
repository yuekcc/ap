#+build !windows
package aptray

import "core:fmt"

run :: proc() -> int {
	fmt.eprintln("ap-tray 只支持 Windows")
	return 1
}
