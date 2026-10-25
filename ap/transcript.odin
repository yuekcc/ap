package ap

import "../internal"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

PREVIEW_BYTES :: 8192

Usage :: internal.Usage

usage_add :: proc(a, b: Usage) -> Usage {
	out := Usage{}
	add_field :: proc(x, y: Maybe(int)) -> Maybe(int) {
		xv, xok := x.?
		yv, yok := y.?
		if !xok && !yok {
			return nil
		}
		sum := 0
		if xok {
			sum += xv
		}
		if yok {
			sum += yv
		}
		return sum
	}
	out.input_tokens = add_field(a.input_tokens, b.input_tokens)
	out.output_tokens = add_field(a.output_tokens, b.output_tokens)
	out.cached_tokens = add_field(a.cached_tokens, b.cached_tokens)
	out.reasoning_tokens = add_field(a.reasoning_tokens, b.reasoning_tokens)
	out.total_tokens = add_field(a.total_tokens, b.total_tokens)
	return out
}

Event_Header :: internal.Event_Header

Session_Start_Event :: struct {
	using header: Event_Header,
	session_id:          string,
	content:             string,
	role:                string,
	cwd:                 string,
	model:               string,
	provider:            string,
	agent_name:          string,
	agent_depth:         int,
	parent_session_id:   Maybe(string),
	parent_tool_call_id: Maybe(string),
	resumed_from:        Maybe(string),
	content_ref:         Maybe(string) `json:"content_ref,omitempty"`,
	content_bytes:       Maybe(int) `json:"content_bytes,omitempty"`,
}

Session_End_Event :: struct {
	using header: Event_Header,
	reason: string,
	usage:  Usage,
}

User_Message_Event :: struct {
	using header: Event_Header,
	content: string,
}

Turn_Start_Event :: struct {
	using header: Event_Header,
	turn: int,
}

Turn_End_Event :: struct {
	using header: Event_Header,
	turn:        int,
	stop_reason: string,
	usage:       Usage,
}

Step_Start_Event :: struct {
	using header: Event_Header,
	step: int,
}

Message_Start_Event :: struct {
	using header: Event_Header,
	message_id: string,
	role:       string,
	model:      string,
}

Content_Block :: struct {
	type:         string,
	text:         Maybe(string) `json:"text,omitempty"`,
	text_ref:     Maybe(string) `json:"text_ref,omitempty"`,
	text_bytes:   Maybe(int)    `json:"text_bytes,omitempty"`,
	text_preview: Maybe(string) `json:"text_preview,omitempty"`,
	id:           Maybe(string) `json:"id,omitempty"`,
	name:         Maybe(string) `json:"name,omitempty"`,
	input:        json.Value    `json:"input,omitempty"`,
	input_ref:    Maybe(string) `json:"input_ref,omitempty"`,
	input_bytes:  Maybe(int)    `json:"input_bytes,omitempty"`,
	input_preview: Maybe(string) `json:"input_preview,omitempty"`,
}

Message_End_Event :: struct {
	using header: Event_Header,
	message_id: string,
	role:       string,
	content:    []Content_Block,
	stop_reason: string,
	usage:      Maybe(Usage),
	reasoning:  Maybe(string) `json:"reasoning"`,
}

Tool_Execution_Start_Event :: struct {
	using header: Event_Header,
	tool_call_id: string,
	name:         string,
	args:         json.Value  `json:"args,omitempty"`,
	args_ref:     Maybe(string) `json:"args_ref,omitempty"`,
	args_bytes:   Maybe(int)    `json:"args_bytes,omitempty"`,
	args_preview: Maybe(string) `json:"args_preview,omitempty"`,
}

Tool_Execution_End_Event :: struct {
	using header: Event_Header,
	tool_call_id:    string,
	ok:              bool,
	content:         Maybe(string) `json:"content"`,
	content_ref:     Maybe(string) `json:"content_ref,omitempty"`,
	content_bytes:   Maybe(int)    `json:"content_bytes,omitempty"`,
	content_preview: Maybe(string) `json:"content_preview,omitempty"`,
	error:           Maybe(string) `json:"error"`,
	duration_ms:     Maybe(int)    `json:"duration_ms"`,
	exit_code:       Maybe(int)    `json:"exit_code"`,
	metadata:        json.Value    `json:"metadata"`,
}

Error_Event :: struct {
	using header: Event_Header,
	scope:     string,
	kind:      Maybe(string) `json:"kind"`,
	message:   string,
	retryable: bool,
	attempt:   int,
}

Cancel_Event :: struct {
	using header: Event_Header,
	scope:     string,
	target_id: Maybe(string) `json:"target_id"`,
}

Event :: struct {
	v:    int,
	seq:  int,
	ts:   i64,
	type: string,
	line: string,
}

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

