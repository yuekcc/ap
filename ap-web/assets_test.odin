package apweb

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

web_test_temp_dir :: proc(prefix: string) -> string {
	base := os.get_env("TEMP", context.allocator)
	if len(base) == 0 {
		base = os.get_env("TMPDIR", context.allocator)
	}
	if len(base) == 0 {
		base = "."
	}
	dir := fmt.aprintf("%s/ap-web-test-%s-%d", base, prefix, time.time_to_unix_nano(time.now()))
	os.make_directory_all(dir)
	return dir
}

web_test_write_file :: proc(path, content: string) {
	dir, _ := os.split_path(path)
	if len(dir) > 0 {
		os.make_directory_all(dir)
	}
	if err := os.write_entire_file_from_bytes(path, transmute([]byte)content); err != nil {
		panic("failed to write test file")
	}
}

@(test)
test_assets_embedded_lookup :: proc(t: ^testing.T) {
	assets, err := make_assets("")
	testing.expect_value(t, err, "")
	testing.expect(t, len(assets.embedded) > 0)

	index := lookup_asset(&assets, "/")
	testing.expect_value(t, index.status, 200)
	testing.expect_value(t, index.content_type, "text/html; charset=utf-8")
	testing.expect(t, len(index.data) > 0)
	testing.expect(t, strings.contains(string(index.data), "ap-web"))
	testing.expect(t, len(index.etag) > 0)

	same := lookup_asset(&assets, "/index.html")
	testing.expect_value(t, same.status, 200)
	testing.expect_value(t, same.etag, index.etag)

	missing := lookup_asset(&assets, "/nope.js")
	testing.expect_value(t, missing.status, 404)
}

@(test)
test_assets_embedded_traversal_forbidden :: proc(t: ^testing.T) {
	assets, _ := make_assets("")
	result := lookup_asset(&assets, "/../secret.txt")
	testing.expect_value(t, result.status, 403)
}

@(test)
test_assets_etag_depends_on_content :: proc(t: ^testing.T) {
	dir := web_test_temp_dir("etag")
	defer os.remove_all(dir)

	web_test_write_file(fmt.aprintf("%s/index.html", dir), "hello")
	assets, err := make_assets(dir)
	testing.expect_value(t, err, "")

	first := lookup_asset(&assets, "/index.html")
	testing.expect_value(t, first.status, 200)
	second := lookup_asset(&assets, "/index.html")
	testing.expect_value(t, second.etag, first.etag)

	web_test_write_file(fmt.aprintf("%s/index.html", dir), "hello again")
	third := lookup_asset(&assets, "/index.html")
	testing.expect(t, third.etag != first.etag)
}

@(test)
test_assets_disk_lookup :: proc(t: ^testing.T) {
	dir := web_test_temp_dir("disk")
	defer os.remove_all(dir)

	web_test_write_file(fmt.aprintf("%s/index.html", dir), "<h1>hi</h1>")
	web_test_write_file(fmt.aprintf("%s/app.js", dir), "console.log(1)")
	web_test_write_file(fmt.aprintf("%s/sub/page.html", dir), "sub")

	assets, err := make_assets(dir)
	testing.expect_value(t, err, "")

	index := lookup_asset(&assets, "/")
	testing.expect_value(t, index.status, 200)
	testing.expect_value(t, string(index.data), "<h1>hi</h1>")
	testing.expect_value(t, index.content_type, "text/html; charset=utf-8")

	js := lookup_asset(&assets, "/app.js")
	testing.expect_value(t, js.status, 200)
	testing.expect_value(t, js.content_type, "text/javascript; charset=utf-8")

	sub := lookup_asset(&assets, "/sub/page.html")
	testing.expect_value(t, sub.status, 200)
	testing.expect_value(t, string(sub.data), "sub")

	dir_index := lookup_asset(&assets, "/sub/")
	testing.expect_value(t, dir_index.status, 404)

	missing := lookup_asset(&assets, "/missing.css")
	testing.expect_value(t, missing.status, 404)
}

@(test)
test_assets_disk_traversal_forbidden :: proc(t: ^testing.T) {
	parent := web_test_temp_dir("traversal")
	defer os.remove_all(parent)
	root := fmt.aprintf("%s/site", parent)
	web_test_write_file(fmt.aprintf("%s/index.html", root), "site")
	web_test_write_file(fmt.aprintf("%s/secret.txt", parent), "secret")

	assets, err := make_assets(root)
	testing.expect_value(t, err, "")

	plain := lookup_asset(&assets, "/../secret.txt")
	testing.expect_value(t, plain.status, 403)

	backslash := lookup_asset(&assets, "/..\\secret.txt")
	testing.expect_value(t, backslash.status, 403)

	// server 解析时先 percent-decode，assets 不再二次解码。
	parsed := test_parse("GET /%2e%2e/secret.txt HTTP/1.1\r\n\r\n")
	testing.expect_value(t, parsed.state, Parse_State.Complete)
	encoded := lookup_asset(&assets, parsed.request.path)
	testing.expect_value(t, encoded.status, 403)
}

@(test)
test_assets_disk_rejects_oversize :: proc(t: ^testing.T) {
	dir := web_test_temp_dir("big")
	defer os.remove_all(dir)

	path := fmt.aprintf("%s/big.bin", dir)
	os.make_directory_all(dir)
	big := make([]byte, MAX_ASSET_BYTES + 1, context.temp_allocator)
	if err := os.write_entire_file_from_bytes(path, big); err != nil {
		panic("failed to write oversize test file")
	}

	assets, err := make_assets(dir)
	testing.expect_value(t, err, "")
	result := lookup_asset(&assets, "/big.bin")
	testing.expect_value(t, result.status, 413)
}

@(test)
test_assets_rejects_missing_root :: proc(t: ^testing.T) {
	_, err := make_assets("C:/definitely/not/here/ap-web-test")
	testing.expect(t, len(err) > 0)
}
