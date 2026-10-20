package ap

import "core:encoding/json"
import "core:strings"
import "core:testing"

Sse_Test_Sink :: struct {
	data: [dynamic]string,
}

sse_test_handler :: proc(user: rawptr, data: string) -> bool {
	sink := (^Sse_Test_Sink)(user)
	append(&sink.data, strings.clone(data))
	return true
}

@(test)
test_sse_parser_split_lines_and_utf8 :: proc(t: ^testing.T) {
	p: Sse_Parser
	sse_parser_init(&p)
	defer sse_parser_destroy(&p)
	sink: Sse_Test_Sink

	// 一个 JSON 行被拆成多个 chunk，中文多字节也被切开。
	chunk1: []byte = transmute([]byte)string(": comment\ndata: {\"text\":\"你")
	chunk2: []byte = transmute([]byte)string("好\"}\n\ndata: [DONE]\n\n")
	testing.expect_value(t, sse_feed(&p, chunk1, sse_test_handler, &sink), Sse_Error.None)
	testing.expect_value(t, sse_feed(&p, chunk2, sse_test_handler, &sink), Sse_Error.None)
	testing.expect(t, p.done)
	testing.expect_value(t, len(sink.data), 1)
	testing.expect_value(t, sink.data[0], `{"text":"你好"}`)
}

@(test)
test_sse_parser_multiline_data_and_crlf :: proc(t: ^testing.T) {
	p: Sse_Parser
	sse_parser_init(&p)
	defer sse_parser_destroy(&p)
	sink: Sse_Test_Sink
	chunk: []byte = transmute([]byte)string("data: {\r\ndata: \"a\":1}\r\n\r\n")
	testing.expect_value(t, sse_feed(&p, chunk, sse_test_handler, &sink), Sse_Error.None)
	testing.expect_value(t, len(sink.data), 1)
	testing.expect_value(t, sink.data[0], "{\n\"a\":1}")
}

@(test)
test_sse_parser_finish_without_newline :: proc(t: ^testing.T) {
	p: Sse_Parser
	sse_parser_init(&p)
	defer sse_parser_destroy(&p)
	sink: Sse_Test_Sink
	chunk: []byte = transmute([]byte)string("data: {\"x\":1}")
	testing.expect_value(t, sse_feed(&p, chunk, sse_test_handler, &sink), Sse_Error.None)
	err, done := sse_finish(&p, sse_test_handler, &sink)
	testing.expect_value(t, err, Sse_Error.None)
	testing.expect(t, !done)
	testing.expect_value(t, len(sink.data), 1)
	testing.expect_value(t, sink.data[0], `{"x":1}`)
}

Provider_Test_Sink :: struct {
	events: [dynamic]Provider_Event,
}

provider_test_on_event :: proc(user: rawptr, event: Provider_Event) {
	sink := (^Provider_Test_Sink)(user)
	append(&sink.events, event)
}

provider_test_sink :: proc(sink: ^Provider_Test_Sink) -> Stream_Sink {
	return {user = sink, on_event = provider_test_on_event}
}

provider_test_find_end :: proc(sink: ^Provider_Test_Sink) -> (Provider_Message_End, bool) {
	for event in sink.events {
		if end, ok := event.(Provider_Message_End); ok {
			return end, true
		}
	}
	return {}, false
}

