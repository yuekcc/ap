package platform

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_project_hash_uses_canonical_root :: proc(t: ^testing.T) {
	dir := test_temp_dir("hash")
	defer test_cleanup(dir)

	config_dir, cerr := canonicalize_path(dir, false)
	testing.expect(t, is_ok(cerr))
	project, perr := open_project(config_dir, dir)
	testing.expect(t, is_ok(perr))
	testing.expect_value(t, project.hash, fnv32a_hex(transmute([]byte)project.root))
	testing.expect(t, os.is_dir(project.blobs_dir))

	path_file := strings.concatenate({project.dir, "/path.txt"})
	testing.expect_value(t, strings.trim_space(test_read_file(path_file)), project.root)
}

@(test)
test_project_path_conflict_is_reported :: proc(t: ^testing.T) {
	dir := test_temp_dir("conflict")
	other := test_temp_dir("conflict-other")
	defer test_cleanup(dir)
	defer test_cleanup(other)

	config_dir, cerr := canonicalize_path(dir, false)
	testing.expect(t, is_ok(cerr))
	project, perr := open_project(config_dir, dir)
	testing.expect(t, is_ok(perr))

	other_root, oerr := canonicalize_path(other, true)
	testing.expect(t, is_ok(oerr))
	test_write_file(strings.concatenate({project.dir, "/path.txt"}), strings.concatenate({other_root, "\n"}))

	_, conflict := open_project(config_dir, dir)
	testing.expect(t, !is_ok(conflict))
	testing.expect(t, strings.contains(conflict.message, "project path conflict"))
}
