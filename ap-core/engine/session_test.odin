package engine

import "../platform"
import "core:fmt"
import "core:testing"

@(test)
test_resolve_fork_without_explicit_source_uses_latest_root :: proc(t: ^testing.T) {
	dir := test_temp_dir("fork-latest")
	defer test_cleanup(dir)
	root := fmt.tprintf("%s/work", dir)
	config_dir := fmt.tprintf("%s/config", dir)
	project, perr := platform.open_project(config_dir, root)
	testing.expect(t, platform.is_ok(perr))

	line := `{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_root","content":"sys","cwd":"/x","model":"m","provider":"p","agent_name":"general","agent_depth":0,"parent_session_id":null}`
	test_write_file(platform.session_file(project, "ses_root"), fmt.tprintf("%s\n", line))

	settings := settings_defaults()
	req := Session_Request {
		kind      = .Fork,
		project   = project,
		settings  = &settings,
		config_dir = config_dir,
		cwd       = project.root,
	}
	resolved, err := resolve_session(req)
	testing.expect(t, is_ok(err))
	testing.expect_value(t, resolved.source_id, "ses_root")
	testing.expect_value(t, resolved.agent_name, "general")
}
