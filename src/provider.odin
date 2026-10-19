package ap

import "base:runtime"
import c "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import "vendor:curl"

FIRST_BYTE_TIMEOUT :: 120 * time.Second

Cancel_Token :: struct {
	value: i32,
}

cancel_token_cancel :: proc(token: ^Cancel_Token) {
	if token != nil {
		sync.atomic_store(&token.value, 1)
	}
}

cancel_token_cancelled :: proc(token: ^Cancel_Token) -> bool {
	if token == nil {
		return false
	}
	return sync.atomic_load(&token.value) != 0
}

Stop_Reason :: enum {
	Stop,
	Tool_Use,
	Max_Tokens,
}

stop_reason_string :: proc(reason: Stop_Reason) -> string {
	switch reason {
	case .Stop:
		return "stop"
	case .Tool_Use:
		return "tool_use"
	case .Max_Tokens:
		return "max_tokens"
	}
	return "stop"
}

Provider_Error_Kind :: enum {
	None,
	Auth,
	Model_Not_Found,
	Invalid_Request,
	Context_Too_Long,
	Rate_Limit,
	Server_Error,
	Network,
	Timeout,
	Protocol,
	Cancelled,
	Internal,
}

Provider_Error :: struct {
	kind:           Provider_Error_Kind,
	message:        string,
	retryable:      bool,
	retry_after_ms: Maybe(int),
}

provider_error_none :: proc() -> Provider_Error {
	return {kind = .None}
}

provider_error_kind_string :: proc(kind: Provider_Error_Kind) -> string {
	switch kind {
	case .None:
		return ""
	case .Auth:
		return "auth"
	case .Model_Not_Found:
		return "model_not_found"
	case .Invalid_Request:
		return "invalid_request"
	case .Context_Too_Long:
		return "context_too_long"
	case .Rate_Limit:
		return "rate_limit"
	case .Server_Error:
		return "server_error"
	case .Network:
		return "network"
	case .Timeout:
		return "timeout"
	case .Protocol:
		return "protocol"
	case .Cancelled:
		return "cancelled"
	case .Internal:
		return "internal"
	}
	return ""
}

Assembled_Tool_Call :: struct {
	id:    string,
	name:  string,
	input: json.Value,
}

Provider_Message_Start :: struct {
	model:      string,
	message_id: string,
}

Provider_Text_Delta :: struct {
	text: string,
}

Provider_Reasoning_Delta :: struct {
	text: string,
}

Provider_Tool_Start :: struct {
	index: int,
	id:    string,
	name:  string,
}

Provider_Tool_Delta :: struct {
	index:      int,
	args_delta: string,
}

Provider_Tool_End :: struct {
	index: int,
}

Provider_Message_End :: struct {
	message_id:  string,
	stop_reason: Stop_Reason,
	usage:       Usage,
	tool_calls:  []Assembled_Tool_Call,
	reasoning:   string,
	text:        string,
}

Provider_Error_Event :: struct {
	err: Provider_Error,
}

Provider_Event :: union {
	Provider_Message_Start,
	Provider_Text_Delta,
	Provider_Reasoning_Delta,
	Provider_Tool_Start,
	Provider_Tool_Delta,
	Provider_Tool_End,
	Provider_Message_End,
	Provider_Error_Event,
}

Stream_Sink :: struct {
	user:     rawptr,
	on_event: proc(user: rawptr, event: Provider_Event),
}

emit_provider_event :: proc(sink: Stream_Sink, event: Provider_Event) {
	if sink.on_event != nil {
		sink.on_event(sink.user, event)
	}
}

Chat_Message_Request :: struct {
	model:                string,
	messages:             []Chat_Message,
	tools:                []Tool_Def,
	max_tokens:           int,
	include_usage:        bool,
}

Chat_Stream_Options :: struct {
	include_usage: bool,
}

