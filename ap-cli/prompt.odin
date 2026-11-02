package apcli

import platform "../ap-core/platform"

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// system prompt 的应用层段落。SDK 只固定 base 与工具段；这里决定其余顺序与内容。
// 默认顺序：环境 → 技能 → 全局记忆 → 项目记忆 → agent 正文 → 用户追加。

Prompt_Options :: struct {
	cwd:           string,
	home_dir:      string,
	agent:         Agent_Def,
	append_prompt: string,
	skill_section: string,
	include_memory: bool,
}

build_prompt_sections :: proc(opts: Prompt_Options) -> []string {
	sections := make([dynamic]string, 0, 8)

	env := strings.builder_make()
	strings.write_string(&env, "## 环境\n")
	fmt.sbprintf(&env, "- OS: %v\n", ODIN_OS)
	fmt.sbprintf(&env, "- cwd: %s\n", opts.cwd)
	fmt.sbprintf(&env, "- 当前时间: %v\n", time.now())
	fmt.sbprintf(&env, "- git 仓库: %s\n", "是" if find_git_root(opts.cwd) != "" else "否")
	append(&sections, strings.to_string(env))

	if len(opts.skill_section) > 0 {
		append(&sections, fmt.tprintf("## 可用技能\n\n%s\n", opts.skill_section))
	}

	if opts.include_memory && len(opts.home_dir) > 0 {
		global_memory := fmt.tprintf("%s/.agents/AGENTS.md", opts.home_dir)
		if os.exists(global_memory) {
			if data, err := os.read_entire_file_from_path(global_memory, context.allocator); err == nil {
				append(&sections, fmt.tprintf("## 全局记忆 (AGENTS.md)\n%s\n", string(data)))
			}
		}
	}

	if opts.include_memory {
		for file in project_memory_files(opts.cwd) {
			if data, err := os.read_entire_file_from_path(file, context.allocator); err == nil {
				append(&sections, fmt.tprintf("## 项目记忆 (%s)\n%s\n", file, string(data)))
			}
		}
	}

	if len(opts.agent.body) > 0 {
		append(&sections, fmt.tprintf("## Agent 定义 (%s)\n%s\n", opts.agent.name, opts.agent.body))
	}

	if len(opts.append_prompt) > 0 {
		append(&sections, fmt.tprintf("## 追加指令\n%s\n", opts.append_prompt))
	}

	return sections[:]
}

find_git_root :: proc(start: string) -> string {
	dir := start
	for len(dir) > 0 {
		git_path, _ := os.join_path([]string{dir, ".git"}, context.allocator)
		if os.exists(git_path) {
			return dir
		}
		parent := os.dir(dir)
		if parent == dir || len(parent) == 0 {
			break
		}
		dir = parent
	}
	return ""
}

project_memory_files :: proc(cwd: string) -> []string {
	git_root := find_git_root(cwd)
	dirs := make([dynamic]string, 0, 8)
	dir := cwd
	for len(dir) > 0 {
		append(&dirs, dir)
		if len(git_root) > 0 && dir == git_root {
			break
		}
		parent := os.dir(dir)
		if parent == dir || len(parent) == 0 {
			break
		}
		dir = parent
	}

	// 近 → 远收集，再反转为远 → 近。
	files := make([dynamic]string, 0, len(dirs))
	for memory_dir in dirs {
		base := os.base(memory_dir)
		if strings.has_prefix(base, ".") {
			continue
		}
		path, _ := os.join_path([]string{memory_dir, "AGENTS.md"}, context.allocator)
		if os.exists(path) && os.is_file(path) {
			canonical, cerr := platform.canonicalize_path(path, true)
			if !platform.is_ok(cerr) {
				canonical = path
			}
			append(&files, canonical)
		}
	}
	// 去重（符号链接可能让不同祖先落到同一物理文件）；保留更近的文件。
	seen := make(map[string]bool, len(files))
	unique := make([dynamic]string, 0, len(files))
	for path in files {
		if path in seen {
			continue
		}
		seen[path] = true
		append(&unique, path)
	}
	ordered := make([dynamic]string, 0, len(unique))
	for i := len(unique) - 1; i >= 0; i -= 1 {
		append(&ordered, unique[i])
	}
	return ordered[:]
}
