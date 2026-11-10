package engine

import "../platform"
import "../protocol"

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:time"

PREVIEW_BYTES :: 8192

// 事件类型与公共信封定义在 ap-core/protocol；这里保留别名让引擎代码保持简洁。
Usage :: protocol.Usage
Event_Header :: protocol.Event_Header
Event :: protocol.Transcript_Event

usage_add :: protocol.usage_add
usage_has_any :: protocol.usage_has_any

Session_Start_Event :: protocol.Session_Start_Event
Session_End_Event :: protocol.Session_End_Event
User_Message_Event :: protocol.User_Message_Event
Turn_Start_Event :: protocol.Turn_Start_Event
Turn_End_Event :: protocol.Turn_End_Event
Turn_Context :: protocol.Turn_Context
Step_Start_Event :: protocol.Step_Start_Event
Message_Start_Event :: protocol.Message_Start_Event
Content_Block :: protocol.Content_Block
Message_End_Event :: protocol.Message_End_Event
Tool_Execution_Start_Event :: protocol.Tool_Execution_Start_Event
Tool_Execution_End_Event :: protocol.Tool_Execution_End_Event
Tool_Image_Ref :: protocol.Tool_Image_Ref
Error_Event :: protocol.Error_Event
Cancel_Event :: protocol.Cancel_Event
Handoff_Event :: protocol.Handoff_Event

// wire 取值别名；唯一权威在 ap-core/protocol/names.odin。
event_type_known :: protocol.event_type_known
event_type_canonical :: protocol.event_type_canonical

EVENT_SESSION_START :: protocol.EVENT_SESSION_START
EVENT_SESSION_END :: protocol.EVENT_SESSION_END
EVENT_USER_MESSAGE :: protocol.EVENT_USER_MESSAGE
EVENT_TURN_START :: protocol.EVENT_TURN_START
EVENT_TURN_END :: protocol.EVENT_TURN_END
EVENT_STEP_START :: protocol.EVENT_STEP_START
EVENT_MESSAGE_START :: protocol.EVENT_MESSAGE_START
EVENT_MESSAGE_END :: protocol.EVENT_MESSAGE_END
EVENT_TOOL_EXECUTION_START :: protocol.EVENT_TOOL_EXECUTION_START
EVENT_TOOL_EXECUTION_END :: protocol.EVENT_TOOL_EXECUTION_END
EVENT_ERROR :: protocol.EVENT_ERROR
EVENT_CANCEL :: protocol.EVENT_CANCEL
EVENT_HANDOFF :: protocol.EVENT_HANDOFF

STOP_REASON_STOP :: protocol.STOP_REASON_STOP
STOP_REASON_TOOL_USE :: protocol.STOP_REASON_TOOL_USE
STOP_REASON_MAX_TOKENS :: protocol.STOP_REASON_MAX_TOKENS
STOP_REASON_MAX_STEPS :: protocol.STOP_REASON_MAX_STEPS
STOP_REASON_CANCELLED :: protocol.STOP_REASON_CANCELLED
STOP_REASON_CONTEXT_TOO_LONG :: protocol.STOP_REASON_CONTEXT_TOO_LONG
STOP_REASON_HANDOFF :: protocol.STOP_REASON_HANDOFF

HANDOFF_REASON_BUDGET_EXHAUSTED :: protocol.HANDOFF_REASON_BUDGET_EXHAUSTED
HANDOFF_REASON_CONTEXT_TOO_LONG :: protocol.HANDOFF_REASON_CONTEXT_TOO_LONG
HANDOFF_REASON_MANUAL :: protocol.HANDOFF_REASON_MANUAL

SESSION_END_EXIT :: protocol.SESSION_END_EXIT
SESSION_END_SIGNAL :: protocol.SESSION_END_SIGNAL
SESSION_END_ERROR :: protocol.SESSION_END_ERROR

SCOPE_LLM :: protocol.SCOPE_LLM
SCOPE_TOOL :: protocol.SCOPE_TOOL
SCOPE_SESSION :: protocol.SCOPE_SESSION
SCOPE_STEP :: protocol.SCOPE_STEP
SCOPE_TURN :: protocol.SCOPE_TURN

