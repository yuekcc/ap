package platform

import "base:runtime"
import c "core:c/libc"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "vendor:curl"

// 流式 HTTP POST 传输层。这里只有连接、超时、取消和 HTTP 状态行处理；
// 响应字节的含义（SSE、错误正文、重试策略）由调用方决定。
// 中文说明见 docs/internal/provider.md「传输层」。

HTTP_CONNECT_TIMEOUT_MS    :: 30000
HTTP_FIRST_BYTE_TIMEOUT_MS :: 120 * 1000
HTTP_LOW_SPEED_LIMIT       :: 1
HTTP_LOW_SPEED_TIME_S      :: 120

Http_Failure :: enum {
	None,
	Network,
	Timeout,
	First_Byte_Timeout,
	Cancelled,
	// 本进程内无法发起请求（初始化、句柄或 header 分配失败），重试无意义。
	Internal,
}

// 返回 false 中止传输。status 是该段字节所属响应的状态码；还没读到状态行时为 0。
Http_Body_Proc :: #type proc(user: rawptr, status: int, data: []byte) -> bool

// 响应头回调：状态行与每个 header 行各一次，line 已去掉换行。
Http_Header_Proc :: #type proc(user: rawptr, status: int, line: string)

Http_Stream_Request :: struct {
	url:                   string,
	// 完整 header 行，例如 "Accept: text/event-stream"。
	headers:               []string,
	body:                  []byte,
	// 两者都是 <= 0 表示不设该超时。
	total_timeout_ms:      int,
	first_byte_timeout_ms: int,
	cancel:                ^Cancel_Token,
	user:                  rawptr,
	on_body:               Http_Body_Proc,
	// 可选：观察响应头，传输层自身不做其它处理。
	on_header:             Http_Header_Proc,
}

Http_Stream_Result :: struct {
	status:         int,
	retry_after_ms: Maybe(int),
	failure:        Http_Failure,
	message:        string,
}

@(private)
Http_State :: struct {
	req:                ^Http_Stream_Request,
	status:             int,
	retry_after_ms:     Maybe(int),
	started:            time.Tick,
	got_data:           bool,
	first_byte_timeout: bool,
}

http_write_cb :: proc "c" (buffer: [^]byte, size, nitems: c.size_t, user: rawptr) -> c.size_t {
	context = runtime.default_context()
	state := (^Http_State)(user)
	n := int(size * nitems)
	if n <= 0 {
		return size * nitems
	}
	state.got_data = true
	if state.req.on_body != nil && !state.req.on_body(state.req.user, state.status, buffer[:n]) {
		return 0
	}
	return size * nitems
}

http_header_cb :: proc "c" (buffer: [^]byte, size, nitems: c.size_t, user: rawptr) -> c.size_t {
	context = runtime.default_context()
	state := (^Http_State)(user)
	n := int(size * nitems)
	line := string(buffer[:n])
	trimmed := strings.trim_right(line, "\r\n")

	if strings.has_prefix(trimmed, "HTTP/") {
		if status, ok := http_parse_status_line(trimmed); ok {
			state.status = status
		}
	}
	if state.req.on_header != nil {
		state.req.on_header(state.req.user, state.status, trimmed)
	}
	lower, _ := strings.to_lower(trimmed, context.temp_allocator)
	if strings.has_prefix(lower, "retry-after:") {
		value := strings.trim_space(trimmed[len("retry-after:"):])
		if seconds, ok := strconv.parse_int(value, 10); ok && seconds > 0 {
			state.retry_after_ms = seconds * 1000
		}
	}
	return size * nitems
}

// 只接受 200..599；重定向与 1xx 不改变结果状态码。
http_parse_status_line :: proc(line: string) -> (int, bool) {
	space := strings.index_byte(line, ' ')
	if space < 0 || space + 4 > len(line) {
		return 0, false
	}
	status := 0
	for i in space + 1 ..< min(space + 4, len(line)) {
		ch := line[i]
		if ch < '0' || ch > '9' {
			return 0, false
		}
		status = status * 10 + int(ch - '0')
	}
	if status < 200 || status >= 600 {
		return 0, false
	}
	return status, true
}

http_xferinfo_cb :: proc "c" (user: rawptr, dltotal, dlnow, ultotal, ulnow: curl.off_t) -> c.int {
	context = runtime.default_context()
	state := (^Http_State)(user)
	if cancel_token_cancelled(state.req.cancel) {
		return 1
	}
	limit := state.req.first_byte_timeout_ms
	if limit > 0 && !state.got_data &&
	   time.tick_since(state.started) > time.Duration(limit) * time.Millisecond {
		state.first_byte_timeout = true
		return 1
	}
	return 0
}

