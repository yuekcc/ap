package main

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:time"

// HTTP API：路由表与全部 handler。约定见 docs/web.md「HTTP API」：
// JSON 请求/响应、语义化状态码、错误统一 {"error":{"code","message"}}。

MAX_PROMPT_BYTES :: 1024 * 1024

// 路由表：server 的 register_route 需要动态数组分配，不能放在 contextless
// 的 @(init) 里，所以 main 在开始 accept 之前显式调用一次；测试也用它重置。
API_ROUTES :: []Http_Route {
	{.Get, "/api/health", false, api_health},
	{.Get, "/api/config", false, api_config},
	{.Get, "/api/session/current", false, api_session_current},
	{.Post, "/api/session/new", false, api_session_new},
	{.Get, "/api/sessions", false, api_sessions},
	{.Post, "/api/session/resume", false, api_session_resume},
	{.Get, "/api/history", false, api_history},
	{.Get, "/api/cwd", false, api_cwd},
	{.Post, "/api/cwd/pick", false, api_cwd_pick},
	{.Post, "/api/turn", false, api_turn_start},
	{.Delete, "/api/turn", false, api_turn_cancel},
	{.Get, "/api/events", false, api_events},
}

// 路由表是进程级全局状态：必须用堆分配。测试里 context.allocator 是每个
// 测试任务结束后回滚的 arena，用它建表会让下一个测试踩到已释放内存。
API_ROUTES_REGISTERED: bool

api_register_routes :: proc() {
	if API_ROUTES_REGISTERED {
		return
	}
	ROUTES.routes = make([dynamic]Http_Route, 0, len(API_ROUTES), runtime.heap_allocator())
	for route in API_ROUTES {
		append(&ROUTES.routes, route)
	}
	API_ROUTES_REGISTERED = true
}

// ---------------------------------------------------------------------------
// JSON 响应
// ---------------------------------------------------------------------------

Api_Error :: struct {
	code:    string `json:"code"`,
	message: string `json:"message"`,
}

Api_Error_Envelope :: struct {
	error: Api_Error `json:"error"`,
}

Api_Health :: struct {
	ok:      bool   `json:"ok"`,
	version: string `json:"version"`,
}

Api_Config :: struct {
	model:      Maybe(string) `json:"model"`,
	agent:      Maybe(string) `json:"agent"`,
	max_steps:  Maybe(int)    `json:"max_steps"`,
	max_tokens: Maybe(int)    `json:"max_tokens"`,
	cwd:        string       `json:"cwd"`,
	platform:   string       `json:"platform"`,
}

Api_Session_Current :: struct {
	session_key: Maybe(string) `json:"session_key"`,
	session_id:  Maybe(string) `json:"session_id"`,
	running:     bool          `json:"running"`,
	turn:        Maybe(int)    `json:"turn"`,
}

Api_Session_Id :: struct {
	session_id:  Maybe(string) `json:"session_id"`,
	session_key: string        `json:"session_key"`,
}

Api_Session_Entry :: struct {
	session_id: string `json:"session_id"`,
	ts:         i64    `json:"ts"`,
	turns:      int    `json:"turns"`,
	running:    bool   `json:"running"`,
}

Api_Cwd :: struct {
	cwd: string `json:"cwd"`,
}

Api_Accepted :: struct {
	accepted:    bool   `json:"accepted"`,
	session_key: string `json:"session_key"`,
}

Api_Cancelled :: struct {
	cancelled: bool `json:"cancelled"`,
}

Api_History :: struct {
	events: []json.Value `json:"events"`,
}

