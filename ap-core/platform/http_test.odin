package platform

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

// 本机假服务器：不碰外网，只用它验证传输层的状态码、分块回调、超时与取消。
Test_Response :: struct {
	status_line:   string,
	headers:       []string,
	parts:         []string,
	head_delay_ms: int,
	part_delay_ms: int,
}

Test_Server :: struct {
	listener: net.TCP_Socket,
	port:     int,
	handle:   ^thread.Thread,
	response: Test_Response,
}

test_server_thread :: proc(data: rawptr) {
	server := (^Test_Server)(data)
	client, _, accept_err := net.accept_tcp(server.listener)
	if accept_err != nil {
		return
	}
	defer net.close(client)

	if !test_server_read_request(client) {
		return
	}
	if server.response.head_delay_ms > 0 {
		time.sleep(time.Duration(server.response.head_delay_ms) * time.Millisecond)
	}
	head := strings.concatenate({server.response.status_line, "\r\n"}, context.temp_allocator)
	for header in server.response.headers {
		head = strings.concatenate({head, header, "\r\n"}, context.temp_allocator)
	}
	head = strings.concatenate({head, "\r\n"}, context.temp_allocator)
	if _, err := net.send_tcp(client, transmute([]byte)head); err != nil {
		return
	}
	for part in server.response.parts {
		if server.response.part_delay_ms > 0 {
			time.sleep(time.Duration(server.response.part_delay_ms) * time.Millisecond)
		}
		if _, err := net.send_tcp(client, transmute([]byte)part); err != nil {
			return
		}
	}
	// 关闭连接：客户端因此收到 EOF，等同于 provider 看到的流结束。
}

test_server_read_request :: proc(client: net.TCP_Socket) -> bool {
	buf: [32 * 1024]byte
	got := 0
	for {
		if got >= len(buf) {
			return false
		}
		n, err := net.recv_tcp(client, buf[got:])
		if err != nil || n <= 0 {
			return false
		}
		got += n
		text := string(buf[:got])
		head_end := strings.index(text, "\r\n\r\n")
		if head_end < 0 {
			continue
		}
		if got - (head_end + 4) >= test_response_content_length(text[:head_end]) {
			return true
		}
	}
}

test_response_content_length :: proc(headers: string) -> int {
	lower, _ := strings.to_lower(headers, context.temp_allocator)
	for line in strings.split_lines_iterator(&lower) {
		if strings.has_prefix(line, "content-length:") {
			value := strings.trim_space(line[len("content-length:"):])
			if length, ok := strconv.parse_int(value, 10); ok {
				return length
			}
		}
	}
	return 0
}

// 服务器结构体放在堆上：线程持有它的指针，不能指向 test_server_start 的栈上返回值。
test_server_start :: proc(t: ^testing.T, response: Test_Response) -> ^Test_Server {
	listener, listen_err := net.listen_tcp(net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = 0,
	})
	testing.expect(t, listen_err == nil, "cannot listen on loopback")
	if listen_err != nil {
		return nil
	}
	endpoint, endpoint_err := net.bound_endpoint(listener)
	testing.expect(t, endpoint_err == nil, "cannot read bound endpoint")

	server := new(Test_Server)
	server.listener = listener
	server.port = endpoint.port
	server.response = response
	server.handle = thread.create_and_start_with_data(server, test_server_thread)
	return server
}

test_server_stop :: proc(server: ^Test_Server) {
	if server == nil {
		return
	}
	net.close(server.listener)
	if server.handle != nil {
		thread.join(server.handle)
		thread.destroy(server.handle)
		server.handle = nil
	}
	free(server)
}

test_server_url :: proc(server: ^Test_Server) -> string {
	return fmt.tprintf("http://127.0.0.1:%d/chat/completions", server.port)
}

Test_Collector :: struct {
	chunks:      [dynamic]string,
	statuses:    [dynamic]int,
	abort_after: int,
}

test_collector_destroy :: proc(c: ^Test_Collector) {
	for chunk in c.chunks {
		delete(chunk)
	}
	delete(c.chunks)
	delete(c.statuses)
}

test_collect_body :: proc(user: rawptr, status: int, data: []byte) -> bool {
	collector := (^Test_Collector)(user)
	append(&collector.chunks, strings.clone(string(data)))
	append(&collector.statuses, status)
	if collector.abort_after > 0 && len(collector.chunks) >= collector.abort_after {
		return false
	}
	return true
}

test_joined_body :: proc(collector: ^Test_Collector) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	for chunk in collector.chunks {
		strings.write_string(&builder, chunk)
	}
	return strings.to_string(builder)
}

@(test)
test_http_stream_sse_chunks_and_status :: proc(t: ^testing.T) {
	server := test_server_start(t, {
		status_line = "HTTP/1.1 200 OK",
		headers = {"Content-Type: text/event-stream"},
		parts = {"data: {\"a\":1}\n\n", "data: [DONE]\n\n"},
		part_delay_ms = 20,
	})
	defer test_server_stop(server)

	collector: Test_Collector
	defer test_collector_destroy(&collector)
	cancel: Cancel_Token

	res := http_stream(&{
		url = test_server_url(server),
		headers = {"Content-Type: application/json"},
		body = transmute([]byte)string(`{"stream":true}`),
		total_timeout_ms = 5000,
		first_byte_timeout_ms = 5000,
		cancel = &cancel,
		user = &collector,
		on_body = test_collect_body,
	})

	testing.expect_value(t, res.failure, Http_Failure.None)
	testing.expect_value(t, res.status, 200)
	testing.expect_value(t, len(collector.chunks), 2)
	for status in collector.statuses {
		testing.expect_value(t, status, 200)
	}
	testing.expect_value(t, test_joined_body(&collector), "data: {\"a\":1}\n\ndata: [DONE]\n\n")
}