Chat_Request_Body :: struct {
	model:               string `json:"model"`,
	messages:            []Chat_Message `json:"messages"`,
	tools:               []Tool_Def `json:"tools,omitempty"`,
	tool_choice:         Maybe(string) `json:"tool_choice,omitempty"`,
	parallel_tool_calls: bool `json:"parallel_tool_calls"`,
	max_tokens:          int `json:"max_tokens"`,
	stream:              bool `json:"stream"`,
	stream_options:      Maybe(Chat_Stream_Options) `json:"stream_options,omitempty"`,
}

build_chat_request_body :: proc(req: Chat_Message_Request) -> ([]byte, Error) {
	body := Chat_Request_Body {
		model = req.model,
		messages = req.messages,
		tools = req.tools,
		parallel_tool_calls = false,
		max_tokens = req.max_tokens,
		stream = true,
	}
	if len(req.tools) > 0 {
		body.tool_choice = "auto"
	}
	if req.include_usage {
		body.stream_options = Chat_Stream_Options{include_usage = true}
	}
	data, jerr := json.marshal(body)
	if jerr != nil {
		return nil, make_error(.Internal, "cannot serialize chat request: %v", jerr)
	}
	return data, ok_error()
}

build_chat_endpoint :: proc(base_url: string) -> string {
	base := strings.trim_right(base_url, "/")
	if strings.has_suffix(base, "/chat/completions") {
		return base
	}
	return fmt.tprintf("%s/chat/completions", base)
}

Chat_Chunk :: struct {
	id:      string,
	model:   string,
	choices: []Chat_Choice,
	usage:   Maybe(Chat_Usage),
	error:   Maybe(Api_Error_Info),
}

Chat_Choice :: struct {
	index:         int,
	delta:         Chat_Delta,
	finish_reason: Maybe(string),
}

Chat_Delta :: struct {
	role:              Maybe(string),
	content:           Maybe(string),
	reasoning_content: Maybe(string),
	tool_calls:        []Chat_Tool_Call_Delta,
}

Chat_Tool_Call_Delta :: struct {
	index:    int,
	id:       Maybe(string),
	type:     Maybe(string),
	function: Maybe(Chat_Function_Delta),
}

Chat_Function_Delta :: struct {
	name:      Maybe(string),
	arguments: Maybe(string),
}

Chat_Usage :: struct {
	prompt_tokens:             Maybe(int),
	completion_tokens:         Maybe(int),
	total_tokens:              Maybe(int),
	prompt_tokens_details:     Maybe(Chat_Prompt_Details),
	completion_tokens_details: Maybe(Chat_Completion_Details),
}

Chat_Prompt_Details :: struct {
	cached_tokens: Maybe(int),
}

Chat_Completion_Details :: struct {
	reasoning_tokens: Maybe(int),
}

usage_from_chat :: proc(raw: Chat_Usage) -> Usage {
	cached: Maybe(int)
	if details, ok := raw.prompt_tokens_details.?; ok {
		cached = details.cached_tokens
	}
	reasoning: Maybe(int)
	if details, ok := raw.completion_tokens_details.?; ok {
		reasoning = details.reasoning_tokens
	}
	return Usage {
		input_tokens = raw.prompt_tokens,
		output_tokens = raw.completion_tokens,
		cached_tokens = cached,
		reasoning_tokens = reasoning,
		total_tokens = raw.total_tokens,
	}
}

Tool_Slot :: struct {
	index:   int,
	id:      string,
	name:    string,
	args:    [dynamic]byte,
	started: bool,
}

Stream_Assembler :: struct {
	sink:           Stream_Sink,
	fallback_model: string,
	started:        bool,
	finished:       bool,
	failed:         bool,
	message_id:     string,
	model:          string,
	finish_reason:  Maybe(string),
	usage:          Usage,
	usage_seen:     bool,
	text:           [dynamic]byte,
	reasoning:      [dynamic]byte,
	slots:          [dynamic]Tool_Slot,
	last_error:     Provider_Error,
}

