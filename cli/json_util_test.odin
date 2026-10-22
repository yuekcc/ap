package ap

import "core:encoding/json"
import "core:testing"

@(test)
test_json_marshal_utf8_preserves_unicode :: proc(t: ^testing.T) {
	data, err := json_marshal_utf8(json.String("你好，世界 \" \\ \n"))
	testing.expect_value(t, err, nil)
	text := string(data)
	testing.expect(t, test_contains(text, "你好，世界"))
	testing.expect(t, !test_contains(text, `\u4f60`))
	testing.expect(t, test_contains(text, `\"`))
	testing.expect(t, test_contains(text, `\\`))
	testing.expect(t, test_contains(text, `\n`))

	value, perr := json.parse_string(text, .JSON, true)
	testing.expect_value(t, perr, nil)
	testing.expect_value(t, string(value.(json.String)), "你好，世界 \" \\ \n")
}

@(test)
test_json_unescape_unicode_handles_surrogates_and_invalid_bytes :: proc(t: ^testing.T) {
	raw: []byte = transmute([]byte)string(
		`{"emoji":"\ud83d\ude00","quote":"\"","newline":"\n","lone":"\ud800","bad":"\xff","slash":"\/"}`,
	)
	out := string(json_unescape_unicode(raw))
	testing.expect(t, test_contains(out, "😀"))
	testing.expect(t, test_contains(out, `\"`))
	testing.expect(t, test_contains(out, `\n`))
	testing.expect(t, test_contains(out, `\ufffd`))
	testing.expect(t, test_contains(out, `\u00ff`))
	testing.expect(t, !test_contains(out, `\ud83d`))
	testing.expect(t, test_contains(out, "/"))

	value, perr := json.parse_string(out, .JSON, true)
	testing.expect_value(t, perr, nil)
	obj := value.(json.Object)
	testing.expect_value(t, string(obj["emoji"].(json.String)), "😀")

	invalid_raw := []byte{'"', 0xff, '"'}
	invalid_out := string(json_unescape_unicode(invalid_raw))
	testing.expect_value(t, invalid_out, `"\ufffd"`)
}

@(test)
test_transcript_writes_unicode_without_escaping :: proc(t: ^testing.T) {
	project, settings, dir := test_project_and_settings(t, "json-unicode")
	defer test_cleanup(dir)
	store, _ := new_transcript_store(project, "unicode", &settings)
	ev := User_Message_Event {
		header = make_header(&store, "user_message"),
		content = "中文内容",
	}
	testing.expect_value(t, transcript_append(&store, ev).code, Exit_Code.OK)
	transcript_close(&store)

	raw := test_read_file(store.path)
	testing.expect(t, test_contains(raw, "中文内容"))
	testing.expect(t, !test_contains(raw, `\u4e2d`))
	events, rerr := transcript_read_all(project, "unicode")
	testing.expect_value(t, rerr.code, Exit_Code.OK)
	testing.expect_value(t, len(events), 1)
	parsed: User_Message_Event
	testing.expect_value(t, json.unmarshal_string(events[0].line, &parsed), nil)
	testing.expect_value(t, parsed.content, "中文内容")
}
