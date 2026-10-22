package ap

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:testing"

test_project_and_settings :: proc(t: ^testing.T, name: string) -> (Project, Settings, string) {
	dir := test_temp_dir(name)
	root := fmt.tprintf("%s/work", dir)
	os.make_directory_all(root)
	project, perr := open_project(fmt.tprintf("%s/config", dir), root)
	testing.expect_value(t, perr.code, Exit_Code.OK)
	settings := settings_defaults()
	settings.blob_threshold_bytes = 100
	return project, settings, dir
}

@(test)
test_transcript_append_read_roundtrip :: proc(t: ^testing.T) {
	project, settings, dir := test_project_and_settings(t, "transcript")
	defer test_cleanup(dir)

	store, serr := new_transcript_store(project, "sess-1", &settings)
	testing.expect_value(t, serr.code, Exit_Code.OK)

	start := Session_Start_Event {
		header = make_header(&store, "session_start"),
		session_id = "sess-1",
		content = "system",
		role = "system",
		cwd = project.root,
		model = "m",
		provider = PROVIDER_NAME,
		agent_name = "general",
		agent_depth = 0,
		parent_session_id = nil,
		parent_tool_call_id = nil,
		resumed_from = nil,
	}
	testing.expect_value(t, transcript_append(&store, start).code, Exit_Code.OK)
	user := User_Message_Event {
		header = make_header(&store, "user_message"),
		content = "hi",
	}
	testing.expect_value(t, transcript_append(&store, user).code, Exit_Code.OK)
	turn_start := Turn_Start_Event {
		header = make_header(&store, "turn_start"),
		turn = 1,
	}
	testing.expect_value(t, transcript_append(&store, turn_start).code, Exit_Code.OK)
	transcript_close(&store)

	events, rerr := transcript_read_all(project, "sess-1")
	testing.expect_value(t, rerr.code, Exit_Code.OK)
	testing.expect_value(t, len(events), 3)
	testing.expect_value(t, events[0].type, "session_start")
	testing.expect_value(t, events[0].seq, 0)
	testing.expect_value(t, events[1].type, "user_message")
	testing.expect_value(t, events[2].type, "turn_start")

	parsed: Session_Start_Event
	uerr := json.unmarshal_string(events[0].line, &parsed)
	testing.expect_value(t, uerr, nil)
	testing.expect_value(t, parsed.session_id, "sess-1")
	testing.expect_value(t, parsed.content, "system")
	testing.expect_value(t, events[0].v, 1)
	testing.expect_value(t, events[0].type, "session_start")
}

@(test)
test_transcript_ignores_partial_last_line :: proc(t: ^testing.T) {
	project, settings, dir := test_project_and_settings(t, "partial")
	defer test_cleanup(dir)
	store, serr := new_transcript_store(project, "sess-partial", &settings)
	testing.expect_value(t, serr.code, Exit_Code.OK)
	start := Session_Start_Event {
		header = make_header(&store, "session_start"),
		session_id = "sess-partial",
		content = "x",
		role = "system",
		model = "m",
		provider = PROVIDER_NAME,
		agent_name = "general",
	}
	testing.expect_value(t, transcript_append(&store, start).code, Exit_Code.OK)
	transcript_close(&store)

	file, _ := os.open(store.path, {.Write, .Append})
	partial: []byte = transmute([]byte)string(`{"v":1,"type":`)
	os.write(file, partial)
	os.close(file)

	events, rerr := transcript_read_all(project, "sess-partial")
	testing.expect_value(t, rerr.code, Exit_Code.OK)
	testing.expect_value(t, len(events), 1)
}

