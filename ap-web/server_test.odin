package main

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

test_parse :: proc(request: string) -> Request_Parse {
	return parse_request_bytes(transmute([]byte)request)
}

@(test)
test_parse_simple_get :: proc(t: ^testing.T) {
	parsed := test_parse("GET /foo?a=1 HTTP/1.1\r\nHost: example\r\n\r\n")
	testing.expect_value(t, parsed.state, Parse_State.Complete)
	testing.expect_value(t, parsed.request.method, Http_Method.Get)
	testing.expect_value(t, parsed.request.path, "/foo")
	testing.expect_value(t, parsed.request.query, "a=1")
	testing.expect_value(t, parsed.request.version, "HTTP/1.1")
	testing.expect_value(t, parsed.request.keep_alive, true)
	testing.expect_value(t, len(parsed.request.headers), 1)
	testing.expect_value(t, len(parsed.request.body), 0)
}

@(test)
test_parse_incomplete_header :: proc(t: ^testing.T) {
	parsed := test_parse("GET / HTTP/1.1\r\nHost: example\r\n")
	testing.expect_value(t, parsed.state, Parse_State.Incomplete)

	parsed2 := test_parse("GET / HTTP/1.1\r\nHost: example\r\n\r\n")
	testing.expect_value(t, parsed2.state, Parse_State.Complete)
}

@(test)
test_parse_line_too_long :: proc(t: ^testing.T) {
	long := strings.repeat("a", MAX_HEADER_LINE, context.temp_allocator)
	request := strings.concatenate({"GET /", long, " HTTP/1.1\r\n\r\n"}, context.temp_allocator)
	parsed := test_parse(request)
	testing.expect_value(t, parsed.state, Parse_State.Error)
	testing.expect_value(t, parsed.status, 400)
}

@(test)
test_parse_too_many_headers :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "GET / HTTP/1.1\r\n")
	for _ in 0 ..< MAX_HEADERS + 1 {
		strings.write_string(&b, "X-Test: v\r\n")
	}
	strings.write_string(&b, "\r\n")
	parsed := test_parse(strings.to_string(b))
	testing.expect_value(t, parsed.state, Parse_State.Error)
	testing.expect_value(t, parsed.status, 400)
}

@(test)
test_parse_malformed_header :: proc(t: ^testing.T) {
	parsed := test_parse("GET / HTTP/1.1\r\nBroken\r\n\r\n")
	testing.expect_value(t, parsed.state, Parse_State.Error)
	testing.expect_value(t, parsed.status, 400)
}

@(test)
test_parse_bare_lf_rejected :: proc(t: ^testing.T) {
	parsed := test_parse("GET / HTTP/1.1\nHost: x\r\n\r\n")
	testing.expect_value(t, parsed.state, Parse_State.Error)
	testing.expect_value(t, parsed.status, 400)
}

@(test)
test_parse_bad_request_line :: proc(t: ^testing.T) {
	parsed := test_parse("GET /\r\n\r\n")
	testing.expect_value(t, parsed.state, Parse_State.Error)
	parsed2 := test_parse("GET / HTTP/2.0\r\n\r\n")
	testing.expect_value(t, parsed2.state, Parse_State.Error)
	parsed3 := test_parse("GET /foo HTTP/1.1 extra\r\n\r\n")
	testing.expect_value(t, parsed3.state, Parse_State.Error)
}

