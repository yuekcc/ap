package main

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

// HTTP/1.1 最小子集，约束见 docs/web.md「HTTP 层（手写）」。
// 解析只接受内存 buffer，socket 读写通过 Transport 注入，测试可以完全不碰网络。
MAX_HEADER_LINE :: 32 * 1024
MAX_HEADERS :: 100
// 请求体上限要比 prompt 上限（1MB）略大，否则 JSON 包装会让「1MB prompt」
// 在解析层就被 413 掉，API 的 prompt_too_large 错误体永远走不到。
MAX_REQUEST_BODY :: 2 * 1024 * 1024
READ_CHUNK :: 16 * 1024

// 读超时（SO_RCVTIMEO）分两档：等新请求可以久一点，保持浏览器连接复用；
// 一旦开始读某个请求，就必须在限期内收完，慢速客户端不能长期占住连接线程。
IDLE_READ_TIMEOUT :: 30 * time.Second
REQUEST_READ_TIMEOUT :: 10 * time.Second


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
	// 出错时保留已解析出的 request target：/api/ 前缀决定错误体用 JSON 还是纯文本。
	target:   string,
}

Http_Response :: struct {
	status:  int,
	headers: [dynamic]Http_Header,
	body:    []byte,
	close:   bool, // handler 强制关连接（SSE、流式响应等）
	stream:  Http_Stream,
}

// 流式响应（SSE）的写通道。头一旦写出去就无法再回到定长路径，所以
// used 表示 handler 选择了流式，started 表示 chunked 头已经发出。
// transport 由 serve_connection 在调用 handler 前填入，测试可以自己拼一个。
Http_Stream :: struct {
	transport: Transport,
	used:      bool,
	started:   bool,
	ended:     bool,
	chunk_buf: [dynamic]u8,
}

// 路由表：精确路径在前台，prefix 路由兜底子路径。api.odin 在启动时调用
// register_route 注册即可，不需要改服务器主循环。
Http_Route :: struct {
	method:  Http_Method,
	path:    string,
	prefix:  bool,
	handler: Http_Handler,
}

Http_Router :: struct {
	routes: [dynamic]Http_Route,
}

ROUTES: Http_Router

router_add :: proc(
	router: ^Http_Router,
	method: Http_Method,
	path: string,
	handler: Http_Handler,
	prefix := false,
) {
	append(&router.routes, Http_Route{method, path, prefix, handler})
}

register_route :: proc(
	method: Http_Method,
	path: string,
	handler: Http_Handler,
	prefix := false,
) {
	router_add(&ROUTES, method, path, handler, prefix)
}

router_dispatch :: proc(
	router: ^Http_Router,
	user: rawptr,
	request: ^Http_Request,
	response: ^Http_Response,
) -> bool {
	// 精确路径优先，其次才是 prefix，避免先注册的 "/api/" 抢走精确路由。
	for route in router.routes {
		if route.method == request.method && !route.prefix && request.path == route.path {
			route.handler(user, request, response)
			return true
		}
	}
	for route in router.routes {
		if route.method == request.method && route.prefix && strings.has_prefix(request.path, route.path) {
			route.handler(user, request, response)
			return true
		}
	}
	return false
}

