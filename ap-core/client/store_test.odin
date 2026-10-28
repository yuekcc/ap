package client

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_fnv32a_known_value :: proc(t: ^testing.T) {
	testing.expect_value(t, fnv32a_hex(transmute([]byte)string("hello")), "4f9f2cab")
}

@(test)
test_locate_project_uses_root_hash :: proc(t: ^testing.T) {
	dir := test_temp_dir("project")
	defer os.remove_all(dir)

	config_dir, config_err := canonicalize_path(dir, false)
	testing.expect_value(t, config_err.message, "")
	project, err := locate_project(config_dir, dir)
	testing.expect_value(t, err.message, "")
	expected_root, root_err := canonicalize_path(dir, true)
	testing.expect_value(t, root_err.message, "")
	testing.expect_value(t, project.root, expected_root)
	testing.expect_value(t, len(project.hash), 8)
	testing.expect_value(t, project.hash, fnv32a_hex(transmute([]byte)project.root))
	testing.expect_value(t, project.dir, fmt.aprintf("%s/projects/%s", config_dir, project.hash))
	testing.expect_value(t, project.blobs_dir, strings.concatenate({project.dir, "/blobs"}))

	// 末尾斜杠不影响 project 身份。
	project2, err2 := locate_project(config_dir, strings.concatenate({dir, "/"}))
	testing.expect_value(t, err2.message, "")
	testing.expect_value(t, project2.hash, project.hash)
}

@(test)
test_store_forwards_sessions_and_blobs :: proc(t: ^testing.T) {
	dir := test_temp_dir("sessions")
	defer os.remove_all(dir)

	project := Project {
		config_dir = dir,
		root       = dir,
		hash       = "test",
		dir        = dir,
		blobs_dir  = fmt.aprintf("%s/blobs", dir),
	}
	os.make_directory_all(project.blobs_dir)

	transcript :=
		"{\"v\":1,\"seq\":0,\"ts\":1,\"type\":\"session_start\",\"session_id\":\"ses_1\",\"parent_session_id\":null}\n" +
		"{\"v\":1,\"seq\":1,\"ts\":2,\"type\":\"user_message\",\"content\":\"hi\"}\n"
	test_write_file(session_file(project, "ses_1"), transcript)

	ids, ids_err := session_ids(project)
	defer {
		for id in ids {
			delete(id)
		}
		delete(ids)
	}
	testing.expect_value(t, ids_err.message, "")
	testing.expect_value(t, len(ids), 1)
	testing.expect_value(t, ids[0], "ses_1")

	data, read_err := read_transcript(project, "ses_1")
	defer delete(data)
	testing.expect_value(t, read_err.message, "")
	testing.expect_value(t, string(data), transcript)

	test_write_file(
		blob_file(project, "559600820d9e6926bb88d9a39b1be2c31c01682580b6a7eaf50c53611d74493d"),
		"blob text\n",
	)
	blob, blob_err := blob_read(project, "559600820d9e6926bb88d9a39b1be2c31c01682580b6a7eaf50c53611d74493d")
	defer delete(blob)
	testing.expect_value(t, blob_err.message, "")
	testing.expect_value(t, string(blob), "blob text\n")

	_, missing_err := blob_read(project, "0000000000000000000000000000000000000000000000000000000000000000")
	testing.expect(t, !is_ok(missing_err))
}

@(test)
test_list_projects_reads_path_txt :: proc(t: ^testing.T) {
	dir := test_temp_dir("list-projects")
	defer os.remove_all(dir)

	config_dir, config_err := canonicalize_path(dir, false)
	testing.expect_value(t, config_err.message, "")
	project, err := locate_project(config_dir, dir)
	testing.expect_value(t, err.message, "")

	// client 只读：手工摆出 ap 写下的 path.txt。
	os.make_directory_all(project.dir)
	test_write_file(fmt.tprintf("%s/path.txt", project.dir), strings.concatenate({project.root, "\n"}))
	// path.txt 与目录名对不上的条目应被忽略。
	os.make_directory_all(fmt.tprintf("%s/projects/bogus", config_dir))
	test_write_file(fmt.tprintf("%s/projects/bogus/path.txt", config_dir), strings.concatenate({project.root, "\n"}))

	projects, list_err := list_projects(config_dir)
	testing.expect_value(t, list_err.message, "")
	testing.expect_value(t, len(projects), 1)
	testing.expect_value(t, projects[0].hash, project.hash)
}