// 用标准库 marshal 保证转义正确；body 落在请求级临时分配器里，
// serve_connection 写完响应后统一回收。
api_json :: proc(response: ^Http_Response, status: int, value: any) {
	data, err := json.marshal(value, {}, context.temp_allocator)
	if err != nil {
		// 编码失败说明服务端有 bug；不能保留调用方给的成功状态码。
		response.status = 500
		response_set_header(response, "Content-Type", "application/json; charset=utf-8")
		response.body = transmute([]byte)string(
			`{"error":{"code":"internal_error","message":"cannot encode response"}}`,
		)
		return
	}
	response_set_header(response, "Content-Type", "application/json; charset=utf-8")
	response.status = status
	response.body = data
}

api_error :: proc(response: ^Http_Response, status: int, code, message: string) {
	api_json(response, status, Api_Error_Envelope{error = {code = code, message = message}})
}

// core:encoding/json 的 Object 是 distinct map，不能直接下标赋值；
// 转成底层 map 类型后写入。当前 Odin 的 map 头是按值拷贝的，插入触发扩容时
// 只更新副本会丢失新键，所以必须把 header 写回调用方。
Json_Object_Map :: map[string]json.Value

json_object_set :: proc(obj: ^json.Object, key: string, value: json.Value) {
	base := Json_Object_Map(obj^)
	base[key] = value
	obj^ = json.Object(base)
}

json_object_remove :: proc(obj: ^json.Object, key: string) {
	base := Json_Object_Map(obj^)
	delete_key(&base, key)
	obj^ = json.Object(base)
}

api_parse_json :: proc(body: []byte, value: ^$T) -> bool {
	if len(body) == 0 {
		return false
	}
	err := json.unmarshal(body, value, json.DEFAULT_SPECIFICATION, context.temp_allocator)
	return err == nil
}

// query 参数：只做 percent-decode，不做 '+' → 空格（session id 里没有空格）。
query_param :: proc(query, name: string) -> (string, bool) {
	for pair in strings.split(query, "&", context.temp_allocator) {
		if len(pair) == 0 {
			continue
		}
		eq := strings.index_byte(pair, '=')
		key := pair
		value := ""
		if eq >= 0 {
			key = pair[:eq]
			value = pair[eq + 1:]
		}
		if key != name {
			continue
		}
		decoded, ok := percent_decode(value, context.temp_allocator)
		if !ok {
			return "", false
		}
		return decoded, true
	}
	return "", false
}

platform_name :: proc() -> string {
	when ODIN_OS == .Windows {
		return "windows"
	} else when ODIN_OS == .Linux {
		return "linux"
	} else when ODIN_OS == .Darwin {
		return "darwin"
	} else {
		return "unix"
	}
}

// ---------------------------------------------------------------------------
// 只读端点
// ---------------------------------------------------------------------------

api_health :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	api_json(response, 200, Api_Health{ok = true, version = WEB_VERSION})
}

api_config :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	app := (^App)(user)
	api_json(
		response,
		200,
		Api_Config {
			model = app.options.model,
			agent = app.options.agent,
			max_steps = app.options.max_steps,
			max_tokens = app.options.max_tokens,
			cwd = app_cwd(app),
			platform = platform_name(),
		},
	)
}

// session_key 缺省时返回「最近活跃」的 session；带 key 时返回该 session 的
// 运行态，供前端重连后校正 running/turn（多标签页各自轮询自己的 session）。
api_session_current :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	app := (^App)(user)
	key, _ := query_param(request.query, "session_key")
	state := runner_state(app, key, context.temp_allocator)
	current := Api_Session_Current {
		running = state.running,
		turn    = state.turn,
	}
	if len(state.key) > 0 {
		current.session_key = state.key
	}
	if len(state.session_id) > 0 {
		current.session_id = state.session_id
	}
	api_json(response, 200, current)
}

api_cwd :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	app := (^App)(user)
	api_json(response, 200, Api_Cwd{cwd = app_cwd(app)})
}

// ---------------------------------------------------------------------------
// session 指针
// ---------------------------------------------------------------------------

