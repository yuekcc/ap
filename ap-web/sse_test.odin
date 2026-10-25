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
