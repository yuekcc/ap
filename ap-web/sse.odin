package main

import "core:fmt"
import "core:strings"

// SSE 帧格式固定为 event / data / id 三行加一个空行（docs/web.md「SSE」）。
// id 由 hub 单点分配，编码器只负责按协议写出字节。
sse_encode_event :: proc(b: ^strings.Builder, event: string, data: string, id: u64) {
	fmt.sbprintf(b, "event: %s\n", event)
	fmt.sbprintf(b, "data: %s\n", data)
	fmt.sbprintf(b, "id: %d\n\n", id)
}