@(test)
test_parse_methods :: proc(t: ^testing.T) {
	get := test_parse("GET / HTTP/1.1\r\n\r\n")
	testing.expect_value(t, get.request.method, Http_Method.Get)
	post := test_parse("POST /x HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
	testing.expect_value(t, post.request.method, Http_Method.Post)
	del := test_parse("DELETE /x HTTP/1.1\r\n\r\n")
	testing.expect_value(t, del.request.method, Http_Method.Delete)
	put := test_parse("PUT /x HTTP/1.1\r\n\r\n")
	testing.expect_value(t, put.state, Parse_State.Complete)
	testing.expect_value(t, put.request.method, Http_Method.Other)
}

@(test)
test_parse_post_requires_content_length :: proc(t: ^testing.T) {
	parsed := test_parse("POST /x HTTP/1.1\r\nHost: h\r\n\r\n")
	testing.expect_value(t, parsed.state, Parse_State.Error)
	testing.expect_value(t, parsed.status, 400)
}

@(test)
test_parse_post_body_waits_for_full_length :: proc(t: ^testing.T) {
	partial := test_parse("POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nhel")
	testing.expect_value(t, partial.state, Parse_State.Incomplete)

	full := test_parse("POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello")
	testing.expect_value(t, full.state, Parse_State.Complete)
	testing.expect_value(t, string(full.request.body), "hello")
	testing.expect_value(t, full.consumed, len("POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"))
}

@(test)
test_parse_body_too_large :: proc(t: ^testing.T) {
	request := strings.concatenate(
		{"POST /x HTTP/1.1\r\nContent-Length: ", fmt.tprintf("%d", MAX_REQUEST_BODY + 1), "\r\n\r\n"},
		context.temp_allocator,
	)
	parsed := test_parse(request)
	testing.expect_value(t, parsed.state, Parse_State.Error)
	testing.expect_value(t, parsed.status, 413)
}

@(test)
test_parse_rejects_chunked :: proc(t: ^testing.T) {
	parsed := test_parse("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
	testing.expect_value(t, parsed.state, Parse_State.Error)
	testing.expect_value(t, parsed.status, 400)
	parsed2 := test_parse("POST /x HTTP/1.1\r\nContent-Length: 0\r\nTransfer-Encoding: identity\r\n\r\n")
	testing.expect_value(t, parsed2.state, Parse_State.Error)
}

@(test)
test_parse_duplicate_content_length :: proc(t: ^testing.T) {
	parsed := test_parse("POST /x HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx")
	testing.expect_value(t, parsed.state, Parse_State.Error)
	testing.expect_value(t, parsed.status, 400)
}

@(test)
test_parse_percent_decoded_path :: proc(t: ^testing.T) {
	parsed := test_parse("GET /a%20b/%E4%BD%A0?x=1 HTTP/1.1\r\n\r\n")
	testing.expect_value(t, parsed.state, Parse_State.Complete)
	testing.expect_value(t, parsed.request.path, "/a b/你")
	testing.expect_value(t, parsed.request.query, "x=1")

	bad := test_parse("GET /%zz HTTP/1.1\r\n\r\n")
	testing.expect_value(t, bad.state, Parse_State.Error)
	testing.expect_value(t, bad.status, 400)
}

@(test)
test_parse_keep_alive_rules :: proc(t: ^testing.T) {
	http11 := test_parse("GET / HTTP/1.1\r\n\r\n")
	testing.expect_value(t, http11.request.keep_alive, true)
	http11_close := test_parse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n")
	testing.expect_value(t, http11_close.request.keep_alive, false)

	http10 := test_parse("GET / HTTP/1.0\r\n\r\n")
	testing.expect_value(t, http10.request.keep_alive, false)
	http10_keep := test_parse("GET / HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n")
	testing.expect_value(t, http10_keep.request.keep_alive, true)
}

@(test)
test_build_response_head :: proc(t: ^testing.T) {
	response := Http_Response {
		status = 200,
	}
	response_set_header(&response, "Content-Type", "text/plain")
	response_set_header(&response, "Content-Length", "999") // 由服务器统一计算
	response_text(&response, 200, "hello")

	head := build_response_head(&response, false)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(head, "Content-Type: text/plain\r\n"))
	testing.expect(t, strings.contains(head, "Content-Length: 5\r\n"))
	testing.expect(t, strings.contains(head, "Connection: keep-alive\r\n"))
	testing.expect(t, !strings.contains(head, "Content-Length: 999"))
	testing.expect(t, strings.has_suffix(head, "\r\n\r\n"))
}

@(test)
test_build_response_304_has_no_body_length :: proc(t: ^testing.T) {
	response := Http_Response {
		status = 304,
	}
	head := build_response_head(&response, false)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 304 Not Modified\r\n"))
	testing.expect(t, !strings.contains(head, "Content-Length"))
}

Test_Transport :: struct {
	input:     []byte,
	pos:       int,
	output:    [dynamic]u8,
	max_read:  int,
	fail_send: bool,
	fail_recv: bool, // 模拟 SO_RCVTIMEO 到期
	timeouts:  [dynamic]time.Duration,
}

test_transport_recv :: proc(user: rawptr, buffer: []byte) -> (n: int, ok: bool) {
	transport := (^Test_Transport)(user)
	if transport.fail_recv {
		return 0, false
	}
	if transport.pos >= len(transport.input) {
		return 0, true
	}
	want := len(buffer)
	if transport.max_read > 0 && want > transport.max_read {
		want = transport.max_read
	}
	remaining := len(transport.input) - transport.pos
	if want > remaining {
		want = remaining
	}
	copy(buffer[:want], transport.input[transport.pos:transport.pos + want])
	transport.pos += want
	return want, true
}

test_transport_set_timeout :: proc(user: rawptr, timeout: time.Duration) -> bool {
	transport := (^Test_Transport)(user)
	append(&transport.timeouts, timeout)
	return true
}

test_transport_send :: proc(user: rawptr, data: []byte) -> bool {
	transport := (^Test_Transport)(user)
	if transport.fail_send {
		return false
	}
	append(&transport.output, ..data)
	return true
}

test_transport :: proc(input: string) -> Test_Transport {
	return Test_Transport{input = transmute([]byte)input, max_read = 7}
}

test_transport_output :: proc(transport: ^Test_Transport) -> string {
	return string(transport.output[:])
}

Handler_Record :: struct {
	paths: [dynamic]string,
}

record_handler :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	record := (^Handler_Record)(user)
	append(&record.paths, strings.clone(request.path, context.allocator))
	response_set_header(response, "Content-Type", "text/plain")
	response_text(response, 200, "ok")
}