ROLE_SYSTEM :: protocol.ROLE_SYSTEM
ROLE_USER :: protocol.ROLE_USER
ROLE_ASSISTANT :: protocol.ROLE_ASSISTANT
ROLE_TOOL :: protocol.ROLE_TOOL

BLOCK_TEXT :: protocol.BLOCK_TEXT
BLOCK_TOOL_USE :: protocol.BLOCK_TOOL_USE

TOOL_ERROR_CANCELLED :: protocol.TOOL_ERROR_CANCELLED

Transcript_Error :: enum {
	None,
	Not_Found,
	Open_Failed,
	Write_Failed,
	Read_Failed,
	Corrupt,
	Unsupported_Version,
	Blob_Missing,
	Blob_Corrupt,
	Blob_Write_Failed,
}

Transcript_Store :: struct {
	project:    Project,
	session_id: string,
	path:       string,
	file:       ^os.File,
	next_seq:   int,
	settings:   ^Settings,
}

make_header :: proc(store: ^Transcript_Store, typ: string) -> Event_Header {
	header := Event_Header {
		v    = SCHEMA_VERSION,
		seq  = store.next_seq,
		ts   = time.time_to_unix_nano(time.now()) / 1_000_000,
		type = typ,
	}
	store.next_seq += 1
	return header
}

open_transcript :: proc(store: ^Transcript_Store, append: bool) -> Error {
	flags: os.File_Flags
	if append {
		flags = {.Read, .Write, .Append}
	} else {
		flags = {.Read, .Write, .Create, .Excl}
	}
	file, ferr := os.open(store.path, flags)
	if ferr != nil {
		return make_error(.Usage, "cannot open transcript %s: %v", store.path, ferr)
	}
	store.file = file
	// 只有新建/复制的 transcript 才从 0 开始；恢复（append）时调用方已经从
	// 源文件算出了最大 seq，这里不能覆盖，否则同一 session 的 seq 会回到 0，
	// 依赖 seq 去重的读取方（ap-web）会把后续 turn 当成重复事件丢掉。
	if !append {
		store.next_seq = 0
	}
	return ok_error()
}

transcript_store :: proc(project: Project, session_id: string, settings: ^Settings) -> Transcript_Store {
	return {
		project    = project,
		session_id = session_id,
		path       = platform.session_file(project, session_id),
		settings   = settings,
	}
}

new_transcript_store :: proc(project: Project, session_id: string, settings: ^Settings) -> (Transcript_Store, Error) {
	store := transcript_store(project, session_id, settings)
	if os.exists(store.path) {
		return store, make_error(.Usage, "session %q already exists at %s", session_id, store.path)
	}
	if err := open_transcript(&store, false); !is_ok(err) {
		return store, err
	}
	return store, ok_error()
}

trim_incomplete_last_line :: proc(path: string) -> Error {
	data, derr := os.read_entire_file_from_path(path, context.allocator)
	if derr != nil || len(data) == 0 {
		return ok_error()
	}
	if data[len(data) - 1] == '\n' {
		return ok_error()
	}
	idx := strings.last_index_byte(string(data), '\n')
	keep := 0
	if idx >= 0 {
		keep = idx + 1
	}
	file, ferr := os.open(path, {.Read, .Write})
	if ferr != nil {
		return make_error(.Usage, "cannot repair transcript %s: %v", path, ferr)
	}
	defer os.close(file)
	if terr := os.truncate(file, i64(keep)); terr != nil {
		return make_error(.Usage, "cannot repair transcript %s: %v", path, terr)
	}
	return ok_error()
}