assembler_init :: proc(a: ^Stream_Assembler, sink: Stream_Sink, model: string) {
	a.sink = sink
	a.fallback_model = model
	a.text = make([dynamic]byte, 0, 256)
	a.reasoning = make([dynamic]byte, 0, 256)
	a.slots = make([dynamic]Tool_Slot, 0, 2)
}

assembler_destroy :: proc(a: ^Stream_Assembler) {
	delete(a.text)
	delete(a.reasoning)
	for &slot in a.slots {
		delete(slot.args)
	}
	delete(a.slots)
}

assembler_fail :: proc(a: ^Stream_Assembler, err: Provider_Error) -> Provider_Error {
	if a.failed {
		return err
	}
	a.failed = true
	a.last_error = err
	emit_provider_event(a.sink, Provider_Error_Event{err = err})
	return err
}

assembler_slot :: proc(a: ^Stream_Assembler, index: int) -> ^Tool_Slot {
	for &slot in a.slots {
		if slot.index == index {
			return &slot
		}
	}
	slot := Tool_Slot{index = index}
	slot.args = make([dynamic]byte, 0, 64)
	append(&a.slots, slot)
	return &a.slots[len(a.slots) - 1]
}

assembler_feed :: proc(a: ^Stream_Assembler, data: string) -> Provider_Error {
	if a.finished || a.failed {
		return provider_error_none()
	}
	chunk: Chat_Chunk
	if uerr := json.unmarshal_string(data, &chunk); uerr != nil {
		return assembler_fail(
			a,
			{kind = .Protocol, message = fmt.tprintf("invalid SSE JSON: %v", uerr), retryable = false},
		)
	}
	if err_info, has_error := chunk.error.?; has_error {
		message := "server returned an error in stream"
		if msg, ok := err_info.message.?; ok {
			message = msg
		}
		kind := Provider_Error_Kind.Invalid_Request
		if code, ok := err_info.code.?; ok {
			if is_context_too_long_string(code) || is_context_too_long_string(message) {
				kind = .Context_Too_Long
			} else if code == "rate_limit_exceeded" || code == "rate_limit" {
				kind = .Rate_Limit
			}
		}
		if is_context_too_long_string(message) {
			kind = .Context_Too_Long
		}
		return assembler_fail(a, {kind = kind, message = message, retryable = false})
	}

	if len(chunk.id) > 0 {
		a.message_id = chunk.id
	}
	if len(chunk.model) > 0 {
		a.model = chunk.model
	}

	if !a.started {
		model := a.model
		if len(model) == 0 {
			model = a.fallback_model
		}
		emit_provider_event(
			a.sink,
			Provider_Message_Start{model = model, message_id = a.message_id},
		)
		a.started = true
	}

	for choice in chunk.choices {
		delta := choice.delta
		if text, ok := delta.content.?; ok && len(text) > 0 {
			append(&a.text, ..transmute([]byte)text)
			emit_provider_event(a.sink, Provider_Text_Delta{text = text})
		}
		if text, ok := delta.reasoning_content.?; ok && len(text) > 0 {
			append(&a.reasoning, ..transmute([]byte)text)
			emit_provider_event(a.sink, Provider_Reasoning_Delta{text = text})
		}
		for call in delta.tool_calls {
			slot := assembler_slot(a, call.index)
			id, has_id := call.id.?
			args_delta := ""
			if has_id && len(id) > 0 {
				slot.id = id
			}
			if fn, has_fn := call.function.?; has_fn {
				if value, ok := fn.name.?; ok && len(value) > 0 {
					slot.name = value
				}
				if value, ok := fn.arguments.?; ok {
					args_delta = value
				}
			}
			if !slot.started {
				slot.started = true
				emit_provider_event(a.sink, Provider_Tool_Start{index = slot.index, id = slot.id, name = slot.name})
			}
			if len(args_delta) > 0 {
				append(&slot.args, ..transmute([]byte)args_delta)
				emit_provider_event(a.sink, Provider_Tool_Delta{index = slot.index, args_delta = args_delta})
			}
		}
		if reason, ok := choice.finish_reason.?; ok && len(reason) > 0 {
			a.finish_reason = reason
		}
	}

	if raw_usage, has_usage := chunk.usage.?; has_usage {
		a.usage = usage_from_chat(raw_usage)
		a.usage_seen = true
	}
	return provider_error_none()
}

