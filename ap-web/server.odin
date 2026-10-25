package main

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"

// HTTP/1.1 最小子集，约束见 docs/web.md「HTTP 层（手写）」。
// 解析只接受内存 buffer，socket 读写通过 Transport 注入，测试可以完全不碰网络。
MAX_HEADER_LINE :: 32 * 1024
MAX_HEADERS :: 100
MAX_REQUEST_BODY :: 1 * 1024 * 1024
READ_CHUNK :: 16 * 1024

Http_Method :: enum {
	Get,
	Post,
	Delete,
	Other,
}

Http_Request :: struct {
	method:     Http_Method,
	method_text: string,
	target:     string,
	path:       string, // percent-decode 之后
	query:      string, // 未解析的原始 query
	version:    string,
	headers:    []Http_Header,
	body:       []byte,
	keep_alive: bool,
}

Parse_State :: enum {
	Complete,
	Incomplete,
	Error,
}

Request_Parse :: struct {
	state:    Parse_State,
	request:  Http_Request,
	consumed: int,
	status:   int,
	message:  string,
}

Http_Response :: struct {
	status:  int,
	headers: [dynamic]Http_Header,
	body:    []byte,
	close:   bool, // handler 强制关连接（SSE、流式响应等）
}

Http_Handler :: #type proc(
	user: rawptr,
	request: ^Http_Request,
	response: ^Http_Response,
)

Transport :: struct {
	user: rawptr,
	recv: proc(user: rawptr, buffer: []byte) -> (n: int, ok: bool),
	send: proc(user: rawptr, data: []byte) -> bool,
}

method_from_text :: proc(text: string) -> Http_Method {
	switch text {
	case "GET":
		return .Get
	case "POST":
		return .Post
	case "DELETE":
		return .Delete
	}
	return .Other
}

parse_fail :: proc(status: int, message: string) -> Request_Parse {
	return {state = .Error, status = status, message = message}
}

find_header_end :: proc(buffer: []byte) -> int {
	if len(buffer) < 4 {
		return -1
	}
	for i in 0 ..< len(buffer) - 3 {
		if buffer[i] == '\r' &&
		   buffer[i + 1] == '\n' &&
		   buffer[i + 2] == '\r' &&
		   buffer[i + 3] == '\n' {
			return i
		}
	}
	return -1
}

// 请求头还没收全时也要能提前拒绝：超长行、裸 LF、过多头部。
scan_incomplete_header :: proc(buffer: []byte) -> (status: int, message: string) {
	line_start := 0
	line_count := 0
	for i := 0; i < len(buffer); i += 1 {
		b := buffer[i]
		if b == '\n' && (i == 0 || buffer[i - 1] != '\r') {
			return 400, "bare LF in request header"
		}
		if b == '\r' && i + 1 < len(buffer) && buffer[i + 1] != '\n' {
			return 400, "bare CR in request header"
		}
		if b == '\n' {
			if i - line_start > MAX_HEADER_LINE {
				return 400, "request header line too long"
			}
			line_count += 1
			if line_count > MAX_HEADERS + 1 {
				return 400, "too many request headers"
			}
			line_start = i + 1
		}
	}
	if len(buffer) - line_start > MAX_HEADER_LINE {
		return 400, "request header line too long"
	}
	return 0, ""
}

parse_request_bytes :: proc(
	buffer: []byte,
	allocator := context.temp_allocator,
) -> Request_Parse {
	header_end := find_header_end(buffer)
	if header_end < 0 {
		if status, message := scan_incomplete_header(buffer); status != 0 {
			return parse_fail(status, message)
		}
		return {state = .Incomplete}
	}

	header_blob := buffer[:header_end]
	lines := strings.split(string(header_blob), "\r\n", context.temp_allocator)
	if len(lines) == 0 || len(lines[0]) == 0 {
		return parse_fail(400, "empty request line")
	}
	if len(lines) - 1 > MAX_HEADERS {
		return parse_fail(400, "too many request headers")
	}
	for line in lines {
		if len(line) > MAX_HEADER_LINE {
			return parse_fail(400, "request header line too long")
		}
		if len(line) == 0 {
			return parse_fail(400, "empty header line")
		}
		if strings.contains_any(line, "\r\n") {
			return parse_fail(400, "bare CR or LF in request header")
		}
	}

	parts := strings.split(lines[0], " ", context.temp_allocator)
	if len(parts) != 3 || len(parts[0]) == 0 || len(parts[1]) == 0 || len(parts[2]) == 0 {
		return parse_fail(400, "malformed request line")
	}
	method_text := parts[0]
	target := parts[1]
	version := parts[2]
	if version != "HTTP/1.1" && version != "HTTP/1.0" {
		return parse_fail(400, "unsupported HTTP version")
	}
	if !strings.has_prefix(target, "/") {
		return parse_fail(400, "unsupported request target")
	}

	headers := make([dynamic]Http_Header, 0, len(lines) - 1, allocator)
	content_length_text := ""
	content_length_count := 0
	for line in lines[1:] {
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			return parse_fail(400, "malformed header")
		}
		name := line[:colon]
		if strings.contains_any(name, " \t") {
			return parse_fail(400, "malformed header name")
		}
		value := strings.trim_space(line[colon + 1:])
		if strings.equal_fold(name, "content-length") {
			content_length_count += 1
			if content_length_count > 1 {
				return parse_fail(400, "duplicate Content-Length")
			}
			content_length_text = value
		}
		if strings.equal_fold(name, "transfer-encoding") {
			// chunked 请求体不支持；identity 也不实现，直接拒绝。
			return parse_fail(400, "Transfer-Encoding is not supported")
		}
		append(&headers, Http_Header{name = name, value = value})
	}

	method := method_from_text(method_text)
	body_length := 0
	if content_length_count > 0 {
		n, ok := strconv.parse_int(content_length_text, 10)
		if !ok || n < 0 {
			return parse_fail(400, "invalid Content-Length")
		}
		if n > MAX_REQUEST_BODY {
			return parse_fail(413, "request body too large")
		}
		body_length = n
	} else if method == .Post {
		return parse_fail(400, "Content-Length is required")
	}

	consumed := header_end + 4 + body_length
	if len(buffer) < consumed {
		return {state = .Incomplete}
	}

	path_raw, query := split_target(target)
	path, decoded := percent_decode(path_raw, allocator)
	if !decoded {
		return parse_fail(400, "invalid percent-encoding")
	}

	keep_alive := version == "HTTP/1.1"
	if header_has_token(headers[:], "connection", "close") {
		keep_alive = false
	} else if version == "HTTP/1.0" && header_has_token(headers[:], "connection", "keep-alive") {
		keep_alive = true
	}

	return {
		state = .Complete,
		consumed = consumed,
		request = {
			method = method,
			method_text = method_text,
			target = target,
			path = path,
			query = query,
			version = version,
			headers = headers[:],
			body = buffer[header_end + 4:consumed],
			keep_alive = keep_alive,
		},
	}
}

