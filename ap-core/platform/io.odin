package platform

import "core:os"

// 写满整个切片；stdout、子进程 stdin 等都可能出现短写。
write_all :: proc(file: ^os.File, data: []byte) -> bool {
	remaining := data
	for len(remaining) > 0 {
		n, err := os.write(file, remaining)
		if err != nil || n <= 0 {
			return false
		}
		remaining = remaining[n:]
	}
	return true
}
