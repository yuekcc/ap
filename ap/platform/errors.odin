package platform

import "core:fmt"

// ap 与 ap-tui 共用的轻量错误：空 message 表示成功。
// ap 在边界处把它映射成自己的 Exit_Code。
Error :: struct {
	message: string,
}

ok_error :: proc() -> Error {
	return {}
}

errorf :: proc(format: string, args: ..any) -> Error {
	return {message = fmt.tprintf(format, ..args)}
}

is_ok :: proc(err: Error) -> bool {
	return len(err.message) == 0
}