@(test)
test_serve_connection_keep_alive_two_requests :: proc(t: ^testing.T) {
	transport := test_transport("GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\nConnection: close\r\n\r\n")
	record := Handler_Record{}
	serve_connection(
		{user = &transport, recv = test_transport_recv, send = test_transport_send},
		record_handler,
		&record,
	)
	out := test_transport_output(&transport)
	testing.expect_value(t, len(record.paths), 2)
	testing.expect_value(t, record.paths[0], "/a")
	testing.expect_value(t, record.paths[1], "/b")
	testing.expect_value(t, strings.count(out, "HTTP/1.1 200 OK"), 2)
	testing.expect_value(t, strings.count(out, "Connection: keep-alive"), 1)
	testing.expect_value(t, strings.count(out, "Connection: close"), 1)
}

@(test)
test_serve_connection_unknown_method_405 :: proc(t: ^testing.T) {
	transport := test_transport("PUT /x HTTP/1.1\r\n\r\n")
	record := Handler_Record{}
	serve_connection(
		{user = &transport, recv = test_transport_recv, send = test_transport_send},
		record_handler,
		&record,
	)
	out := test_transport_output(&transport)
	testing.expect_value(t, len(record.paths), 0)
	testing.expect(t, strings.contains(out, "HTTP/1.1 405 Method Not Allowed"))
	testing.expect(t, strings.contains(out, "Connection: close"))
}

@(test)
test_serve_connection_bad_request_closes :: proc(t: ^testing.T) {
	transport := test_transport("BROKEN\r\n\r\n")
	record := Handler_Record{}
	serve_connection(
		{user = &transport, recv = test_transport_recv, send = test_transport_send},
		record_handler,
		&record,
	)
	out := test_transport_output(&transport)
	testing.expect(t, strings.contains(out, "HTTP/1.1 400 Bad Request"))
	testing.expect(t, strings.contains(out, "Connection: close"))
}

@(test)
test_serve_connection_error_response_closes :: proc(t: ^testing.T) {
	transport := test_transport(
		"GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\n",
	)
	record := Handler_Record{}
	err_handler :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
		response_text(response, 404, "missing")
	}
	serve_connection(
		{user = &transport, recv = test_transport_recv, send = test_transport_send},
		err_handler,
		&record,
	)
	out := test_transport_output(&transport)
	testing.expect_value(t, strings.count(out, "HTTP/1.1 404 Not Found"), 1)
	testing.expect_value(t, strings.count(out, "HTTP/1.1"), 1)
}

@(test)
test_serve_connection_eof_mid_request :: proc(t: ^testing.T) {
	transport := test_transport("GET /a HTTP/1.1\r\nHost: x\r\n")
	record := Handler_Record{}
	serve_connection(
		{user = &transport, recv = test_transport_recv, send = test_transport_send},
		record_handler,
		&record,
	)
	testing.expect_value(t, len(record.paths), 0)
	testing.expect_value(t, len(transport.output), 0)
}

// 空闲 keep-alive 与半截请求用不同读超时：后者更短，慢速客户端不能长期占住连接线程。
@(test)
test_serve_connection_sets_idle_and_request_read_timeouts :: proc(t: ^testing.T) {
	transport := test_transport("GET /a HTTP/1.1\r\nHost: x\r\n")
	record := Handler_Record{}
	serve_connection(
		{
			user = &transport,
			recv = test_transport_recv,
			send = test_transport_send,
			set_read_timeout = test_transport_set_timeout,
		},
		record_handler,
		&record,
	)
	testing.expect_value(t, transport.timeouts[0], IDLE_READ_TIMEOUT)
	testing.expect(t, len(transport.timeouts) > 1)
	for timeout in transport.timeouts[1:] {
		testing.expect_value(t, timeout, REQUEST_READ_TIMEOUT)
	}
	testing.expect(t, IDLE_READ_TIMEOUT > REQUEST_READ_TIMEOUT)
}

// 读超时（recv 返回 !ok）必须直接断连：不写响应、不调用 handler。
@(test)
test_serve_connection_recv_timeout_closes_without_response :: proc(t: ^testing.T) {
	transport := Test_Transport{fail_recv = true}
	record := Handler_Record{}
	serve_connection(
		{
			user = &transport,
			recv = test_transport_recv,
			send = test_transport_send,
			set_read_timeout = test_transport_set_timeout,
		},
		record_handler,
		&record,
	)
	testing.expect_value(t, len(record.paths), 0)
	testing.expect_value(t, len(transport.output), 0)
	testing.expect_value(t, len(transport.timeouts), 1)
	testing.expect_value(t, transport.timeouts[0], IDLE_READ_TIMEOUT)
}

