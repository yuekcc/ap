package platform

import "core:strings"
import "core:testing"

blob_test_project :: proc(t: ^testing.T, name: string) -> (Project, string) {
	dir := test_temp_dir(name)
	config_dir, cerr := canonicalize_path(dir, false)
	testing.expect(t, is_ok(cerr))
	project, perr := open_project(config_dir, dir)
	testing.expect(t, is_ok(perr))
	return project, dir
}

@(test)
test_blob_roundtrip_and_dedup :: proc(t: ^testing.T) {
	project, dir := blob_test_project(t, "blob")
	defer test_cleanup(dir)

	data: []byte = transmute([]byte)string("hello blob")
	sha, werr := blob_write(project, data)
	testing.expect(t, is_ok(werr))
	testing.expect_value(t, len(sha), 64)
	testing.expect_value(t, sha, sha256_hex(data))

	sha2, werr2 := blob_write(project, data)
	testing.expect(t, is_ok(werr2))
	testing.expect_value(t, sha2, sha)

	read, rerr := blob_read(project, sha)
	testing.expect(t, is_ok(rerr))
	testing.expect_value(t, string(read), "hello blob")
	delete(read)
}

@(test)
test_blob_missing_and_corrupt :: proc(t: ^testing.T) {
	project, dir := blob_test_project(t, "blob-corrupt")
	defer test_cleanup(dir)

	missing := strings.repeat("0", 64)
	_, merr := blob_read(project, missing)
	testing.expect(t, !is_ok(merr))
	testing.expect(t, strings.contains(merr.message, "missing"))

	data: []byte = transmute([]byte)string("payload")
	sha, werr := blob_write(project, data)
	testing.expect(t, is_ok(werr))
	test_write_file(blob_file(project, sha), "tampered")

	_, cerr := blob_read(project, sha)
	testing.expect(t, !is_ok(cerr))
	testing.expect(t, strings.contains(cerr.message, "corrupt"))
}
