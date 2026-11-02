package apcli

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

prompt_test_write :: proc(path, content: string) {
	dir, _ := os.split_path(path)
	if len(dir) > 0 {
		os.make_directory_all(dir)
	}
	if err := os.write_entire_file_from_bytes(path, transmute([]byte)content); err != nil {
		panic("cannot write test file")
	}
}

@(test)
test_prompt_sections_default_order :: proc(t: ^testing.T) {
	dir := cli_temp_dir(t, "prompt-order")
	defer os.remove_all(dir)
	root := fmt.tprintf("%s/repo", dir)
	home := fmt.tprintf("%s/home", dir)
	sub := fmt.tprintf("%s/sub", root)
	os.make_directory_all(sub)
	os.make_directory_all(fmt.tprintf("%s/.git", root))
	prompt_test_write(fmt.tprintf("%s/.agents/AGENTS.md", home), "GLOBAL_MEMORY\n")
	prompt_test_write(fmt.tprintf("%s/AGENTS.md", root), "ROOT_MEMORY\n")
	prompt_test_write(fmt.tprintf("%s/AGENTS.md", sub), "SUB_MEMORY\n")

	agent := agent_default_general()
	agent.body = "AGENT_BODY"
	sections := build_prompt_sections(
		{
			cwd = sub,
			home_dir = home,
			agent = agent,
			append_prompt = "APPEND_MARKER",
			skill_section = "SKILL_SECTION",
			include_memory = true,
		},
	)
	testing.expect(t, len(sections) >= 7)
	testing.expect(t, strings.has_prefix(sections[0], "## 环境\n"))
	testing.expect(t, strings.contains(sections[0], "- 当前时间: "))
	testing.expect(t, strings.contains(sections[0], "- git 仓库: 是"))
	testing.expect_value(t, sections[1], "## 可用技能\n\nSKILL_SECTION\n")
	testing.expect(t, strings.has_prefix(sections[2], "## 全局记忆 (AGENTS.md)\n"))
	testing.expect(t, strings.contains(sections[2], "GLOBAL_MEMORY"))
	testing.expect(t, strings.has_prefix(sections[3], "## 项目记忆 ("))
	testing.expect(t, strings.contains(sections[3], "ROOT_MEMORY"))
	testing.expect(t, strings.contains(sections[4], "SUB_MEMORY"))
	testing.expect_value(t, sections[5], "## Agent 定义 (general)\nAGENT_BODY\n")
	testing.expect_value(t, sections[6], "## 追加指令\nAPPEND_MARKER\n")
}

@(test)
test_prompt_sections_switches :: proc(t: ^testing.T) {
	dir := cli_temp_dir(t, "prompt-switches")
	defer os.remove_all(dir)
	root := fmt.tprintf("%s/plain", dir)
	home := fmt.tprintf("%s/home", dir)
	os.make_directory_all(root)
	prompt_test_write(fmt.tprintf("%s/.agents/AGENTS.md", home), "GLOBAL_MEMORY\n")
	prompt_test_write(fmt.tprintf("%s/AGENTS.md", root), "PROJECT_MEMORY\n")

	sections := build_prompt_sections(
		{
			cwd = root,
			home_dir = home,
			agent = agent_default_general(),
			skill_section = "",
			include_memory = false,
		},
	)
	testing.expect_value(t, len(sections), 1)
	testing.expect(t, strings.contains(sections[0], "- git 仓库: 否"))
	testing.expect(t, !strings.contains(strings.join(sections, ""), "记忆"))
}