normalize_finish_reason :: proc(reason: string) -> (Stop_Reason, bool) {
	switch reason {
	case "stop":
		return .Stop, true
	case "content_filter":
		log_warn("provider stopped due to content_filter")
		return .Stop, true
	case "tool_calls":
		return .Tool_Use, true
	case "length":
		return .Max_Tokens, true
	}
	return .Stop, false
}

assembler_finish :: proc(a: ^Stream_Assembler) -> Provider_Error {
	if a.failed {
		return provider_error_none()
	}
	if a.finished {
		return assembler_fail(
			a,
			{kind = .Protocol, message = "received more than one stream completion", retryable = false},
		)
	}
	if !a.started {
		return assembler_fail(a, {kind = .Protocol, message = "empty response from provider", retryable = false})
	}
	finish, has_finish := a.finish_reason.?
	if !has_finish {
		return assembler_fail(a, {kind = .Protocol, message = "stream ended without finish_reason", retryable = false})
	}
	stop, ok := normalize_finish_reason(finish)
	if !ok {
		return assembler_fail(
			a,
			{kind = .Protocol, message = fmt.tprintf("unknown finish_reason %q", finish), retryable = false},
		)
	}

	// 按 index 稳定排序，保证 tool call 顺序与 provider 声明一致。
	for i in 1 ..< len(a.slots) {
		j := i
		for j > 0 && a.slots[j].index < a.slots[j - 1].index {
			a.slots[j], a.slots[j - 1] = a.slots[j - 1], a.slots[j]
			j -= 1
		}
	}

	tool_calls := make([dynamic]Assembled_Tool_Call, 0, len(a.slots))
	for &slot in a.slots {
		if len(slot.id) == 0 || len(slot.name) == 0 {
			return assembler_fail(
				a,
				{kind = .Protocol, message = "tool call is missing id or name", retryable = false},
			)
		}
		args_text := string(slot.args[:])
		if len(args_text) == 0 {
			args_text = "{}"
		}
		input, perr := json.parse_string(args_text, .JSON, true)
		if perr != nil {
			return assembler_fail(
				a,
				{
					kind = .Protocol,
					message = fmt.tprintf("tool call %q has invalid JSON arguments: %v", slot.name, perr),
					retryable = false,
				},
			)
		}
		emit_provider_event(a.sink, Provider_Tool_End{index = slot.index})
		append(&tool_calls, Assembled_Tool_Call{id = slot.id, name = slot.name, input = input})
	}

	if stop != .Tool_Use && len(tool_calls) > 0 {
		return assembler_fail(
			a,
			{kind = .Protocol, message = "provider returned tool calls with a non-tool finish_reason", retryable = false},
		)
	}
	if stop == .Tool_Use && len(tool_calls) == 0 {
		return assembler_fail(
			a,
			{kind = .Protocol, message = "provider returned tool_use without tool calls", retryable = false},
		)
	}

	a.finished = true
	usage := a.usage
	if !a.usage_seen {
		usage = Usage{}
	}
	emit_provider_event(
		a.sink,
		Provider_Message_End {
			message_id = a.message_id,
			stop_reason = stop,
			usage = usage,
			tool_calls = tool_calls[:],
			reasoning = string(a.reasoning[:]),
			text = string(a.text[:]),
		},
	)
	return provider_error_none()
}

is_context_too_long_string :: proc(s: string) -> bool {
	lower, _ := strings.to_lower(s, context.temp_allocator)
	return strings.contains(lower, "context_length_exceeded") ||
	       strings.contains(lower, "context_too_long") ||
	       strings.contains(lower, "maximum context length") ||
	       strings.contains(lower, "context length exceeded") ||
	       strings.contains(lower, "too many tokens")
}

