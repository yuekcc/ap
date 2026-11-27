package aptray

import "core:strings"
import "core:testing"

@(test)
test_web_command_line_quotes_path :: proc(t: ^testing.T) {
	line := web_command_line("C:\\Program Files\\ap\\ap-web.exe")
	testing.expect_value(t, line, "\"C:\\Program Files\\ap\\ap-web.exe\"")
}

@(test)
test_web_exe_path_joins_binary :: proc(t: ^testing.T) {
	path := web_exe_path("C:\\build")
	testing.expect(t, strings.has_suffix(path, "\\ap-web.exe"))
	testing.expect_value(t, WEB_EXE, "ap-web.exe")
}