@(test)
test_transcript_skips_unknown_and_rejects_future_version :: proc(t: ^testing.T) {
	project, settings, dir := test_project_and_settings(t, "unknown")
	defer test_cleanup(dir)
	store, serr := new_transcript_store(project, "sess-unknown", &settings)
	testing.expect_value(t, serr.code, Exit_Code.OK)
	start := Session_Start_Event {
		header = make_header(&store, "session_start"),
		session_id = "sess-unknown",
		content = "x",
		role = "system",
		model = "m",
		agent_name = "general",
	}
	transcript_append(&store, start)
	transcript_close(&store)

	test_write_file(
		store.path,
		fmt.tprintf("%s%s\n", test_read_file(store.path), `{"v":1,"seq":9,"ts":1,"type":"future_event","x":1}`),
	)
	events, rerr := transcript_read_all(project, "sess-unknown")
	testing.expect_value(t, rerr.code, Exit_Code.OK)
	testing.expect_value(t, len(events), 1)

	test_write_file(
		store.path,
		fmt.tprintf("%s%s\n", test_read_file(store.path), `{"v":2,"seq":10,"ts":1,"type":"session_end","reason":"exit"}`),
	)
	_, rerr2 := transcript_read_all(project, "sess-unknown")
	testing.expect_value(t, rerr2.code, Exit_Code.Usage)
}

@(test)
test_blob_roundtrip_and_dedup :: proc(t: ^testing.T) {
	project, _, dir := test_project_and_settings(t, "blob")
	defer test_cleanup(dir)
	data: []byte = transmute([]byte)string("hello blob\n")
	sha, err := blob_write(project, data)
	testing.expect_value(t, err.code, Exit_Code.OK)
	testing.expect_value(t, len(sha), 64)
	sha2, err2 := blob_write(project, data)
	testing.expect_value(t, err2.code, Exit_Code.OK)
	testing.expect_value(t, sha, sha2)

	got, rerr := blob_read(project, sha)
	testing.expect_value(t, rerr.code, Exit_Code.OK)
	testing.expect_value(t, string(got), "hello blob\n")
	testing.expect(t, os.exists(blob_file(project, sha)))
}

@(test)
test_blob_missing_and_corrupt :: proc(t: ^testing.T) {
	project, _, dir := test_project_and_settings(t, "blob-bad")
	defer test_cleanup(dir)
	missing := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	_, rerr := blob_read(project, missing)
	testing.expect_value(t, rerr.code, Exit_Code.Usage)

	data: []byte = transmute([]byte)string("payload")
	sha, _ := blob_write(project, data)
	test_write_file(blob_file(project, sha), "tampered")
	_, rerr2 := blob_read(project, sha)
	testing.expect_value(t, rerr2.code, Exit_Code.Usage)

	_, rerr3 := blob_read(project, "../../etc/passwd")
	testing.expect_value(t, rerr3.code, Exit_Code.Usage)
}

@(test)
test_maybe_blob_threshold :: proc(t: ^testing.T) {
	project, settings, dir := test_project_and_settings(t, "maybe-blob")
	defer test_cleanup(dir)
	store, _ := new_transcript_store(project, "sess-blob", &settings)
	defer transcript_close(&store)

	small: []byte = transmute([]byte)string("small")
	fields, err := maybe_blob(&store, small)
	testing.expect_value(t, err.code, Exit_Code.OK)
	_, has_ref := fields.ref.?
	testing.expect(t, !has_ref)

	big_data := make([]byte, 200)
	for i in 0 ..< len(big_data) {
		big_data[i] = 'a'
	}
	fields2, err2 := maybe_blob(&store, big_data)
	testing.expect_value(t, err2.code, Exit_Code.OK)
	sha, has_ref2 := fields2.ref.?
	testing.expect(t, has_ref2)
	testing.expect_value(t, len(sha), 64)
	got, _ := blob_read(project, sha)
	testing.expect_value(t, len(got), 200)
}