response_set_header :: proc(response: ^Http_Response, name, value: string) {
	for header, i in response.headers {
		if strings.equal_fold(header.name, name) {
			response.headers[i].value = value
			return
		}
	}
	append(&response.headers, Http_Header{name = name, value = value})
}

response_text :: proc(response: ^Http_Response, status: int, text: string) {
	response.status = status
	response.body = transmute([]byte)text
}

build_response_head :: proc(
	response: ^Http_Response,
	close: bool,
	allocator := context.temp_allocator,
) -> string {
	b := strings.builder_make(allocator)
	fmt_append_status(&b, response.status)
	for header in response.headers {
		// 这两个头由服务器统一生成，避免 handler 写出与 body 长度不一致的值。
		if strings.equal_fold(header.name, "content-length") ||
		   strings.equal_fold(header.name, "connection") ||
		   strings.equal_fold(header.name, "transfer-encoding") {
			continue
		}
		strings.write_string(&b, header.name)
		strings.write_string(&b, ": ")
		strings.write_string(&b, header.value)
		strings.write_string(&b, "\r\n")
	}
	if response.status != 304 {
		fmt.sbprintf(&b, "Content-Length: %d\r\n", len(response.body))
	}
	if close {
		strings.write_string(&b, "Connection: close\r\n")
	} else {
		strings.write_string(&b, "Connection: keep-alive\r\n")
	}
	strings.write_string(&b, "\r\n")
	return strings.to_string(b)
}

fmt_append_status :: proc(b: ^strings.Builder, status: int) {
	fmt.sbprintf(b, "HTTP/1.1 %d %s\r\n", status, status_text(status))
}

write_response :: proc(transport: Transport, response: ^Http_Response, close: bool) -> bool {
	head := build_response_head(response, close)
	if !transport.send(transport.user, transmute([]byte)head) {
		return false
	}
	if response.status != 304 && len(response.body) > 0 {
		if !transport.send(transport.user, response.body) {
			return false
		}
	}
	return true
}

write_error_response :: proc(transport: Transport, status: int, message: string) {
	response := Http_Response {
		status = status,
	}
	body := status_text(status)
	if len(message) > 0 {
		body = message
	}
	response_text(&response, status, body)
	response_set_header(&response, "Content-Type", "text/plain; charset=utf-8")
	_ = write_response(transport, &response, true)
}

// 每连接一个状态机：读满头部 → 解析 → 交给 handler → 写出 → 保留 buffer 里
// 多读到的下一请求字节。出错和 4xx/5xx 之后一律关连接。
serve_connection :: proc(
	transport: Transport,
	handler: Http_Handler,
	handler_user: rawptr,
) {
	buffer: [dynamic]u8
	defer delete(buffer)

	for {
		parsed := parse_request_bytes(buffer[:])
		switch parsed.state {
		case .Incomplete:
			chunk: [READ_CHUNK]u8
			n, ok := transport.recv(transport.user, chunk[:])
			if !ok || n <= 0 {
				return
			}
			append(&buffer, ..chunk[:n])
		case .Error:
			write_error_response(transport, parsed.status, parsed.message)
			return
		case .Complete:
			request := parsed.request
			if request.method == .Other {
				write_error_response(transport, 405, "method not allowed")
				return
			}

			response := Http_Response {
				status = 200,
			}
			handler(handler_user, &request, &response)
			close := !request.keep_alive || response.close || response.status >= 400
			if !write_response(transport, &response, close) {
				return
			}

			remaining := len(buffer) - parsed.consumed
			if remaining > 0 {
				copy(buffer[:remaining], buffer[parsed.consumed:])
			}
			resize(&buffer, remaining)
			free_all(context.temp_allocator)
			if close {
				return
			}
		}
	}
}

socket_transport :: proc(socket: ^net.TCP_Socket) -> Transport {
	return {
		user = socket,
		recv = socket_transport_recv,
		send = socket_transport_send,
	}
}

socket_transport_recv :: proc(user: rawptr, buffer: []byte) -> (n: int, ok: bool) {
	socket := (^net.TCP_Socket)(user)^
	read, err := net.recv_tcp(socket, buffer)
	if err != nil {
		return 0, false
	}
	return read, true
}

socket_transport_send :: proc(user: rawptr, data: []byte) -> bool {
	socket := (^net.TCP_Socket)(user)^
	written, err := net.send_tcp(socket, data)
	return err == nil && written == len(data)
}
