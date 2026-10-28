package apweb

import "core:testing"

@(test)
test_mime_by_extension :: proc(t: ^testing.T) {
	testing.expect_value(t, mime_type_for("index.html"), "text/html; charset=utf-8")
	testing.expect_value(t, mime_type_for("app.js"), "text/javascript; charset=utf-8")
	testing.expect_value(t, mime_type_for("styles.css"), "text/css; charset=utf-8")
	testing.expect_value(t, mime_type_for("logo.svg"), "image/svg+xml")
	testing.expect_value(t, mime_type_for("a.PNG"), "image/png")
	testing.expect_value(t, mime_type_for("favicon.ico"), "image/x-icon")
	testing.expect_value(t, mime_type_for("mod.wasm"), "application/wasm")
	testing.expect_value(t, mime_type_for("data.json"), "application/json; charset=utf-8")
	testing.expect_value(t, mime_type_for("README"), "application/octet-stream")
	testing.expect_value(t, mime_type_for("dir/index.html"), "text/html; charset=utf-8")
}

@(test)
test_percent_decode :: proc(t: ^testing.T) {
	decoded, ok := percent_decode("/a%20b")
	testing.expect(t, ok)
	testing.expect_value(t, decoded, "/a b")

	slash, ok2 := percent_decode("/a%2Fb")
	testing.expect(t, ok2)
	testing.expect_value(t, slash, "/a/b")

	plus, ok3 := percent_decode("/a+b")
	testing.expect(t, ok3)
	testing.expect_value(t, plus, "/a+b")

	utf8, ok4 := percent_decode("/%E4%BD%A0")
	testing.expect(t, ok4)
	testing.expect_value(t, utf8, "/你")

	_, bad1 := percent_decode("/%zz")
	testing.expect(t, !bad1)
	_, bad2 := percent_decode("/%4")
	testing.expect(t, !bad2)
}

@(test)
test_split_target :: proc(t: ^testing.T) {
	path, query := split_target("/api/history?session=ses_1&x=2")
	testing.expect_value(t, path, "/api/history")
	testing.expect_value(t, query, "session=ses_1&x=2")

	path2, query2 := split_target("/index.html")
	testing.expect_value(t, path2, "/index.html")
	testing.expect_value(t, query2, "")

	path3, query3 := split_target("/?a=b")
	testing.expect_value(t, path3, "/")
	testing.expect_value(t, query3, "a=b")
}

@(test)
test_status_text :: proc(t: ^testing.T) {
	testing.expect_value(t, status_text(200), "OK")
	testing.expect_value(t, status_text(304), "Not Modified")
	testing.expect_value(t, status_text(400), "Bad Request")
	testing.expect_value(t, status_text(403), "Forbidden")
	testing.expect_value(t, status_text(404), "Not Found")
	testing.expect_value(t, status_text(405), "Method Not Allowed")
	testing.expect_value(t, status_text(413), "Payload Too Large")
}

@(test)
test_header_lookup :: proc(t: ^testing.T) {
	headers := []Http_Header {
		{"Host", "127.0.0.1:8417"},
		{"Content-Length", "12"},
		{"Connection", "keep-alive, Upgrade"},
		{"If-None-Match", `"abc", W/"def"`},
	}
	value, ok := header_value(headers, "host")
	testing.expect(t, ok)
	testing.expect_value(t, value, "127.0.0.1:8417")

	value2, ok2 := header_value(headers, "CONTENT-LENGTH")
	testing.expect(t, ok2)
	testing.expect_value(t, value2, "12")

	_, missing := header_value(headers, "Accept")
	testing.expect(t, !missing)

	testing.expect(t, header_has_token(headers, "connection", "upgrade"))
	testing.expect(t, !header_has_token(headers, "connection", "close"))
}

@(test)
test_etag_matches :: proc(t: ^testing.T) {
	testing.expect(t, etag_matches(`"abc"`, `"abc"`))
	testing.expect(t, etag_matches(`W/"abc"`, `"abc"`))
	testing.expect(t, etag_matches(`"x", "abc"`, `"abc"`))
	testing.expect(t, etag_matches(`*`, `"abc"`))
	testing.expect(t, !etag_matches(`"x"`, `"abc"`))
	testing.expect(t, !etag_matches(``, `"abc"`))
}