Api_Error_Info :: struct {
	message: Maybe(string),
	type:    Maybe(string),
	code:    Maybe(string),
}

Api_Error_Body :: struct {
	error: Maybe(Api_Error_Info),
}

provider_http_error :: proc(status: int, body: string, retry_after_ms: Maybe(int)) -> Provider_Error {
	message := strings.trim_space(body)
	code := ""
	parsed: Api_Error_Body
	if json.unmarshal_string(body, &parsed) == nil {
		if info, ok := parsed.error.?; ok {
			if msg, has_msg := info.message.?; has_msg && len(msg) > 0 {
				message = msg
			}
			if c, has_code := info.code.?; has_code {
				code = c
			}
		}
	}
	if len(message) > 2000 {
		message = message[:2000]
	}
	if len(message) == 0 {
		message = fmt.tprintf("HTTP %d", status)
	}

	kind := Provider_Error_Kind.Invalid_Request
	retryable := false
	switch {
	case status == 401 || status == 403:
		kind = .Auth
	case status == 404:
		kind = .Model_Not_Found
	case status == 429:
		kind = .Rate_Limit
		retryable = true
	case status >= 500:
		kind = .Server_Error
		retryable = true
	case status == 400:
		if is_context_too_long_string(code) || is_context_too_long_string(message) {
			kind = .Context_Too_Long
		} else {
			kind = .Invalid_Request
		}
	case status >= 400:
		kind = .Invalid_Request
	case:
		kind = .Server_Error
		retryable = true
	}
	return {kind = kind, message = message, retryable = retryable, retry_after_ms = retry_after_ms}
}

Provider :: struct {
	base_url:          string,
	api_key:           string,
	llm_timeout_ms:    int,
	stream_include_usage: bool,
}

provider_init :: proc(settings: ^Settings) -> Provider {
	return {
		base_url = build_chat_endpoint(settings.base_url),
		api_key = settings.api_key,
		llm_timeout_ms = settings.llm_timeout_ms,
		stream_include_usage = settings.stream_include_usage,
	}
}

Curl_Context :: struct {
	assembler:         ^Stream_Assembler,
	cancel:            ^Cancel_Token,
	status:            c.long,
	retry_after_ms:    Maybe(int),
	raw:               [dynamic]byte,
	sse:               Sse_Parser,
	started:           time.Tick,
	last_data:         time.Tick,
	got_data:          bool,
	first_byte_timeout: bool,
	protocol_error:    string,
	feed_failed:       bool,
}

curl_write_cb :: proc "c" (buffer: [^]byte, size, nitems: c.size_t, user: rawptr) -> c.size_t {
	context = runtime.default_context()
	ctx := (^Curl_Context)(user)
	n := int(size * nitems)
	if n <= 0 {
		return size * nitems
	}
	ctx.got_data = true
	ctx.last_data = time.tick_now()
	if ctx.status == 200 {
		err := sse_feed(&ctx.sse, buffer[:n], provider_sse_handler, rawptr(ctx.assembler))
		if err != .None {
			if !ctx.assembler.failed {
				ctx.protocol_error = "SSE parse error"
			}
			ctx.feed_failed = true
			return 0
		}
		return size * nitems
	}
	if len(ctx.raw) < 1024 * 1024 {
		append(&ctx.raw, ..buffer[:n])
	}
	return size * nitems
}

provider_sse_handler :: proc(user: rawptr, data: string) -> bool {
	assembler := (^Stream_Assembler)(user)
	err := assembler_feed(assembler, data)
	return err.kind == .None
}

