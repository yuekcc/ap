package platform

import "core:fmt"
import "core:os"
import "core:strings"

// 定位 bash。优先 AP_BASH，其次 PATH，最后是常见安装位置。
find_bash :: proc() -> (string, Error) {
	if configured := os.get_env("AP_BASH", context.allocator); len(configured) > 0 {
		if os.exists(configured) {
			return configured, ok_error()
		}
		return "", errorf("AP_BASH points to a missing file: %s", configured)
	}

	path_env := os.get_env("PATH", context.allocator)
	when ODIN_OS == .Windows {
		separator := ";"
		exe_name := "bash.exe"
	} else {
		separator := ":"
		exe_name := "bash"
	}
	dirs, _ := strings.split(path_env, separator)
	for dir in dirs {
		if len(dir) == 0 {
			continue
		}
		candidate := fmt.tprintf("%s/%s", strings.trim_right(dir, `\/`), exe_name)
		when ODIN_OS == .Windows {
			lower, _ := strings.to_lower(candidate, context.temp_allocator)
			if strings.contains(lower, "system32") || strings.contains(lower, "windowsapps") {
				// WSL 的 bash.exe 不是 Git for Windows，跳过。
				continue
			}
		}
		if os.exists(candidate) {
			return candidate, ok_error()
		}
	}

	when ODIN_OS == .Windows {
		candidates := make([dynamic]string, 0, 4)
		append(&candidates, `C:\Program Files\Git\bin\bash.exe`)
		append(&candidates, `C:\Program Files (x86)\Git\bin\bash.exe`)
		if local := os.get_env("LOCALAPPDATA", context.allocator); len(local) > 0 {
			append(&candidates, fmt.tprintf("%s/Programs/Git/bin/bash.exe", local))
		}
		for candidate in candidates {
			if os.exists(candidate) {
				return candidate, ok_error()
			}
		}
	} else {
		for candidate in ([3]string{"/bin/bash", "/usr/bin/bash", "/usr/local/bin/bash"}) {
			if os.exists(candidate) {
				return candidate, ok_error()
			}
		}
	}
	return "", errorf("bash not found in PATH; install Git for Windows (or provide AP_BASH)")
}