resume_transcript_store :: proc(project: Project, session_id: string, settings: ^Settings) -> (Transcript_Store, Error) {
	store := transcript_store(project, session_id, settings)
	if !os.exists(store.path) {
		return store, make_error(
			.Usage,
			"session %q not found in project %s (expected %s)\nhint: run ap from the directory where the session was created",
			session_id,
			project.hash,
			store.path,
		)
	}
	// 崩溃可能留下没有换行结尾的半行；它从未成为完整事件，重放时丢弃并截掉，
	// 否则后续追加会把它变成中间行。
	if terr := trim_incomplete_last_line(store.path); !is_ok(terr) {
		return store, terr
	}
	events, rerr := transcript_read_all(project, session_id)
	if !is_ok(rerr) {
		return store, rerr
	}
	for ev in events {
		if ev.seq + 1 > store.next_seq {
			store.next_seq = ev.seq + 1
		}
	}
	if err := open_transcript(&store, true); !is_ok(err) {
		return store, err
	}
	// append 模式下文件偏移由 O_APPEND 保证；seq 从最大值继续。
	return store, ok_error()
}

// 事件结构里的 header 是 using 嵌入字段，json.marshal 会输出成嵌套对象；
// transcript schema 要求 header 字段平铺在顶层。这里直接把两段序列化结果
// 拼成一行，省掉「解析成 JSON 树 → 合并 → 再序列化」的整套临时对象
// （那条路径每条事件都要留一棵树加两份字节）。
flatten_event_json :: proc(header_json, event_json: string) -> ([]byte, Error) {
	prefix := `{"header":`
	if !strings.has_prefix(event_json, prefix) {
		return nil, make_error(.Internal, "transcript event does not start with the embedded header")
	}
	rest_start := len(prefix) + len(header_json)
	if rest_start >= len(event_json) {
		return nil, make_error(.Internal, "transcript event header is malformed")
	}
	rest := event_json[rest_start:]
	if rest[0] != ',' && rest[0] != '}' {
		return nil, make_error(.Internal, "transcript event header is malformed")
	}
	if len(header_json) < 2 || header_json[len(header_json) - 1] != '}' {
		return nil, make_error(.Internal, "transcript event header is malformed")
	}
	// 去掉 header 对象自己的两个花括号，字段直接平铺到顶层。
	b := strings.builder_make(0, len(event_json))
	strings.write_byte(&b, '{')
	strings.write_string(&b, header_json[1:len(header_json) - 1])
	strings.write_string(&b, rest)
	return transmute([]byte)strings.to_string(b), ok_error()
}

// 从事件值里取出 using 嵌入的 header。调用方只传带 header 的事件结构。
event_header_of :: proc(event: any) -> Event_Header {
	data := rawptr(uintptr(event.data))
	return (^Event_Header)(data)^
}

transcript_append_line :: proc(store: ^Transcript_Store, event: any) -> (string, Error) {
	// 用 platform.json_marshal_utf8 而不是 json.marshal：后者遇到非法 UTF-8 会输出 \xNN，
	// 后续解析无法识别这种转义，会把字符串字段解析成空。
	event_json, jerr := platform.json_marshal_utf8(event)
	if jerr != nil {
		return "", make_error(.Internal, "cannot serialize transcript event: %v", jerr)
	}
	defer delete(event_json)

	header_json, herr := platform.json_marshal_utf8(event_header_of(event))
	if herr != nil {
		return "", make_error(.Internal, "cannot serialize transcript event header: %v", herr)
	}
	defer delete(header_json)

	flat, ferr := flatten_event_json(string(header_json), string(event_json))
	if !is_ok(ferr) {
		return "", ferr
	}
	defer delete(flat)

	if !write_all_file(store.file, flat) {
		return "", make_error(.Internal, "cannot write transcript %s", store.path)
	}
	nl: []byte = transmute([]byte)string("\n")
	n2, werr2 := os.write(store.file, nl)
	if werr2 != nil || n2 != 1 {
		return "", make_error(.Internal, "cannot write transcript %s: %v", store.path, werr2)
	}
	if ferr2 := os.flush(store.file); ferr2 != nil {
		return "", make_error(.Internal, "cannot flush transcript %s: %v", store.path, ferr2)
	}
	// 返回的行会进入 Loop.events 并活到 session 结束，必须单独持有一份。
	return strings.clone(string(flat)), ok_error()
}

