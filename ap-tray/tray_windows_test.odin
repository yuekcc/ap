#+build windows
package aptray

import "core:testing"
import win "core:sys/windows"

@(test)
test_icon_from_invalid_ico_is_nil :: proc(t: ^testing.T) {
	testing.expect(t, icon_from_ico("not an ico file") == nil)
	testing.expect(t, icon_from_ico("") == nil)
}

@(test)
test_embedded_tray_ico_loads :: proc(t: ^testing.T) {
	testing.expect(t, len(TRAY_ICON_DATA) > 0)
	icon := load_icon()
	testing.expect(t, icon != nil)
	if icon != nil {
		_ = win.DestroyIcon(icon)
	}
}