// 新建会话只分配一个 slot：下一条提示词让 ap 创建真实 session，不落盘任何东西。
// 其他 session 的运行态完全不受影响（多标签页各开各的新会话）。
api_session_new :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	app := (^App)(user)
	key := runner_session_new(app, context.temp_allocator)
	api_json(response, 200, Api_Session_Id{session_key = key})
}

Api_Resume_Body :: struct {
	session_id: string `json:"session_id"`,
}

api_session_resume :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	app := (^App)(user)
	body: Api_Resume_Body
	if !api_parse_json(request.body, &body) {
		api_error(response, 400, "invalid_json", "request body must be a JSON object")
		return
	}
	if len(strings.trim_space(body.session_id)) == 0 {
		api_error(response, 400, "invalid_request", "session_id is required")
		return
	}
	// 切换视图不影响其他 session 的运行中 turn；同一 session 的分飞由
	// POST /api/turn 自己保证。
	key := runner_session_resume(app, body.session_id, context.temp_allocator)
	api_json(response, 200, Api_Session_Id{
		session_id = body.session_id,
		session_key = key,
	})
}

// 会话列表：id 来自 internal/sessions，ts 取文件 mtime（毫秒），
// turns 数 turn_start 行（读不到文件时尽力而为，返回 0）。
api_sessions :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	app := (^App)(user)
	project := app_project(app)
	ids, ids_err := session_ids(project)
	if !is_ok(ids_err) {
		api_error(response, 500, "internal_error", ids_err.message)
		return
	}
	defer {
		for id in ids {
			delete(id, context.allocator)
		}
		delete(ids, context.allocator)
	}

	entries := make([dynamic]Api_Session_Entry, 0, len(ids), context.temp_allocator)
	for id in ids {
		ts: i64 = 0
		if info, stat_err := os.stat(session_file(project, id), context.temp_allocator); stat_err == nil {
			ts = time.time_to_unix_nano(info.modification_time) / 1_000_000
		}
		append(&entries, Api_Session_Entry{
			session_id = id,
			ts         = ts,
			turns      = session_turn_count(project, id),
			running    = runner_session_running(app, id),
		})
	}
	// 最近修改的在前，前端下拉框直接可用。
	for i in 1 ..< len(entries) {
		j := i
		for j > 0 && entries[j].ts > entries[j - 1].ts {
			entries[j], entries[j - 1] = entries[j - 1], entries[j]
			j -= 1
		}
	}
	api_json(response, 200, entries[:])
}

Type_Probe :: struct {
	type: string `json:"type"`,
}

session_turn_count :: proc(project: Project, session_id: string) -> int {
	data, err := read_transcript(project, session_id)
	if !is_ok(err) {
		return 0
	}
	defer delete(data, context.allocator)

	count := 0
	it := Line_Iterator{data = string(data)}
	for {
		line, more := next_line(&it)
		if !more {
			break
		}
		probe: Type_Probe
		if json.unmarshal(transmute([]byte)line, &probe, json.DEFAULT_SPECIFICATION, context.temp_allocator) == nil {
			if probe.type == "turn_start" {
				count += 1
			}
		}
	}
	return count
}

// ---------------------------------------------------------------------------
// history：transcript 重放
// ---------------------------------------------------------------------------

// 逐行读 JSONL；保留原始事件字段，只补前端渲染需要的解析结果：
// - session_start 的 content_ref 解析成 content（缺失 blob 退化为 content_preview）
// - message_end 的 text_ref 解析成 text、tool_use 的 input_ref 解析成 input
//   （缺失 blob 分别退化为 text_preview / input_preview）
// - tool_execution_start 增加 args_preview（与 ap-tui tool_args_text 相同规则）
// - tool_execution_end 超过 200 行/20KB 时换成 content_preview 并标记 content_truncated
api_history :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	app := (^App)(user)
	session_id, has_session := query_param(request.query, "session_id")
	if !has_session || len(session_id) == 0 {
		api_error(response, 400, "invalid_request", "session_id query parameter is required")
		return
	}
	project := app_project(app)
	data, read_err := read_transcript(project, session_id)
	if !is_ok(read_err) {
		api_error(response, 404, "session_not_found", read_err.message)
		return
	}
	defer delete(data, context.allocator)

	events := make([dynamic]json.Value, 0, 32, context.temp_allocator)
	it := Line_Iterator{data = string(data)}
	for {
		line, more := next_line(&it)
		if !more {
			break
		}
		ev, parsed := parse_event_line(line)
		if !parsed {
			continue
		}
		value, json_err := json.parse_string(line, .JSON, true, context.temp_allocator)
		if json_err != nil {
			continue
		}
		history_enrich_event(&value, ev, project)
		append(&events, value)
	}
	api_json(response, 200, Api_History{events = events[:]})
}