transcript_append :: proc(store: ^Transcript_Store, event: any) -> Error {
	_, err := transcript_append_line(store, event)
	return err
}

transcript_close :: proc(store: ^Transcript_Store) {
	if store.file != nil {
		os.flush(store.file)
		os.close(store.file)
		store.file = nil
	}
}

// 读取并校验 transcript；最后一行损坏时丢弃，其他位置的损坏视为错误。
transcript_read_all :: proc(project: Project, session_id: string) -> ([]Event, Error) {
	path := platform.session_file(project, session_id)
	data, derr := os.read_entire_file_from_path(path, context.allocator)
	if derr != nil {
		return nil, make_error(.Usage, "cannot read transcript %s: %v", path, derr)
	}

	events := make([dynamic]Event, 0, 16)
	start := 0
	last_nonempty := -1
	lines := make([dynamic]string, 0, 16)
	for i in 0 ..= len(data) {
		if i == len(data) || data[i] == '\n' {
			line := string(data[start:i])
			append(&lines, line)
			if len(strings.trim_space(line)) > 0 {
				last_nonempty = len(lines) - 1
			}
			start = i + 1
		}
	}

	for line, idx in lines {
		if len(strings.trim_space(line)) == 0 {
			continue
		}
		value, perr := json.parse_string(line, .JSON, true)
		if perr != nil {
			if idx == last_nonempty {
				log_warn("transcript %s: ignoring incomplete last line", path)
				break
			}
			return nil, make_error(.Usage, "transcript %s is corrupt at line %d: %v", path, idx + 1, perr)
		}
		// 每行解析出的 JSON 树只在本次循环有效；不释放的话，恢复一个长 session
		// 会为每行永久保留一份解析结果和数据副本。
		defer json.destroy_value(value)

		obj, is_obj := value.(json.Object)
		if !is_obj {
			if idx == last_nonempty {
				log_warn("transcript %s: ignoring incomplete last line", path)
				break
			}
			return nil, make_error(.Usage, "transcript %s is corrupt at line %d: not an object", path, idx + 1)
		}
		typ, typ_ok := obj["type"].(json.String)
		if !typ_ok {
			if idx == last_nonempty {
				log_warn("transcript %s: ignoring incomplete last line", path)
				break
			}
			return nil, make_error(.Usage, "transcript %s is corrupt at line %d: missing type", path, idx + 1)
		}
		type_name := string(typ)
		version := 1
		if v, ok := obj["v"].(json.Integer); ok {
			version = int(v)
		}
		if !event_type_known(type_name) {
			log_debug("transcript %s: skipping unknown event type %q", path, type_name)
			continue
		}
		if version > SCHEMA_VERSION {
			return nil, make_error(
				.Usage,
				"transcript %s uses schema v%d, this ap supports v%d",
				path,
				version,
				SCHEMA_VERSION,
			)
		}
		seq := 0
		if s, ok := obj["seq"].(json.Integer); ok {
			seq = int(s)
		}
		ts := i64(0)
		if t, ok := obj["ts"].(json.Integer); ok {
			ts = i64(t)
		}
		// 只有 line 需要拷贝（它指向 data）；type 统一用静态字面量，
		// 这样调用方永远不需要释放 Event.type。
		append(
			&events,
			Event {
				v = version,
				seq = seq,
				ts = ts,
				type = event_type_canonical(type_name),
				line = strings.clone(line),
			},
		)
	}
	delete(data)
	delete(lines)
	return events[:], ok_error()
}

write_all_file :: proc(file: ^os.File, data: []byte) -> bool {
	return platform.write_all(file, data)
}

blob_read :: proc(project: Project, sha: string, allocator := context.allocator) -> ([]byte, Error) {
	data, err := platform.blob_read(project, sha, allocator)
	return data, from_platform(err, .Usage)
}

blob_write :: proc(project: Project, data: []byte) -> (string, Error) {
	sha, err := platform.blob_write(project, data)
	return sha, from_platform(err, .Tool)
}

blob_write_text :: proc(project: Project, data: []byte) -> (string, Error) {
	path, err := platform.blob_write_text(project, data)
	return path, from_platform(err, .Tool)
}

