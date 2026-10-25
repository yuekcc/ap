package main

import "core:testing"
import "core:strings"

import "../internal"

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

// turn_done 信封的字段顺序固定，前端按字段名读，测试锁住字节序防止漂移。
@(test)
test_sse_turn_done_json :: proc(t: ^testing.T) {
	done := Sse_Turn_Done {
		exit_code      = 0,
		stop_reason    = "stop",
		usage          = internal.Usage{input_tokens = 10, output_tokens = 5, total_tokens = 15},
		stderr_preview = "line one\nline two\n",
	}

	data := sse_turn_done_json(done)
	defer delete(data)

	// JSON 会把 stderr_preview 里的换行转义成 \n（两个字符），所以帧本身仍是单行 data；
	// 含原始换行的多行 data 编码由 test_sse_encode_event_multiline_data 覆盖。
	testing.expect_value(t, data,
		`{"exit_code":0,"stop_reason":"stop",` +
		`"usage":{"input_tokens":10,"output_tokens":5,` +
		`"cached_tokens":null,"reasoning_tokens":null,"total_tokens":15},` +
		`"stderr_preview":"line one\nline two\n"}`)
}

// 没有 turn_end / session_end 时 stop_reason 与 stderr 都是 null，usage 字段全为 null。
@(test)
test_sse_turn_done_json_nulls :: proc(t: ^testing.T) {
	data := sse_turn_done_json(Sse_Turn_Done{exit_code = 1})
	defer delete(data)

	testing.expect_value(t, data,
		`{"exit_code":1,"stop_reason":null,` +
		`"usage":{"input_tokens":null,"output_tokens":null,` +
		`"cached_tokens":null,"reasoning_tokens":null,"total_tokens":null},` +
		`"stderr_preview":null}`)
}