history_enrich_event :: proc(value: ^json.Value, ev: Event, project: Project) {
	obj, is_object := value.(json.Object)
	if !is_object {
		return
	}
	// map 头按值拷贝：所有写入先落到 obj，再写回 union。
	defer value^ = obj
	switch ev.type {
	case "session_start":
		if _, has_content := obj["content"]; has_content {
			return
		}
		if ref, has_ref := json_string_field(obj, "content_ref"); has_ref {
			if blob, blob_err := blob_read(project, ref, context.temp_allocator); is_ok(blob_err) {
				json_object_set(&obj, "content", json.String(string(blob)))
				return
			}
		}
		if preview, has_preview := json_string_field(obj, "content_preview"); has_preview {
			json_object_set(&obj, "content", json.String(preview))
		}
	case "message_end":
		blocks, ok := obj["content"].(json.Array)
		if !ok {
			return
		}
		for block_value, i in blocks {
			block, block_is_object := block_value.(json.Object)
			if !block_is_object {
				continue
			}
			block_type, _ := json_string_field(block, "type")
			switch block_type {
			case "text":
				history_resolve_text_block(&block, project)
			case "tool_use":
				history_resolve_tool_input(&block, project)
			}
			blocks[i] = block
		}
	case "tool_execution_start":
		local := project
		args_text := tool_args_text(ev, &local)
		json_object_set(&obj, "args_preview", json.String(args_text))
	case "tool_execution_end":
		local := project
		content, _ := tool_result_text(ev, &local)
		preview, truncated := preview_content(content)
		// 与 ap-tui 重放一致：超限结果只给预览窗口。为了让前端据此显示
		// 「已截断」提示，截断时把完整 content 拿掉、改放 content_preview。
		if truncated {
			json_object_remove(&obj, "content")
			json_object_set(&obj, "content_preview", json.String(preview))
		} else {
			json_object_set(&obj, "content", json.String(content))
		}
		json_object_set(&obj, "content_truncated", json.Boolean(truncated))
	}
}

history_resolve_text_block :: proc(block: ^json.Object, project: Project) {
	if _, has_text := json_string_field(block^, "text"); has_text {
		return
	}
	if ref, has_ref := json_string_field(block^, "text_ref"); has_ref {
		if blob, blob_err := blob_read(project, ref, context.temp_allocator); is_ok(blob_err) {
			json_object_set(block, "text", json.String(string(blob)))
			return
		}
	}
	if preview, has_preview := json_string_field(block^, "text_preview"); has_preview {
		json_object_set(block, "text", json.String(preview))
	}
}

// tool_use 的 input 是结构化 JSON：blob 内容必须能整体解析；解析失败与
// blob 缺失都退化为 input_preview（字符串），至少让前端能显示参数摘要。
history_resolve_tool_input :: proc(block: ^json.Object, project: Project) {
	if _, has_input := block["input"]; has_input {
		return
	}
	if ref, has_ref := json_string_field(block^, "input_ref"); has_ref {
		if blob, blob_err := blob_read(project, ref, context.temp_allocator); is_ok(blob_err) {
			if parsed, parse_err := json.parse_string(
				string(blob),
				.JSON,
				true,
				context.temp_allocator,
			); parse_err == nil {
				json_object_set(block, "input", parsed)
				return
			}
		}
	}
	if preview, has_preview := json_string_field(block^, "input_preview"); has_preview {
		json_object_set(block, "input", json.String(preview))
	}
}