@(test)
test_assembler_tool_call_streaming :: proc(t: ^testing.T) {
	a: Stream_Assembler
	assembler_init(&a, {}, "fallback-model")
	defer assembler_destroy(&a)
	sink: Provider_Test_Sink
	a.sink = provider_test_sink(&sink)

	chunks := []string {
		`{"id":"chatcmpl-1","model":"hy3","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}`,
		`{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"先读文件"},"finish_reason":null}]}`,
		`{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{\"file_"}}]},"finish_reason":null}]}`,
		`{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"path\":\"a.txt\"}"}}]},"finish_reason":null}]}`,
		`{"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}`,
		`{"id":"chatcmpl-1","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"prompt_tokens_details":{"cached_tokens":3},"completion_tokens_details":{"reasoning_tokens":2}}}`,
	}
	for chunk in chunks {
		err := assembler_feed(&a, chunk)
		testing.expect_value(t, err.kind, Provider_Error_Kind.None)
	}
	testing.expect_value(t, assembler_finish(&a).kind, Provider_Error_Kind.None)
	end, found := provider_test_find_end(&sink)
	testing.expect(t, found)
	testing.expect_value(t, end.message_id, "chatcmpl-1")
	testing.expect_value(t, end.stop_reason, Stop_Reason.Tool_Use)
	testing.expect_value(t, len(end.tool_calls), 1)
	testing.expect_value(t, end.tool_calls[0].id, "call_1")
	testing.expect_value(t, end.tool_calls[0].name, "read_file")
	json_expect(t, end.tool_calls[0].input.(json.Object)["file_path"], json.String("a.txt"))
	testing.expect_value(t, end.text, "先读文件")
	testing.expect_value(t, end.usage.input_tokens.?, 10)
	testing.expect_value(t, end.usage.output_tokens.?, 5)
	testing.expect_value(t, end.usage.cached_tokens.?, 3)
	testing.expect_value(t, end.usage.reasoning_tokens.?, 2)
	testing.expect_value(t, end.usage.total_tokens.?, 15)

	// 工具调用结束与消息结束各一次。
	end_count := 0
	tool_end_count := 0
	text_count := 0
	for event in sink.events {
		if _, ok := event.(Provider_Message_End); ok {
			end_count += 1
		}
		if _, ok := event.(Provider_Tool_End); ok {
			tool_end_count += 1
		}
		if _, ok := event.(Provider_Text_Delta); ok {
			text_count += 1
		}
	}
	testing.expect_value(t, end_count, 1)
	testing.expect_value(t, tool_end_count, 1)
	testing.expect_value(t, text_count, 1)
}

@(test)
test_assembler_text_stop_and_missing_usage :: proc(t: ^testing.T) {
	a: Stream_Assembler
	assembler_init(&a, {}, "m")
	defer assembler_destroy(&a)
	sink: Provider_Test_Sink
	a.sink = provider_test_sink(&sink)
	testing.expect_value(
		t,
		assembler_feed(&a, `{"id":"x","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}`).kind,
		Provider_Error_Kind.None,
	)
	testing.expect_value(
		t,
		assembler_feed(&a, `{"id":"x","choices":[{"index":0,"delta":{},"finish_reason":"length"}]}`).kind,
		Provider_Error_Kind.None,
	)
	testing.expect_value(t, assembler_finish(&a).kind, Provider_Error_Kind.None)
	end, found := provider_test_find_end(&sink)
	testing.expect(t, found)
	testing.expect_value(t, end.stop_reason, Stop_Reason.Max_Tokens)
	testing.expect_value(t, end.usage.input_tokens, Maybe(int)(nil))
}

@(test)
test_assembler_protocol_errors :: proc(t: ^testing.T) {
	cases := []struct {
		chunks: []string,
		kind:   Provider_Error_Kind,
	} {
		{
			chunks = []string{
				`{"id":"x","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"bash","arguments":"{bad"}}]},"finish_reason":null}]}`,
				`{"id":"x","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}`,
			},
			kind = .Protocol,
		},
		{
			chunks = []string{`{"id":"x","choices":[{"index":0,"delta":{"content":"a"},"finish_reason":null}]}`},
			kind = .Protocol,
		},
		{
			chunks = []string{`{"id":"x","choices":[{"index":0,"delta":{},"finish_reason":"wat"}]}`},
			kind = .Protocol,
		},
		{
			chunks = []string{
				`{"id":"x","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"bash","arguments":"{}"}}]},"finish_reason":null}]}`,
				`{"id":"x","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`,
			},
			kind = .Protocol,
		},
	}
	for c in cases {
		a: Stream_Assembler
		assembler_init(&a, {}, "m")
		sink: Provider_Test_Sink
		a.sink = provider_test_sink(&sink)
		for chunk in c.chunks {
			_ = assembler_feed(&a, chunk)
		}
		err := assembler_finish(&a)
		testing.expect_value(t, err.kind, c.kind)
		assembler_destroy(&a)
	}
}

