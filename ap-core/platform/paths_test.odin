package platform

import "core:fmt"
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

@(test)
test_path_normalization_hash_stable :: proc(t: ^testing.T) {
	dir := test_temp_dir("hash-stable")
	defer test_cleanup(dir)
	a, err := canonicalize_path(dir, true)
	testing.expect(t, is_ok(err))

	with_slash := fmt.tprintf("%s/", a)
	b, err2 := canonicalize_path(with_slash, true)
	testing.expect(t, is_ok(err2))
	testing.expect_value(t, a, b)

	when ODIN_OS == .Windows {
		upper, _ := strings.to_upper(a)
		c, err3 := canonicalize_path(upper, true)
		testing.expect(t, is_ok(err3))
		testing.expect_value(t, a, c)
	}
}

@(test)
test_path_relative_and_home :: proc(t: ^testing.T) {
	dir := test_temp_dir("resolve")
	defer test_cleanup(dir)
	os.make_directory_all(fmt.tprintf("%s/sub", dir))
	joined, err := resolve_tool_path(dir, "sub/../a.txt")
	testing.expect(t, is_ok(err))
	expect := fmt.tprintf("%s/a.txt", strings.trim_right(dir, `\/`))
	testing.expect_value(t, joined, normalize_slashes(expect))

	when ODIN_OS == .Windows {
		_, msys_err := resolve_tool_path(dir, "/z/projects/example")
		testing.expect(t, !is_ok(msys_err))
	}

	home, herr := os.user_home_dir(context.allocator)
	testing.expect_value(t, herr, nil)
	expanded, err2 := expand_home("~/x")
	testing.expect(t, is_ok(err2))
	home_slashed := normalize_slashes(home)
	testing.expect_value(t, expanded, fmt.tprintf("%s/x", strings.trim_right(home_slashed, `\/`)))
}

@(test)
test_project_hash_ignores_separators_and_uppercase :: proc(t: ^testing.T) {
	dir := test_temp_dir("project-sep")
	defer test_cleanup(dir)
	config := fmt.tprintf("%s/config", dir)
	root := fmt.tprintf("%s/work", dir)
	os.make_directory_all(root)

	p1, err := open_project(config, root)
	testing.expect(t, is_ok(err))
	backslashed, _ := strings.replace_all(root, "/", `\`)
	p2, err2 := open_project(config, backslashed)
	testing.expect(t, is_ok(err2))
	testing.expect_value(t, p1.hash, p2.hash)

	when ODIN_OS == .Windows {
		upper, _ := strings.to_upper(root)
		p3, err3 := open_project(config, upper)
		testing.expect(t, is_ok(err3))
		testing.expect_value(t, p1.hash, p3.hash)
	}

	testing.expect(t, os.exists(fmt.tprintf("%s/path.txt", p1.dir)))
}