@(test)
test_http_stream_retry_after_and_error_body :: proc(t: ^testing.T) {
	server := test_server_start(t, {
		status_line = "HTTP/1.1 429 Too Many Requests",
		headers = {"Content-Type: application/json", "Retry-After: 3"},
		parts = {`{"error":{"message":"slow down"}}`},
	})
	defer test_server_stop(server)

	collector: Test_Collector
	defer test_collector_destroy(&collector)
	cancel: Cancel_Token

	res := http_stream(&{
		url = test_server_url(server),
		body = transmute([]byte)string("{}"),
		total_timeout_ms = 5000,
		cancel = &cancel,
		user = &collector,
		on_body = test_collect_body,
	})

	testing.expect_value(t, res.failure, Http_Failure.None)
	testing.expect_value(t, res.status, 429)
	retry_after, has_retry_after := res.retry_after_ms.?
	testing.expect(t, has_retry_after)
	testing.expect_value(t, retry_after, 3000)
	testing.expect_value(t, len(collector.chunks), 1)
	testing.expect_value(t, collector.statuses[0], 429)
	testing.expect_value(t, test_joined_body(&collector), `{"error":{"message":"slow down"}}`)
}

@(test)
test_http_stream_abort_on_body_rejection :: proc(t: ^testing.T) {
	server := test_server_start(t, {
		status_line = "HTTP/1.1 200 OK",
		parts = {"data: one\n\n", "data: two\n\n"},
	})
	defer test_server_stop(server)

	collector: Test_Collector
	defer test_collector_destroy(&collector)
	collector.abort_after = 1
	cancel: Cancel_Token

	res := http_stream(&{
		url = test_server_url(server),
		body = transmute([]byte)string("{}"),
		total_timeout_ms = 5000,
		cancel = &cancel,
		user = &collector,
		on_body = test_collect_body,
	})

	// 回调拒绝后立即中止传输，调用方据自己的失败原因判断结果。
	testing.expect_value(t, res.failure, Http_Failure.Network)
	testing.expect_value(t, len(collector.chunks), 1)
}

@(test)
test_http_stream_cancelled_before_request :: proc(t: ^testing.T) {
	cancel: Cancel_Token
	cancel_token_cancel(&cancel)

	res := http_stream(&{
		url = "http://127.0.0.1:9/chat/completions",
		body = transmute([]byte)string("{}"),
		cancel = &cancel,
	})

	testing.expect_value(t, res.failure, Http_Failure.Cancelled)
}

@(test)
test_http_stream_connection_refused :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp(net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = 0,
	})
	testing.expect(t, listen_err == nil, "cannot listen on loopback")
	if listen_err != nil {
		return
	}
	endpoint, _ := net.bound_endpoint(listener)
	net.close(listener)

	res := http_stream(&{
		url = fmt.tprintf("http://127.0.0.1:%d/chat/completions", endpoint.port),
		body = transmute([]byte)string("{}"),
		total_timeout_ms = 5000,
	})

	testing.expect_value(t, res.failure, Http_Failure.Network)
}

Cancel_After :: struct {
	token:    ^Cancel_Token,
	delay_ms: int,
}

cancel_after_thread :: proc(data: rawptr) {
	job := (^Cancel_After)(data)
	time.sleep(time.Duration(job.delay_ms) * time.Millisecond)
	cancel_token_cancel(job.token)
}

// 传输中的取消依赖进度回调轮询，只有它真的被调用，取消才能中断在途请求。
@(test)
test_http_stream_cancel_during_request :: proc(t: ^testing.T) {
	server := test_server_start(t, {
		status_line = "HTTP/1.1 200 OK",
		parts = {"data: [DONE]\n\n"},
		head_delay_ms = 1500,
	})
	defer test_server_stop(server)

	cancel: Cancel_Token
	job := Cancel_After {
		token    = &cancel,
		delay_ms = 100,
	}
	handle := thread.create_and_start_with_data(&job, cancel_after_thread)

	started := time.tick_now()
	res := http_stream(&{
		url = test_server_url(server),
		body = transmute([]byte)string("{}"),
		total_timeout_ms = 30000,
		cancel = &cancel,
	})
	elapsed := time.tick_since(started)
	if handle != nil {
		thread.join(handle)
		thread.destroy(handle)
	}

	testing.expect_value(t, res.failure, Http_Failure.Cancelled)
	testing.expect(t, elapsed < 1200 * time.Millisecond, "cancel did not abort the in-flight request")
}

@(test)
test_http_stream_first_byte_timeout :: proc(t: ^testing.T) {
	server := test_server_start(t, {
		status_line = "HTTP/1.1 200 OK",
		parts = {"data: [DONE]\n\n"},
		head_delay_ms = 1500,
	})
	defer test_server_stop(server)

	cancel: Cancel_Token
	started := time.tick_now()
	res := http_stream(&{
		url = test_server_url(server),
		body = transmute([]byte)string("{}"),
		total_timeout_ms = 30000,
		first_byte_timeout_ms = 100,
		cancel = &cancel,
	})

	testing.expect_value(t, res.failure, Http_Failure.First_Byte_Timeout)
	testing.expect(t, time.tick_since(started) < 1200 * time.Millisecond, "first byte timeout did not abort early")
}