@(test)
test_provider_http_error_mapping :: proc(t: ^testing.T) {
	e1 := provider_http_error(401, `{"error":{"message":"bad key"}}`, nil)
	testing.expect_value(t, e1.kind, Provider_Error_Kind.Auth)
	testing.expect_value(t, e1.retryable, false)
	testing.expect_value(t, e1.message, "bad key")

	e2 := provider_http_error(404, `{"error":{"message":"model missing"}}`, nil)
	testing.expect_value(t, e2.kind, Provider_Error_Kind.Model_Not_Found)

	e3 := provider_http_error(429, `{"error":{"message":"slow down"}}`, 2000)
	testing.expect_value(t, e3.kind, Provider_Error_Kind.Rate_Limit)
	testing.expect_value(t, e3.retryable, true)
	testing.expect_value(t, e3.retry_after_ms.?, 2000)

	e4 := provider_http_error(500, `{"error":{"message":"boom"}}`, nil)
	testing.expect_value(t, e4.kind, Provider_Error_Kind.Server_Error)
	testing.expect_value(t, e4.retryable, true)

	e5 := provider_http_error(400, `{"error":{"message":"maximum context length exceeded","code":"context_length_exceeded"}}`, nil)
	testing.expect_value(t, e5.kind, Provider_Error_Kind.Context_Too_Long)
	testing.expect_value(t, e5.retryable, false)

	e6 := provider_http_error(400, `{"error":{"message":"bad parameter"}}`, nil)
	testing.expect_value(t, e6.kind, Provider_Error_Kind.Invalid_Request)
}

@(test)
test_chat_request_body_shape :: proc(t: ^testing.T) {
	messages := []Chat_Message {
		{role = "user", content = "hi"},
		{
			role = "assistant",
			tool_calls = []Chat_Tool_Call {
				{
					id = "call_1",
					type = "function",
					function = Chat_Tool_Function{name = "read_file", arguments = `{"file_path":"a.txt"}`},
				},
			},
		},
		{role = "tool", content = "ok", tool_call_id = "call_1"},
	}
	params := make(json.Object)
	params["type"] = json.String("object")
	tools := []Tool_Def {
		{
			type = "function",
			function = Function_Def {
				name = "read_file",
				description = "read",
				parameters = params,
			},
		},
	}
	body, err := build_chat_request_body(
		{
			model = "m",
			messages = messages,
			tools = tools,
			max_tokens = 123,
			include_usage = true,
		},
	)
	testing.expect_value(t, err.code, Exit_Code.OK)
	value, perr := json.parse_string(string(body), .JSON, true)
	testing.expect_value(t, perr, nil)
	obj := value.(json.Object)
	json_expect(t, obj["model"], json.String("m"))
	json_expect(t, obj["max_tokens"], json.Integer(123))
	json_expect(t, obj["stream"], json.Boolean(true))
	json_expect(t, obj["parallel_tool_calls"], json.Boolean(false))
	json_expect(t, obj["tool_choice"], json.String("auto"))
	opts := obj["stream_options"].(json.Object)
	json_expect(t, opts["include_usage"], json.Boolean(true))
	msgs := obj["messages"].(json.Array)
	assistant := msgs[1].(json.Object)
	json_expect(t, assistant["content"], json.Null(nil))
	tool := msgs[2].(json.Object)
	json_expect(t, tool["tool_call_id"], json.String("call_1"))

	body2, _ := build_chat_request_body({model = "m", messages = messages, max_tokens = 1})
	value2, perr2 := json.parse_string(string(body2), .JSON, true)
	testing.expect_value(t, perr2, nil)
	obj2 := value2.(json.Object)
	_, has_tools := obj2["tools"]
	testing.expect(t, !has_tools)
	_, has_options := obj2["stream_options"]
	testing.expect(t, !has_options)
}

@(test)
test_chat_request_body_preserves_unicode :: proc(t: ^testing.T) {
	messages := []Chat_Message{{role = "user", content = "中文请求"}}
	body, err := build_chat_request_body({model = "m", messages = messages, max_tokens = 16})
	testing.expect_value(t, err.code, Exit_Code.OK)
	text := string(body)
	testing.expect(t, test_contains(text, "中文请求"))
	testing.expect(t, !test_contains(text, `\u4e2d`))
}

@(test)
test_chat_endpoint_building :: proc(t: ^testing.T) {
	testing.expect_value(t, build_chat_endpoint("http://x/v1"), "http://x/v1/chat/completions")
	testing.expect_value(t, build_chat_endpoint("http://x/v1/"), "http://x/v1/chat/completions")
	testing.expect_value(t, build_chat_endpoint("http://x/v1/chat/completions"), "http://x/v1/chat/completions")
}

@(test)
test_context_too_long_detection :: proc(t: ^testing.T) {
	testing.expect(t, is_context_too_long_string("This model's maximum context length is 8192 tokens"))
	testing.expect(t, is_context_too_long_string("context_length_exceeded"))
	testing.expect(t, !is_context_too_long_string("bad request"))
}