curl_header_cb :: proc "c" (buffer: [^]byte, size, nitems: c.size_t, user: rawptr) -> c.size_t {
	context = runtime.default_context()
	ctx := (^Curl_Context)(user)
	n := int(size * nitems)
	line := string(buffer[:n])
	trimmed := strings.trim_right(line, "\r\n")

	if strings.has_prefix(trimmed, "HTTP/") {
		space := strings.index_byte(trimmed, ' ')
		if space >= 0 && space + 4 <= len(trimmed) {
			status := 0
			for i in space + 1 ..< min(space + 4, len(trimmed)) {
				ch := trimmed[i]
				if ch < '0' || ch > '9' {
					status = 0
					break
				}
				status = status * 10 + int(ch - '0')
			}
			if status >= 200 && status < 600 {
				ctx.status = c.long(status)
				if status == 200 && len(ctx.raw) > 0 {
					err := sse_feed(&ctx.sse, ctx.raw[:], provider_sse_handler, rawptr(ctx.assembler))
					clear(&ctx.raw)
					if err != .None {
						ctx.protocol_error = "SSE parse error"
						ctx.feed_failed = true
						return 0
					}
				}
			}
		}
	}
	lower, _ := strings.to_lower(trimmed, context.temp_allocator)
	if strings.has_prefix(lower, "retry-after:") {
		value := strings.trim_space(trimmed[len("retry-after:"):])
		if seconds, ok := parse_positive_int(value); ok {
			ctx.retry_after_ms = seconds * 1000
		}
	}
	return size * nitems
}

curl_xferinfo_cb :: proc "c" (user: rawptr, dltotal, dlnow, ultotal, ulnow: curl.off_t) -> c.int {
	context = runtime.default_context()
	ctx := (^Curl_Context)(user)
	if cancel_token_cancelled(ctx.cancel) {
		return 1
	}
	if !ctx.got_data && time.tick_since(ctx.started) > FIRST_BYTE_TIMEOUT {
		ctx.first_byte_timeout = true
		return 1
	}
	return 0
}

provider_network_error :: proc(code: curl.code) -> Provider_Error {
	#partial switch code {
	case .E_OPERATION_TIMEDOUT:
		return {kind = .Timeout, message = "LLM request timed out", retryable = true}
	case .E_COULDNT_RESOLVE_HOST,
	     .E_COULDNT_RESOLVE_PROXY,
	     .E_COULDNT_CONNECT,
	     .E_PARTIAL_FILE,
	     .E_GOT_NOTHING,
	     .E_SEND_ERROR,
	     .E_RECV_ERROR,
	     .E_SSL_CONNECT_ERROR:
		return {
			kind = .Network,
			message = fmt.tprintf("network error: %v", code),
			retryable = true,
		}
	}
	return {kind = .Network, message = fmt.tprintf("network error: %v", code), retryable = true}
}

provider_global_ready := false

provider_global_init :: proc() -> Error {
	if provider_global_ready {
		return ok_error()
	}
	if res := curl.global_init(curl.GLOBAL_ALL); res != .E_OK {
		return make_error(.Provider, "libcurl initialization failed: %v", res)
	}
	provider_global_ready = true
	return ok_error()
}