// 路径存在但方法不匹配时用来给出 405 而不是 404。
router_path_exists :: proc(router: ^Http_Router, path: string) -> bool {
	for route in router.routes {
		if route.prefix {
			if strings.has_prefix(path, route.path) {
				return true
			}
		} else if path == route.path {
			return true
		}
	}
	return false
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
	// 可选：设置阻塞读的期限（SO_RCVTIMEO）。为 nil 时依赖 recv 自身实现。
	set_read_timeout: proc(user: rawptr, timeout: time.Duration) -> bool,
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

parse_fail :: proc(status: int, message: string, target := "") -> Request_Parse {
	return {state = .Error, status = status, message = message, target = target}
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
			return parse_fail(400, "malformed header", target)
		}
		name := line[:colon]
		if strings.contains_any(name, " \t") {
			return parse_fail(400, "malformed header name", target)
		}
		value := strings.trim_space(line[colon + 1:])
		if strings.equal_fold(name, "content-length") {
			content_length_count += 1
			if content_length_count > 1 {
				return parse_fail(400, "duplicate Content-Length", target)
			}
			content_length_text = value
		}
		if strings.equal_fold(name, "transfer-encoding") {
			// chunked 请求体不支持；identity 也不实现，直接拒绝。
			return parse_fail(400, "Transfer-Encoding is not supported", target)
		}
		append(&headers, Http_Header{name = name, value = value})
	}

	method := method_from_text(method_text)
	body_length := 0
	if content_length_count > 0 {
		n, ok := strconv.parse_int(content_length_text, 10)
		if !ok || n < 0 {
			return parse_fail(400, "invalid Content-Length", target)
		}
		if n > MAX_REQUEST_BODY {
			return parse_fail(413, "request body too large", target)
		}
		body_length = n
	} else if method == .Post {
		return parse_fail(400, "Content-Length is required", target)
	}

	consumed := header_end + 4 + body_length
	if len(buffer) < consumed {
		return {state = .Incomplete}
	}

	path_raw, query := split_target(target)
	path, decoded := percent_decode(path_raw, allocator)
	if !decoded {
		return parse_fail(400, "invalid percent-encoding", target)
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

// 流式响应头固定用 chunked + close：SSE 是单向长连接，没有已知长度，
// 也不复用连接（docs/web.md「SSE」）。
build_stream_head :: proc(response: ^Http_Response, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt_append_status(&b, response.status)
	for header in response.headers {
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
	strings.write_string(&b, "Transfer-Encoding: chunked\r\n")
	strings.write_string(&b, "Connection: close\r\n")
	strings.write_string(&b, "\r\n")
	return strings.to_string(b)
}

// 开始流式响应：立刻写出 chunked 头。返回 false 表示连接已断，
// handler 应直接返回（之后服务器不再写任何东西）。
response_stream_start :: proc(response: ^Http_Response) -> bool {
	if response.stream.started {
		return true
	}
	response.stream.used = true
	response.stream.started = true
	head := build_stream_head(response)
	return response.stream.transport.send(response.stream.transport.user, transmute([]byte)head)
}

// 写一个 chunk。空数据直接成功，避免发出 0 长度的数据 chunk。
response_stream_write :: proc(response: ^Http_Response, data: []byte) -> bool {
	if len(data) == 0 {
		return true
	}
	if !response.stream.started {
		if !response_stream_start(response) {
			return false
		}
	}
	clear(&response.stream.chunk_buf)
	header: [24]u8
	prefix := fmt.bprintf(header[:], "%x\r\n", len(data))
	append(&response.stream.chunk_buf, ..transmute([]byte)prefix)
	append(&response.stream.chunk_buf, ..data)
	append(&response.stream.chunk_buf, ..transmute([]byte)string("\r\n"))
	return response.stream.transport.send(
		response.stream.transport.user,
		response.stream.chunk_buf[:],
	)
}

// 结束流：写终止 chunk。头还没发出去时也要先发头，保证响应是完整的。
// 重复调用安全（handler 显式结束 + 服务器兜底）。
response_stream_end :: proc(response: ^Http_Response) {
	response.stream.used = true
	if response.stream.ended {
		return
	}
	response.stream.ended = true
	if !response.stream.started {
		if !response_stream_start(response) {
			return
		}
	}
	_ = response.stream.transport.send(response.stream.transport.user, transmute([]byte)string("0\r\n\r\n"))
}

write_error_response :: proc(
	transport: Transport,
	status: int,
	message: string,
	json_api := false,
) {
	response := Http_Response {
		status  = status,
		headers = make([dynamic]Http_Header, 0, 4, context.temp_allocator),
	}
	if json_api {
		// /api/* 的错误体必须与 handler 一致；这些 message 都是本文件的固定字面量，
		// 不含需要 JSON 转义的字符。
		body := fmt.tprintf(
			`{{"error":{{"code":"%s","message":"%s"}}}}`,
			http_error_code(status),
			message,
		)
		response_text(&response, status, body)
		response_set_header(&response, "Content-Type", "application/json; charset=utf-8")
	} else {
		body := status_text(status)
		if len(message) > 0 {
			body = message
		}
		response_text(&response, status, body)
		response_set_header(&response, "Content-Type", "text/plain; charset=utf-8")
	}
	_ = write_response(transport, &response, true)
}

// 解析层没有 api.odin 的 Api_Error，这里给出同样的 code 映射。
http_error_code :: proc(status: int) -> string {
	switch status {
	case 400:
		return "bad_request"
	case 403:
		return "forbidden"
	case 404:
		return "not_found"
	case 405:
		return "method_not_allowed"
	case 413:
		return "payload_too_large"
	case 503:
		return "service_unavailable"
	}
	return "internal_error"
}

is_api_target :: proc(target: string) -> bool {
	return target == "/api" || strings.has_prefix(target, "/api/")
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
			if transport.set_read_timeout != nil {
				timeout := IDLE_READ_TIMEOUT if len(buffer) == 0 else REQUEST_READ_TIMEOUT
				_ = transport.set_read_timeout(transport.user, timeout)
			}
			chunk: [READ_CHUNK]u8
			n, ok := transport.recv(transport.user, chunk[:])
			if !ok || n <= 0 {
				return
			}
			append(&buffer, ..chunk[:n])
		case .Error:
			write_error_response(
				transport,
				parsed.status,
				parsed.message,
				is_api_target(parsed.target),
			)
			return
		case .Complete:
			request := parsed.request
			if request.method == .Other {
				write_error_response(
					transport,
					405,
					"method not allowed",
					is_api_target(request.target),
				)
				return
			}

			response := Http_Response {
				status  = 200,
				headers = make([dynamic]Http_Header, 0, 8, context.temp_allocator),
			}
			// 流式响应的 handler 需要直接写 socket（SSE 会持续到连接断开），
			// 定长路径完全不受影响。
			response.stream.transport = transport
			handler(handler_user, &request, &response)
			if response.stream.used {
				if response.stream.started && !response.stream.ended {
					response_stream_end(&response)
				}
				delete(response.stream.chunk_buf)
				return
			}
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
		set_read_timeout = socket_transport_set_timeout,
	}
}

socket_transport_set_timeout :: proc(user: rawptr, timeout: time.Duration) -> bool {
	socket := (^net.TCP_Socket)(user)^
	return socket_set_read_timeout(socket, timeout)
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

// 只接受主机名/IP + 端口，不做 URL 解析。resolve 对 IP 字面量会跳过 DNS。
resolve_endpoint :: proc(host: string, port: int) -> (net.Endpoint, string) {
	ep4, ep6, err := net.resolve(host)
	if err != nil {
		return {}, fmt.tprintf("cannot resolve --host %q: %v", host, err)
	}
	endpoint := ep4
	if endpoint.address == nil {
		endpoint = ep6
	}
	if endpoint.address == nil {
		return {}, fmt.tprintf("cannot resolve --host %q", host)
	}
	endpoint.port = port
	return endpoint, ""
}

Client_Context :: struct {
	app:    ^App,
	socket: net.TCP_Socket,
}

// 每连接一个线程；线程结束时释放 context 并关闭 socket。
serve_client :: proc(user: rawptr) {
	ctx := (^Client_Context)(user)
	socket := ctx.socket
	defer net.close(socket)
	defer free(ctx)
	// SSE 需要低延迟：禁 Nagle，避免事件被攒包（docs/web.md「SSE」）。
	_ = net.set_option(socket, .TCP_Nodelay, true)
	serve_connection(socket_transport(&ctx.socket), app_handle_request, ctx.app)
	free_all(context.temp_allocator)
}

close_client :: proc(socket: net.TCP_Socket) {
	net.close(socket)
}

