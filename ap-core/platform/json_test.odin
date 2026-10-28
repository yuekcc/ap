package platform

import "core:encoding/json"
import "core:strings"
import "core:testing"

@(test)
test_json_marshal_utf8_preserves_unicode :: proc(t: ^testing.T) {
	data, err := json_marshal_utf8(json.String("你好，世界 \" \\ \n"))
	testing.expect_value(t, err, nil)
	text := string(data)
	testing.expect(t, strings.contains(text, "你好，世界"))
	testing.expect(t, !strings.contains(text, `\u4f60`))
	testing.expect(t, strings.contains(text, `\"`))
	testing.expect(t, strings.contains(text, `\`))
	testing.expect(t, strings.contains(text, `\n`))

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
	testing.expect(t, strings.contains(out, "😀"))
	testing.expect(t, strings.contains(out, `\"`))
	testing.expect(t, strings.contains(out, `\n`))
	testing.expect(t, strings.contains(out, `\ufffd`))
	testing.expect(t, strings.contains(out, `\u00ff`))
	testing.expect(t, !strings.contains(out, `\ud83d`))
	testing.expect(t, strings.contains(out, "/"))

	value, perr := json.parse_string(out, .JSON, true)
	testing.expect_value(t, perr, nil)
	obj := value.(json.Object)
	testing.expect_value(t, string(obj["emoji"].(json.String)), "😀")

	invalid_raw := []byte{'"', 0xff, '"'}
	invalid_out := string(json_unescape_unicode(invalid_raw))
	testing.expect_value(t, invalid_out, `"\ufffd"`)
}

@(test)
test_json_canonical_string_sorts_keys :: proc(t: ^testing.T) {
	value, perr := json.parse_string(`{"z":1,"a":[3,{"y":true,"b":null}],"m":"x"}`, .JSON, true)
	testing.expect_value(t, perr, nil)
	testing.expect_value(t, json_canonical_string(value), `{"a":[3,{"b":null,"y":true}],"m":"x","z":1}`)
}
