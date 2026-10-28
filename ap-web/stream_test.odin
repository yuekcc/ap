package apweb

import "core:strings"
import "core:testing"

// 流式响应（SSE）必须先把头写成 chunked，再由 handler 持续写 chunk。
// 这里直接用 Test_Transport 驱动完整的连接状态机，断言线上字节。
@(test)
test_serve_connection_stream_chunked :: proc(t: ^testing.T) {
	transport := test_transport("GET /api/events HTTP/1.1\r\n\r\n")

	stream_handler :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
		response_set_header(response, "Content-Type", "text/event-stream")
		response_set_header(response, "Cache-Control", "no-cache")
		if !response_stream_start(response) {
			return
		}
		_ = response_stream_write(response, transmute([]byte)string("event: ap\ndata: {}\n\n"))
		_ = response_stream_write(response, transmute([]byte)string(": ping\n\n"))
		response_stream_end(response)
	}

	serve_connection(
		{user = &transport, recv = test_transport_recv, send = test_transport_send},
		stream_handler,
		nil,
	)

	out := test_transport_output(&transport)
	testing.expect(t, strings.has_prefix(out, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(out, "Content-Type: text/event-stream\r\n"))
	testing.expect(t, strings.contains(out, "Cache-Control: no-cache\r\n"))
	testing.expect(t, strings.contains(out, "Transfer-Encoding: chunked\r\n"))
	testing.expect(t, strings.contains(out, "Connection: close\r\n"))
	testing.expect(t, !strings.contains(out, "Content-Length"))

	// 每个 frame 一个 chunk，最后是终止 chunk；只有一份响应头。
	expected := strings.concatenate(
		{
			"14\r\n",
			"event: ap\ndata: {}\n\n",
			"\r\n",
			"8\r\n",
			": ping\n\n",
			"\r\n",
			"0\r\n\r\n",
		},
		context.temp_allocator,
	)
	testing.expect_value(t, strings.count(out, "HTTP/1.1"), 1)
	testing.expect(t, strings.has_suffix(out,
		expected))
	testing.expect_value(t, strings.count(out, "0\r\n\r\n"), 1)
}

// 写失败（连接 reset/EPIPE）时 write 返回 false，handler 应停止循环；
// 服务器不会再拼一个终止 chunk 去写已死的 socket。
@(test)
test_stream_write_reports_failure :: proc(t: ^testing.T) {
	transport := Test_Transport{max_read = 7}
	response := Http_Response{}
	response.stream.transport = {user = &transport, recv = test_transport_recv, send = test_transport_send}
	transport.fail_send = true
	response_set_header(&response, "Content-Type", "text/event-stream")

	testing.expect(t, !response_stream_start(&response))
}

// 没有走流式路径的响应必须保持原样（定长 + Content-Length）。
@(test)
test_fixed_length_path_unchanged :: proc(t: ^testing.T) {
	transport := test_transport("GET /plain HTTP/1.1\r\n\r\n")
	plain_handler :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
		response_text(response, 200, "hello")
	}
	serve_connection(
		{user = &transport, recv = test_transport_recv, send = test_transport_send},
		plain_handler,
		nil,
	)
	out := test_transport_output(&transport)
	testing.expect(t, strings.has_suffix(out, "\r\n\r\nhello"))
	testing.expect(t, strings.contains(out, "Content-Length: 5\r\n"))
	testing.expect(t, !strings.contains(out, "Transfer-Encoding"))
}