@(test)
test_resume_repairs_partial_last_line :: proc(t: ^testing.T) {
	project, settings, dir := test_project_and_settings(t, "resume-partial")
	defer test_cleanup(dir)
	store, _ := new_transcript_store(project, "resume-partial", &settings)
	start := Session_Start_Event {
		header = make_header(&store, "session_start"),
		session_id = "resume-partial",
		content = "sys",
		role = "system",
		cwd = project.root,
		model = "m",
		provider = PROVIDER_NAME,
		agent_name = "general",
	}
	transcript_append(&store, start)
	transcript_close(&store)
	file, _ := os.open(store.path, {.Write, .Append})
	partial: []byte = transmute([]byte)string(`{"v":1,"type":"user_mess`)
	os.write(file, partial)
	os.close(file)

	resumed, rerr := resume_transcript_store(project, "resume-partial", &settings)
	testing.expect_value(t, rerr.code, Exit_Code.OK)
	defer transcript_close(&resumed)
	user := User_Message_Event{header = make_header(&resumed, "user_message"), content = "next"}
	testing.expect_value(t, transcript_append(&resumed, user).code, Exit_Code.OK)
	transcript_close(&resumed)

	events, rerr2 := transcript_read_all(project, "resume-partial")
	testing.expect_value(t, rerr2.code, Exit_Code.OK)
	testing.expect_value(t, len(events), 2)
	testing.expect_value(t, events[1].type, "user_message")
}

@(test)
test_fork_transcript_copies_events :: proc(t: ^testing.T) {
	project, settings, dir := test_project_and_settings(t, "fork")
	defer test_cleanup(dir)
	store, _ := new_transcript_store(project, "source", &settings)
	start := Session_Start_Event {
		header = make_header(&store, "session_start"),
		session_id = "source",
		content = "sys",
		role = "system",
		cwd = project.root,
		model = "m",
		provider = PROVIDER_NAME,
		agent_name = "general",
	}
	transcript_append(&store, start)
	user := User_Message_Event {
		header = make_header(&store, "user_message"),
		content = "hello",
	}
	transcript_append(&store, user)
	transcript_close(&store)

	forked, ferr := fork_transcript(project, "source", "forked", &settings)
	testing.expect_value(t, ferr.code, Exit_Code.OK)
	testing.expect_value(t, forked.next_seq, 2)
	new_start := Session_Start_Event {
		header = make_header(&forked, "session_start"),
		session_id = "forked",
		content = "sys",
		role = "system",
		cwd = project.root,
		model = "m",
		provider = PROVIDER_NAME,
		agent_name = "general",
		resumed_from = "source",
	}
	testing.expect_value(t, transcript_append(&forked, new_start).code, Exit_Code.OK)
	transcript_close(&forked)

	events, _ := transcript_read_all(project, "forked")
	testing.expect_value(t, len(events), 3)
	testing.expect_value(t, events[2].seq, 2)
	parsed: Session_Start_Event
	json.unmarshal_string(events[2].line, &parsed)
	testing.expect_value(t, parsed.session_id, "forked")
	testing.expect_value(t, parsed.resumed_from.?, "source")
}

@(test)
test_transcript_invalid_utf8_content_is_not_dropped :: proc(t: ^testing.T) {
	project, settings, dir := test_project_and_settings(t, "transcript-invalid-utf8")
	defer test_cleanup(dir)

	store, serr := new_transcript_store(project, "sess-bad", &settings)
	testing.expect_value(t, serr.code, Exit_Code.OK)
	// 模拟 Windows 本地代码页（GBK）传进来的提示词：字节不是合法 UTF-8。
	gbk := transmute(string)([]byte{0xd6, 0xd0, 0xce, 0xc4})
	ev := User_Message_Event {
		header = make_header(&store, "user_message"),
		content = gbk,
	}
	testing.expect_value(t, transcript_append(&store, ev).code, Exit_Code.OK)
	transcript_close(&store)

	events, rerr := transcript_read_all(project, "sess-bad")
	testing.expect_value(t, rerr.code, Exit_Code.OK)
	testing.expect_value(t, len(events), 1)
	parsed: User_Message_Event
	testing.expect_value(t, json.unmarshal_string(events[0].line, &parsed), nil)
	testing.expect(t, len(parsed.content) > 0)
}