http_global_ready := false
http_global_mu: sync.Mutex

// libcurl 的 global_init 不是线程安全的；进程内可能有多个会话并发请求，
// 因此首次初始化必须串行化。初始化完成后锁只保护一次布尔读取，开销可忽略。
http_global_init :: proc() -> Error {
	sync.mutex_lock(&http_global_mu)
	defer sync.mutex_unlock(&http_global_mu)
	if http_global_ready {
		return ok_error()
	}
	if res := curl.global_init(curl.GLOBAL_ALL); res != .E_OK {
		return errorf("libcurl initialization failed: %v", res)
	}
	http_global_ready = true
	return ok_error()
}

http_stream :: proc(req: ^Http_Stream_Request) -> Http_Stream_Result {
	if err := http_global_init(); !is_ok(err) {
		return {failure = .Internal, message = err.message}
	}

	state := Http_State {
		req     = req,
		started = time.tick_now(),
	}

	h := curl.easy_init()
	if h == nil {
		return {failure = .Internal, message = "curl_easy_init failed"}
	}
	defer curl.easy_cleanup(h)

	headers: ^curl.slist
	for header in req.headers {
		headers = curl.slist_append(headers, strings.clone_to_cstring(header, context.temp_allocator))
	}
	if headers == nil && len(req.headers) > 0 {
		return {failure = .Internal, message = "cannot allocate HTTP headers"}
	}
	defer curl.slist_free_all(headers)

	one := c.long(1)
	curl.easy_setopt(h, .URL, strings.clone_to_cstring(req.url, context.temp_allocator))
	curl.easy_setopt(h, .HTTPHEADER, headers)
	curl.easy_setopt(h, .POST, one)
	curl.easy_setopt(h, .POSTFIELDSIZE, c.long(len(req.body)))
	if len(req.body) > 0 {
		curl.easy_setopt(h, .POSTFIELDS, cstring(raw_data(req.body)))
	}
	curl.easy_setopt(h, .WRITEFUNCTION, rawptr(http_write_cb))
	curl.easy_setopt(h, .WRITEDATA, rawptr(&state))
	curl.easy_setopt(h, .HEADERFUNCTION, rawptr(http_header_cb))
	curl.easy_setopt(h, .HEADERDATA, rawptr(&state))
	curl.easy_setopt(h, .XFERINFOFUNCTION, rawptr(http_xferinfo_cb))
	curl.easy_setopt(h, .XFERINFODATA, rawptr(&state))
	curl.easy_setopt(h, .NOSIGNAL, one)
	// 只有关掉进度条，libcurl 才会调用 XFERINFOFUNCTION；取消与首字节超时都靠它。
	curl.easy_setopt(h, .NOPROGRESS, c.long(0))
	// SSE 不能落进 libcurl 的压缩缓冲，否则增量会被攒成整块。
	curl.easy_setopt(h, .ACCEPT_ENCODING, cstring("identity"))
	curl.easy_setopt(h, .HTTP_VERSION, c.long(curl.HTTP_VERSION_1_1))
	curl.easy_setopt(h, .CONNECTTIMEOUT_MS, c.long(HTTP_CONNECT_TIMEOUT_MS))
	if req.total_timeout_ms > 0 {
		curl.easy_setopt(h, .TIMEOUT_MS, c.long(req.total_timeout_ms))
	}
	curl.easy_setopt(h, .LOW_SPEED_LIMIT, c.long(HTTP_LOW_SPEED_LIMIT))
	curl.easy_setopt(h, .LOW_SPEED_TIME, c.long(HTTP_LOW_SPEED_TIME_S))

	res := curl.easy_perform(h)

	result := Http_Stream_Result {
		status         = state.status,
		retry_after_ms = state.retry_after_ms,
	}
	if result.status == 0 {
		info_status: c.long
		curl.easy_getinfo(h, .RESPONSE_CODE, &info_status)
		if info_status != 0 {
			result.status = int(info_status)
		}
	}

	switch {
	case cancel_token_cancelled(req.cancel):
		result.failure = .Cancelled
		result.message = "cancelled"
	case state.first_byte_timeout:
		result.failure = .First_Byte_Timeout
		result.message = fmt.tprintf("no response within %d ms", req.first_byte_timeout_ms)
	case res == .E_OPERATION_TIMEDOUT:
		result.failure = .Timeout
		result.message = "request timed out"
	case res != .E_OK:
		result.failure = .Network
		result.message = fmt.tprintf("network error: %v", res)
	}
	return result
}