provider_stream :: proc(
	p: ^Provider,
	req: ^Chat_Message_Request,
	sink: Stream_Sink,
	cancel: ^Cancel_Token,
) -> Provider_Error {
	if gerr := provider_global_init(); !is_ok(gerr) {
		return {kind = .Network, message = gerr.message, retryable = false}
	}
	body, berr := build_chat_request_body(req^)
	if !is_ok(berr) {
		return {kind = .Protocol, message = berr.message, retryable = false}
	}

	a: Stream_Assembler
	assembler_init(&a, sink, req.model)
	defer assembler_destroy(&a)

	ctx := Curl_Context {
		assembler = &a,
		cancel    = cancel,
		started   = time.tick_now(),
		last_data = time.tick_now(),
	}
	sse_parser_init(&ctx.sse)
	defer sse_parser_destroy(&ctx.sse)

	h := curl.easy_init()
	if h == nil {
		return assembler_fail(&a, {kind = .Network, message = "curl_easy_init failed", retryable = false})
	}
	defer curl.easy_cleanup(h)

	headers: ^curl.slist
	auth := fmt.tprintf("Authorization: Bearer %s", p.api_key)
	user_agent := fmt.tprintf("User-Agent: ap/%s", VERSION)
	headers = curl.slist_append(headers, cstring("Content-Type: application/json"))
	headers = curl.slist_append(headers, cstring("Accept: text/event-stream"))
	headers = curl.slist_append(headers, strings.clone_to_cstring(user_agent, context.temp_allocator))
	headers = curl.slist_append(headers, strings.clone_to_cstring(auth, context.temp_allocator))
	if headers == nil {
		return assembler_fail(&a, {kind = .Internal, message = "cannot allocate HTTP headers", retryable = false})
	}
	defer curl.slist_free_all(headers)

	body_c := cstring(raw_data(body))
	timeout_ms := c.long(p.llm_timeout_ms)
	one := c.long(1)

	curl.easy_setopt(h, .URL, strings.clone_to_cstring(p.base_url, context.temp_allocator))
	curl.easy_setopt(h, .HTTPHEADER, headers)
	curl.easy_setopt(h, .POST, one)
	curl.easy_setopt(h, .POSTFIELDS, body_c)
	curl.easy_setopt(h, .POSTFIELDSIZE, c.long(len(body)))
	curl.easy_setopt(h, .WRITEFUNCTION, rawptr(curl_write_cb))
	curl.easy_setopt(h, .WRITEDATA, rawptr(&ctx))
	curl.easy_setopt(h, .HEADERFUNCTION, rawptr(curl_header_cb))
	curl.easy_setopt(h, .HEADERDATA, rawptr(&ctx))
	curl.easy_setopt(h, .XFERINFOFUNCTION, rawptr(curl_xferinfo_cb))
	curl.easy_setopt(h, .XFERINFODATA, rawptr(&ctx))
	curl.easy_setopt(h, .NOSIGNAL, one)
	curl.easy_setopt(h, .ACCEPT_ENCODING, cstring("identity"))
	curl.easy_setopt(h, .HTTP_VERSION, c.long(curl.HTTP_VERSION_1_1))
	curl.easy_setopt(h, .CONNECTTIMEOUT_MS, c.long(30000))
	curl.easy_setopt(h, .TIMEOUT_MS, timeout_ms)
	curl.easy_setopt(h, .LOW_SPEED_LIMIT, one)
	curl.easy_setopt(h, .LOW_SPEED_TIME, c.long(120))

	res := curl.easy_perform(h)
	status: c.long
	curl.easy_getinfo(h, .RESPONSE_CODE, &status)
	if ctx.status == 0 && status != 0 {
		ctx.status = status
	}

	if len(ctx.protocol_error) > 0 {
		return assembler_fail(&a, {kind = .Protocol, message = ctx.protocol_error, retryable = false})
	}
	if a.failed {
		return a.last_error
	}
	if cancel_token_cancelled(cancel) {
		return {kind = .Cancelled, message = "cancelled"}
	}
	if ctx.first_byte_timeout {
		return assembler_fail(&a, {kind = .Timeout, message = "LLM first byte timeout", retryable = true})
	}
	if res != .E_OK {
		return assembler_fail(&a, provider_network_error(res))
	}
	if status != 200 {
		err := provider_http_error(int(status), string(ctx.raw[:]), ctx.retry_after_ms)
		return assembler_fail(&a, err)
	}

	sse_err, saw_done := sse_finish(&ctx.sse, provider_sse_handler, rawptr(&a))
	if a.failed {
		return a.last_error
	}
	if sse_err == .Line_Too_Long {
		return assembler_fail(&a, {kind = .Protocol, message = "SSE line too long", retryable = false})
	}
	if sse_err != .None {
		return assembler_fail(&a, {kind = .Protocol, message = "SSE parse error", retryable = false})
	}
	if !saw_done {
		return assembler_fail(
			&a,
			{kind = .Network, message = "stream ended before [DONE]", retryable = true},
		)
	}
	return assembler_finish(&a)
}

provider_usage_from_chunk :: proc(raw: Chat_Usage) -> Usage {
	return usage_from_chat(raw)
}