event_type_known :: proc(typ: string) -> bool {
	switch typ {
	case "session_start",
	     "session_end",
	     "user_message",
	     "turn_start",
	     "turn_end",
	     "step_start",
	     "message_start",
	     "message_end",
	     "tool_execution_start",
	     "tool_execution_end",
	     "error",
	     "cancel":
		return true
	}
	return false
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
		path       = session_file(project, session_id),
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

transcript_append_line :: proc(store: ^Transcript_Store, event: any) -> (string, Error) {
	// 用 json_marshal_utf8 而不是 json.marshal：后者遇到非法 UTF-8 会输出 \xNN，
	// 下面的 parse_string 无法识别这种转义，会把字符串字段解析成空。
	data, jerr := json_marshal_utf8(event)
	if jerr != nil {
		return "", make_error(.Internal, "cannot serialize transcript event: %v", jerr)
	}
	// json 包不会展开 using 嵌入字段；把 header 对象合并回顶层，保证事件 schema 平坦。
	value, perr := json.parse_string(string(data), .JSON, true)
	if perr != nil {
		return "", make_error(.Internal, "cannot normalize transcript event: %v", perr)
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return "", make_error(.Internal, "transcript event is not an object")
	}
	if header_value, has_header := obj["header"]; has_header {
		if header, header_is_obj := header_value.(json.Object); header_is_obj {
			for key, field in header {
				obj[key] = field
			}
			delete_key(&obj, "header")
		}
	}
	normalized, merr := json_marshal_utf8(obj)
	if merr != nil {
		return "", make_error(.Internal, "cannot serialize transcript event: %v", merr)
	}
	if !write_all_file(store.file, normalized) {
		return "", make_error(.Internal, "cannot write transcript %s", store.path)
	}
	nl: []byte = transmute([]byte)string("\n")
	n2, werr2 := os.write(store.file, nl)
	if werr2 != nil || n2 != 1 {
		return "", make_error(.Internal, "cannot write transcript %s: %v", store.path, werr2)
	}
	if ferr := os.flush(store.file); ferr != nil {
		return "", make_error(.Internal, "cannot flush transcript %s: %v", store.path, ferr)
	}
	return string(normalized), ok_error()
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
	path := session_file(project, session_id)
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
		version := 1
		if v, ok := obj["v"].(json.Integer); ok {
			version = int(v)
		}
		if !event_type_known(string(typ)) {
			log_debug("transcript %s: skipping unknown event type %q", path, string(typ))
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
		append(&events, Event{v = version, seq = seq, ts = ts, type = string(typ), line = strings.clone(line)})
	}
	return events[:], ok_error()
}

blob_read :: proc(project: Project, sha: string) -> ([]byte, Error) {
	data, err := internal.blob_read(project, sha)
	return data, internal_error_to_ap(err)
}

blob_write :: proc(project: Project, data: []byte) -> (string, Error) {
	sha := sha256_hex(data)
	path := blob_file(project, sha)
	if os.exists(path) {
		return sha, ok_error()
	}
	if err := blob_write_at(project, path, data); !is_ok(err) {
		return "", err
	}
	return sha, ok_error()
}

// 把完整工具输出写成模型可直接用 read_file 读取的 .txt 文件。
// 返回绝对路径；文件名使用内容 sha256，重复输出自动去重。
blob_write_text :: proc(project: Project, data: []byte) -> (string, Error) {
	sha := sha256_hex(data)
	path := fmt.tprintf("%s/%s.txt", project.blobs_dir, sha)
	if os.exists(path) {
		return path, ok_error()
	}
	if err := blob_write_at(project, path, data); !is_ok(err) {
		return "", err
	}
	return path, ok_error()
}

blob_write_at :: proc(project: Project, path: string, data: []byte) -> Error {
	tmp := fmt.tprintf("%s/.tmp-%d-%d", project.blobs_dir, os.get_pid(), time.time_to_unix_nano(time.now()))
	perm := os.Permissions{.Read_User, .Write_User}
	file, ferr := os.open(tmp, {.Write, .Create, .Excl, .Trunc}, perm)
	if ferr != nil {
		return make_error(.Tool, "failed to persist output blob: cannot create %s: %v", tmp, ferr)
	}
	ok_write := write_all_file(file, data)
	sync_err := os.sync(file)
	close_err := os.close(file)
	if !ok_write || sync_err != nil || close_err != nil {
		os.remove(tmp)
		return make_error(.Tool, "failed to persist output blob: write error")
	}
	if rerr := os.rename(tmp, path); rerr != nil {
		os.remove(tmp)
		return make_error(.Tool, "failed to persist output blob: rename failed: %v", rerr)
	}
	return ok_error()
}

write_all_file :: proc(file: ^os.File, data: []byte) -> bool {
	return internal.write_all(file, data)
}

utf8_prefix :: proc(data: []byte, max_bytes: int) -> string {
	if len(data) <= max_bytes {
		return string(data)
	}
	cut := max_bytes
	for cut > 0 && !utf8.valid_string(string(data[:cut])) {
		// 只截断可能不完整的多字节序列，最多回退 3 字节。
		if max_bytes - cut >= 3 {
			break
		}
		cut -= 1
	}
	return string(data[:cut])
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
		preview = utf8_prefix(data, PREVIEW_BYTES),
	}, ok_error()
}

fork_transcript :: proc(
	project: Project,
	source_id, new_id: string,
	settings: ^Settings,
) -> (Transcript_Store, Error) {
	source_path := session_file(project, source_id)
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
		if events[i].type != "session_start" {
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
	if ref, ok := ev.content_ref.?; ok {
		data, berr := blob_read(project, ref)
		if !is_ok(berr) {
			return "", berr
		}
		return string(data), ok_error()
	}
	return ev.content, ok_error()
}

session_system_prompt :: proc(project: Project, events: []Event) -> (Session_Start_Event, string, Error) {
	start, found := last_session_start(events)
	if !found {
		return {}, "", make_error(.Usage, "transcript has no session_start event")
	}
	content, cerr := session_start_content(project, start)
	if !is_ok(cerr) {
		return start, "", cerr
	}
	return start, content, ok_error()
}

find_latest_root_session :: proc(project: Project) -> (string, Error) {
	id, err := internal.find_latest_root_session(project)
	return id, internal_error_to_ap(err)
}