Blob_Fields :: struct {
	ref:     Maybe(string),
	bytes:   Maybe(int),
	preview: Maybe(string),
}

maybe_blob :: proc(store: ^Transcript_Store, data: []byte) -> (Blob_Fields, Error) {
	threshold := store.settings.blob_threshold_bytes
	if len(data) <= threshold {
		return {}, ok_error()
	}
	sha, berr := blob_write(store.project, data)
	if !is_ok(berr) {
		return {}, berr
	}
	return Blob_Fields {
		ref = sha,
		bytes = len(data),
		preview = platform.utf8_prefix(data, PREVIEW_BYTES),
	}, ok_error()
}

fork_transcript :: proc(
	project: Project,
	source_id, new_id: string,
	settings: ^Settings,
) -> (Transcript_Store, Error) {
	source_path := platform.session_file(project, source_id)
	source, serr := os.read_entire_file_from_path(source_path, context.allocator)
	if serr != nil {
		return {}, make_error(.Usage, "cannot read source transcript %s: %v", source_path, serr)
	}
	// 先完整校验源文件，避免复制损坏的 transcript。
	events, verr := transcript_read_all(project, source_id)
	if !is_ok(verr) {
		return {}, verr
	}
	// 只复制完整事件行；崩溃留下的半行不能进入 fork。
	copy_len := len(source)
	if copy_len > 0 && source[copy_len - 1] != '\n' {
		idx := strings.last_index_byte(string(source), '\n')
		copy_len = 0
		if idx >= 0 {
			copy_len = idx + 1
		}
	}
	source = source[:copy_len]
	store := transcript_store(project, new_id, settings)
	if err := open_transcript(&store, false); !is_ok(err) {
		return {}, err
	}
	if n, werr := os.write(store.file, source); werr != nil || n != len(source) {
		transcript_close(&store)
		return {}, make_error(.Internal, "cannot write forked transcript: %v", werr)
	}
	if ferr := os.flush(store.file); ferr != nil {
		transcript_close(&store)
		return {}, make_error(.Internal, "cannot flush forked transcript: %v", ferr)
	}
	for ev in events {
		if ev.seq + 1 > store.next_seq {
			store.next_seq = ev.seq + 1
		}
	}
	return store, ok_error()
}

last_session_start :: proc(events: []Event) -> (Session_Start_Event, bool) {
	for i := len(events) - 1; i >= 0; i -= 1 {
		if events[i].type != EVENT_SESSION_START {
			continue
		}
		ev: Session_Start_Event
		if json.unmarshal_string(events[i].line, &ev) == nil {
			return ev, true
		}
	}
	return {}, false
}

session_start_content :: proc(project: Project, ev: Session_Start_Event) -> (string, Error) {
	return session_start_content_in(project, ev, context.allocator)
}

session_start_content_in :: proc(
	project: Project,
	ev: Session_Start_Event,
	allocator: runtime.Allocator,
) -> (string, Error) {
	if ref, ok := ev.content_ref.?; ok {
		data, berr := blob_read(project, ref, allocator)
		if !is_ok(berr) {
			return "", berr
		}
		return string(data), ok_error()
	}
	return ev.content, ok_error()
}

session_system_prompt :: proc(project: Project, events: []Event) -> (Session_Start_Event, string, Error) {
	return session_system_prompt_in(project, events, context.allocator)
}

session_system_prompt_in :: proc(
	project: Project,
	events: []Event,
	allocator: runtime.Allocator,
) -> (Session_Start_Event, string, Error) {
	start, found := last_session_start(events)
	if !found {
		return {}, "", make_error(.Usage, "transcript has no session_start event")
	}
	content, cerr := session_start_content_in(project, start, allocator)
	if !is_ok(cerr) {
		return start, "", cerr
	}
	return start, content, ok_error()
}

find_latest_root_session :: proc(project: Project) -> (string, Error) {
	id, err := platform.find_latest_root_session(project)
	return id, from_platform(err, .Usage)
}
