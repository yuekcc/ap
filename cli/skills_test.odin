package ap

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

make_skill_dir :: proc(base, dir_name, front_name, description, body: string) -> string {
	dir := fmt.tprintf("%s/%s", base, dir_name)
	content := fmt.tprintf("---\nname: %s\ndescription: %s\n---\n%s\n", front_name, description, body)
	test_write_file(fmt.tprintf("%s/%s", dir, SKILL_FILE), content)
	return dir
}

@(test)
test_load_skill_parses_frontmatter :: proc(t: ^testing.T) {
	dir := test_temp_dir("skill-parse")
	defer test_cleanup(dir)

	skill_dir := make_skill_dir(dir, "alpha", `"alpha"`, "does alpha things", "Step 1\nStep 2")
	skill, ok := load_skill(skill_dir)
	testing.expect(t, ok)
	testing.expect_value(t, skill.name, "alpha")
	testing.expect_value(t, skill.description, "does alpha things")
	testing.expect_value(t, skill.content, "Step 1\nStep 2")
	testing.expect(t, strings.has_suffix(skill.location, SKILL_FILE))
}

@(test)
test_load_skill_unescapes_quoted_values :: proc(t: ^testing.T) {
	dir := test_temp_dir("skill-unescape")
	defer test_cleanup(dir)

	skill_dir := fmt.tprintf("%s/quoted", dir)
	test_write_file(
		fmt.tprintf("%s/%s", skill_dir, SKILL_FILE),
		"---\nname: quoted\ndescription: \"say \\\"hi\\\" and C:\\\\path\"\n---\nbody\n",
	)
	skill, ok := load_skill(skill_dir)
	testing.expect(t, ok)
	testing.expect_value(t, skill.description, `say "hi" and C:\path`)
}

@(test)
test_load_skill_disable_model_invocation :: proc(t: ^testing.T) {
	dir := test_temp_dir("skill-disable")
	defer test_cleanup(dir)

	disabled_dir := fmt.tprintf("%s/disabled", dir)
	test_write_file(
		fmt.tprintf("%s/%s", disabled_dir, SKILL_FILE),
		"---\nname: manual\ndescription: manual only\ndisable-model-invocation: true\n---\nbody\n",
	)
	disabled, ok := load_skill(disabled_dir)
	testing.expect(t, ok)
	testing.expect(t, disabled.disable_model_invocation)

	quoted_dir := fmt.tprintf("%s/quoted", dir)
	test_write_file(
		fmt.tprintf("%s/%s", quoted_dir, SKILL_FILE),
		"---\nname: quoted\ndescription: quoted flag\ndisable-model-invocation: \"TRUE\"\n---\nbody\n",
	)
	quoted, ok2 := load_skill(quoted_dir)
	testing.expect(t, ok2)
	testing.expect(t, quoted.disable_model_invocation)

	enabled_dir := fmt.tprintf("%s/enabled", dir)
	test_write_file(
		fmt.tprintf("%s/%s", enabled_dir, SKILL_FILE),
		"---\nname: enabled\ndescription: enabled flag\ndisable-model-invocation: false\n---\nbody\n",
	)
	enabled, ok3 := load_skill(enabled_dir)
	testing.expect(t, ok3)
	testing.expect(t, !enabled.disable_model_invocation)
}

@(test)
test_load_skill_requires_name_description_and_content :: proc(t: ^testing.T) {
	dir := test_temp_dir("skill-invalid")
	defer test_cleanup(dir)

	missing_description := fmt.tprintf("%s/missing-desc", dir)
	test_write_file(
		fmt.tprintf("%s/%s", missing_description, SKILL_FILE),
		"---\nname: x\n---\nbody\n",
	)
	_, ok := load_skill(missing_description)
	testing.expect(t, !ok)

	empty_body := fmt.tprintf("%s/empty-body", dir)
	test_write_file(
		fmt.tprintf("%s/%s", empty_body, SKILL_FILE),
		"---\nname: x\ndescription: y\n---\n\n",
	)
	_, ok2 := load_skill(empty_body)
	testing.expect(t, !ok2)

	missing_close := fmt.tprintf("%s/missing-close", dir)
	test_write_file(
		fmt.tprintf("%s/%s", missing_close, SKILL_FILE),
		"---\nname: x\ndescription: y\nbody\n",
	)
	_, ok3 := load_skill(missing_close)
	testing.expect(t, !ok3)

	no_frontmatter := fmt.tprintf("%s/no-frontmatter", dir)
	test_write_file(fmt.tprintf("%s/%s", no_frontmatter, SKILL_FILE), "just a body\n")
	_, ok4 := load_skill(no_frontmatter)
	testing.expect(t, !ok4)
}

@(test)
test_load_skill_handles_bom_and_crlf :: proc(t: ^testing.T) {
	dir := test_temp_dir("skill-bom")
	defer test_cleanup(dir)

	skill_dir := fmt.tprintf("%s/crlf", dir)
	test_write_file(
		fmt.tprintf("%s/%s", skill_dir, SKILL_FILE),
		"\xEF\xBB\xBF---\r\nname: crlf\r\ndescription: windows line endings\r\n---\r\nline one\r\nline two\r\n",
	)
	skill, ok := load_skill(skill_dir)
	testing.expect(t, ok)
	testing.expect_value(t, skill.name, "crlf")
	testing.expect_value(t, skill.content, "line one\nline two")
}

