package main

import "core:fmt"
import "core:strings"

// SSE 帧格式固定为 event / data / id 三行加一个空行（docs/web.md「SSE」）。
// id 由 hub 单点分配，编码器只负责按协议写出字节。
sse_encode_event :: proc(b: ^strings.Builder, event: string, data: string, id: u64) {
	fmt.sbprintf(b, "event: %s\n", event)
	sse_write_data_lines(b, data)
	fmt.sbprintf(b, "id: %d\n\n", id)
}

// data 可能含换行（工单要求的 stderr 预览场景）：按 SSE 规范每个物理行都加
// data: 前缀，客户端再拼回 \n。少了这步，换行会直接截断帧结构。
sse_write_data_lines :: proc(b: ^strings.Builder, data: string) {
	start := 0
	for i in 0 ..< len(data) {
		if data[i] != '\n' {
			continue
		}
		fmt.sbprintf(b, "data: %s\n", data[start:i])
		start = i + 1
	}
	fmt.sbprintf(b, "data: %s\n", data[start:])
}

// 心跳注释行：EventSource 会忽略注释内容，代理与浏览器只据此判断连接还活着。
sse_encode_comment :: proc(b: ^strings.Builder, text: string) {
	fmt.sbprintf(b, ": %s\n\n", text)
}

// 一次心跳 = 注释行 + ping 事件；拼成同一个 chunk，调用方一次写出即可。
sse_encode_heartbeat :: proc(b: ^strings.Builder, ts: i64, id: u64) {
	sse_encode_comment(b, "ping")
	sse_encode_event(b, "ping", sse_ping_data(ts), id)
}

// ping 事件的 data（临时分配的短命字符串，编码完即丢弃）。
sse_ping_data :: proc(ts: i64) -> string {
	return fmt.tprintf("{{\"ts\":%d}}", ts)
}