// ---------------------------------------------------------------------------
// turn
// ---------------------------------------------------------------------------

Api_Turn_Body :: struct {
	prompt:      string        `json:"prompt"`,
	session_key: string        `json:"session_key"`,
	model:       Maybe(string) `json:"model"`,
	agent:       Maybe(string) `json:"agent"`,
	max_steps:   Maybe(int)    `json:"max_steps"`,
	max_tokens:  Maybe(int)    `json:"max_tokens"`,
}

api_turn_start :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	app := (^App)(user)
	body: Api_Turn_Body
	if !api_parse_json(request.body, &body) {
		api_error(response, 400, "invalid_json", "request body must be a JSON object")
		return
	}
	if len(strings.trim_space(body.prompt)) == 0 {
		api_error(response, 400, "prompt_empty", "prompt is required")
		return
	}
	if len(body.prompt) > MAX_PROMPT_BYTES {
		api_error(response, 413, "prompt_too_large", "prompt must be at most 1MB")
		return
	}
	if steps, ok := body.max_steps.?; ok && steps <= 0 {
		api_error(response, 400, "invalid_request", "max_steps must be a positive integer")
		return
	}
	if tokens, ok := body.max_tokens.?; ok && tokens <= 0 {
		api_error(response, 400, "invalid_request", "max_tokens must be a positive integer")
		return
	}

	request_options := Turn_Request {
		prompt      = body.prompt,
		session_key = strings.trim_space(body.session_key),
		model       = non_empty_maybe(body.model),
		agent       = non_empty_maybe(body.agent),
		max_steps   = body.max_steps,
		max_tokens  = body.max_tokens,
	}
	status, key, message := runner_start_turn(app, request_options, context.temp_allocator)
	switch status {
	case .Started:
		api_json(response, 202, Api_Accepted{accepted = true, session_key = key})
	case .Busy:
		api_error(response, 409, "turn_running", message)
	case .Shutting_Down:
		api_error(response, 503, "shutting_down", message)
	case .Failed:
		api_error(response, 500, "internal_error", message)
	}
}

non_empty_maybe :: proc(value: Maybe(string)) -> Maybe(string) {
	if text, ok := value.?; ok && len(strings.trim_space(text)) > 0 {
		return text
	}
	return nil
}

api_turn_cancel :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	app := (^App)(user)
	key, _ := query_param(request.query, "session_key")
	cancelled := runner_cancel(app, key)
	api_json(response, 202, Api_Cancelled{cancelled = cancelled})
}

// ---------------------------------------------------------------------------
// SSE
// ---------------------------------------------------------------------------

// 每个标签页订阅自己的 session（session_key 可以是 slot key 或真实 id），
// 只收到这个 session 的事件；不带参数时保持旧的「订阅全部」行为。
api_events :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	app := (^App)(user)
	key, _ := query_param(request.query, "session_key")
	sub: Sse_Subscriber
	if !sse_hub_subscribe_topic(&app.hub, &sub, key) {
		api_error(response, 500, "internal_error", "cannot register SSE subscriber")
		return
	}
	defer sse_hub_unsubscribe(&app.hub, &sub)

	response_set_header(response, "Content-Type", "text/event-stream")
	response_set_header(response, "Cache-Control", "no-cache")
	response_set_header(response, "Connection", "close")
	if !response_stream_start(response) {
		return
	}
	for {
		frame, ok := sse_subscriber_recv(&sub)
		if !ok {
			break
		}
		wrote := response_stream_write(response, transmute([]byte)frame)
		delete(frame, context.allocator)
		if !wrote {
			break
		}
	}
	response_stream_end(response)
}