@(test)
test_load_skill_dirs_overrides_and_sorts :: proc(t: ^testing.T) {
	dir := test_temp_dir("skill-dirs")
	defer test_cleanup(dir)

	global := make_skill_dir(dir, "global/dup", "dup", "global version", "global body")
	project := make_skill_dir(dir, "project/dup", "dup", "project version", "project body")
	bravo := make_skill_dir(dir, "project/bravo", "bravo", "b", "body")

	skills := load_skill_dirs([]string{global, bravo, project})
	testing.expect_value(t, len(skills), 2)
	testing.expect_value(t, skills[0].name, "bravo")
	testing.expect_value(t, skills[1].name, "dup")
	testing.expect_value(t, skills[1].description, "project version")
	testing.expect_value(t, skills[1].content, "project body")
}

@(test)
test_discover_skills_from_roots :: proc(t: ^testing.T) {
	dir := test_temp_dir("skill-discover")
	defer test_cleanup(dir)

	home := fmt.tprintf("%s/home", dir)
	cwd := fmt.tprintf("%s/work", dir)
	os.make_directory_all(home)
	os.make_directory_all(cwd)

	global_skills := fmt.tprintf("%s/%s/%s", home, SKILLS_ASSETS_DIR, SKILLS_SUBDIR)
	project_skills := fmt.tprintf("%s/%s/%s", cwd, SKILLS_ASSETS_DIR, SKILLS_SUBDIR)
	make_skill_dir(global_skills, "alpha", "alpha", "global alpha", "global")
	make_skill_dir(global_skills, "delta", "delta", "global delta", "global")
	make_skill_dir(project_skills, "alpha", "alpha", "project alpha", "project")
	make_skill_dir(project_skills, "beta", "beta", "project beta", "project")

	skills := discover_skills_from(home, cwd)
	testing.expect_value(t, len(skills), 3)
	testing.expect_value(t, skills[0].name, "alpha")
	testing.expect_value(t, skills[0].description, "project alpha")
	testing.expect_value(t, skills[1].name, "beta")
	testing.expect_value(t, skills[2].name, "delta")

	none := discover_skills_from(fmt.tprintf("%s/nohome", dir), fmt.tprintf("%s/nocwd", dir))
	testing.expect_value(t, len(none), 0)
}

@(test)
test_skills_prompt_block :: proc(t: ^testing.T) {
	testing.expect_value(t, skills_prompt_block(nil), "")

	skills := []Skill {
		{name = "alpha", description = "a <b> & c", location = "C:/skills/alpha/SKILL.md"},
		{name = "bravo", description = "plain", location = `C:\skills\bravo\SKILL.md`},
	}
	block := skills_prompt_block(skills)
	testing.expect(t, test_contains(block, "<available_skills>"))
	testing.expect(t, test_contains(block, "<name>alpha</name>"))
	testing.expect(t, test_contains(block, "a &lt;b&gt; &amp; c"))
	testing.expect(t, test_contains(block, "<location>C:/skills/bravo/SKILL.md</location>"))
	testing.expect(t, test_contains(block, "read_file"))
}

@(test)
test_skills_prompt_block_skips_disabled :: proc(t: ^testing.T) {
	skills := []Skill {
		{name = "auto", description = "available", location = "C:/skills/auto/SKILL.md"},
		{name = "manual", description = "manual only", location = "C:/skills/manual/SKILL.md", disable_model_invocation = true},
	}
	block := skills_prompt_block(skills)
	testing.expect(t, test_contains(block, "<name>auto</name>"))
	testing.expect(t, !test_contains(block, "manual"))

	all_disabled := []Skill {
		{name = "manual", description = "manual only", location = "C:/skills/manual/SKILL.md", disable_model_invocation = true},
	}
	testing.expect_value(t, skills_prompt_block(all_disabled), "")
}

@(test)
test_skills_brief :: proc(t: ^testing.T) {
	testing.expect_value(t, skills_brief(nil), "No skill found\n")

	skills := []Skill {
		{name = "alpha", description = "does alpha"},
		{name = "bravo", description = "does bravo", disable_model_invocation = true},
	}
	testing.expect_value(t, skills_brief(skills), "1. alpha: does alpha\n2. bravo: does bravo\n")
}

@(test)
test_system_prompt_includes_skill_section :: proc(t: ^testing.T) {
	dir := test_temp_dir("skill-prompt")
	defer test_cleanup(dir)

	config := fmt.tprintf("%s/config", dir)
	root := fmt.tprintf("%s/work", dir)
	os.make_directory_all(config)
	os.make_directory_all(root)
	test_write_file(fmt.tprintf("%s/AGENTS.md", config), "GLOBAL_MEMORY")

	prompt := build_system_prompt(
		{
			cwd = root,
			config_dir = config,
			agent = agent_default_general(),
			tool_section = "TOOL_SECTION",
			skill_section = "SKILL_SECTION",
			append_prompt = "APPEND_SECTION",
		},
	)
	testing.expect(t, test_contains(prompt, "## 可用技能"))
	testing.expect(t, test_contains(prompt, "SKILL_SECTION"))

	skill_pos := strings.index(prompt, "SKILL_SECTION")
	memory_pos := strings.index(prompt, "GLOBAL_MEMORY")
	append_pos := strings.index(prompt, "APPEND_SECTION")
	testing.expect(t, skill_pos < memory_pos)
	testing.expect(t, memory_pos < append_pos)
}
