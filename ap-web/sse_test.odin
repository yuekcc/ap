package main

import "core:testing"
import "core:strings"

// SSE 帧是逐字节的协议：测试直接断言完整输出，不用 contains 之类宽松匹配。
@(test)
test_sse_encode_event :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	sse_encode_event(&b, "ap", `{"type":"message_update","delta":{"text":"hi"}}`, 42)

	testing.expect_value(t, strings.to_string(b),
		"event: ap\n" +
		`data: {"type":"message_update","delta":{"text":"hi"}}` + "\n" +
		"id: 42\n\n")
}

// data 里的换行必须编码成多个 data: 行，否则客户端只会看到第一行。
@(test)
test_sse_encode_event_multiline_data :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	sse_encode_event(&b, "log", "alpha\nbeta\n", 7)

	testing.expect_value(t, strings.to_string(b),
		"event: log\n" +
		"data: alpha\n" +
		"data: beta\n" +
		"data: \n" +
		"id: 7\n\n")
}

@(test)
test_sse_encode_comment :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	sse_encode_comment(&b, "ping")

	testing.expect_value(t, strings.to_string(b), ": ping\n\n")
}

// 心跳 = 注释行 + ping 事件，拼成一个 chunk 便于调用方一次写出。
@(test)
test_sse_encode_heartbeat :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	sse_encode_heartbeat(&b, 1700000000, 9)

	testing.expect_value(t, strings.to_string(b),
		": ping\n\n" +
		"event: ping\n" +
		"data: {\"ts\":1700000000}\n" +
		"id: 9\n\n")
}
