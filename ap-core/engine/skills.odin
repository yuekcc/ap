package engine

import "../platform"

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// ---- 分节 ----
// 技能（skill）的发现、解析与提示词片段组装。
//
// 技能即一个目录：目录里放 SKILL.md，front matter 给出 name/description，正文是技能内容。
// 从两处发现：全局 `~/.agents/skills/<name>/`，项目 `<启动目录>/.agents/skills/<name>/`；
// 同名时项目级覆盖全局级。
//
// 本模块产出两样东西：
//   - skills_prompt_block()：拼进 system prompt 的 `<available_skills>` 块；
//   - skills_brief()：`--list-skills` 的人读简表。
//
// skill 不是工具：正文不直接注入，模型按提示用 read_file / bash 读取后再执行。

// ---- 常量 ----

SKILL_FILE :: "SKILL.md"
SKILLS_SUBDIR :: "skills"
SKILLS_ASSETS_DIR :: ".agents"

// 拼进 system prompt 的开场说明：何时读、怎么读、相对路径怎么解析。
SKILL_PROMPT_INTRO :: `若 <available_skills> 里有明显适用于当前任务的 skill，先用 read_file 读取其 <location> 指向的 SKILL.md（文件过大或需要定位片段时用 bash），再照其中步骤执行。
若多个都沾边，选最贴切的那个；若都不贴切，一个都不要读。
skill 中引用相对路径时，以该 SKILL.md 所在目录为基准解析成绝对路径再使用。`

// ---- 类型 ----

Skill :: struct {
	name:                     string,
	description:              string,
	content:                  string,
	location:                 string,
	disable_model_invocation: bool,
}

// ---- 装配入口 ----

// 从默认两处（~/.agents/skills、<cwd>/.agents/skills）发现并加载。
discover_skills :: proc(cwd: string) -> []Skill {
	home, herr := os.user_home_dir(context.allocator)
	if herr != nil {
		home = ""
	}
	return discover_skills_from(home, cwd)
}

// 显式指定全局根与项目根；拆出来供单元测试使用。
discover_skills_from :: proc(home, cwd: string) -> []Skill {
	dirs := make([dynamic]string, 0, 8)
	defer delete(dirs)

	if len(home) > 0 {
		home_norm := platform.trim_trailing_slashes(platform.normalize_slashes(home, context.allocator))
		collect_skill_dirs(&dirs, fmt.tprintf("%s/%s/%s", home_norm, SKILLS_ASSETS_DIR, SKILLS_SUBDIR))
	}
	if len(cwd) > 0 {
		cwd_norm := platform.trim_trailing_slashes(platform.normalize_slashes(cwd, context.allocator))
		collect_skill_dirs(&dirs, fmt.tprintf("%s/%s/%s", cwd_norm, SKILLS_ASSETS_DIR, SKILLS_SUBDIR))
	}

	return load_skill_dirs(dirs[:])
}

// 从显式目录列表加载（discover_skills 与单元测试共用）。
// 同名去重，后加载者覆盖先加载者；结果按 name 升序。
load_skill_dirs :: proc(dirs: []string) -> []Skill {
	skills := make([dynamic]Skill, 0, 8)
	index_by_name := make(map[string]int, 8)
	defer delete(index_by_name)

	for dir in dirs {
		skill, ok := load_skill(dir)
		if !ok {
			continue
		}
		if at, exists := index_by_name[skill.name]; exists {
			skills[at] = skill
			continue
		}
		index_by_name[skill.name] = len(skills)
		append(&skills, skill)
	}

	slice.sort_by(skills[:], proc(a, b: Skill) -> bool {
		return a.name < b.name
	})
	return skills[:]
}

// ---- 列表组装 ----

// system prompt 注入块：无可用 skill 时返回空串（不留任何噪音）。
// disable-model-invocation 的技能只在 --list-skills 中展示，不进入提示词。
skills_prompt_block :: proc(skills: []Skill) -> string {
	b := strings.builder_make()
	wrote_any := false
	for skill in skills {
		if skill.disable_model_invocation {
			continue
		}
		if !wrote_any {
			strings.write_string(&b, SKILL_PROMPT_INTRO)
			strings.write_string(&b, "\n\n<available_skills>\n")
			wrote_any = true
		}
		strings.write_string(&b, "  <skill>\n")
		fmt.sbprintf(&b, "    <name>%s</name>\n", escape_xml(skill.name))
		fmt.sbprintf(&b, "    <description>%s</description>\n", escape_xml(skill.description))
		fmt.sbprintf(&b, "    <location>%s</location>\n", escape_xml(platform.normalize_slashes(skill.location)))
		strings.write_string(&b, "  </skill>\n")
	}
	if !wrote_any {
		return ""
	}
	strings.write_string(&b, "</available_skills>")
	return strings.to_string(b)
}

// 简表：每行 `<序号>. <name>: <description>`，供 --list-skills 打印。
skills_brief :: proc(skills: []Skill) -> string {
	if len(skills) == 0 {
		return "No skill found\n"
	}
	b := strings.builder_make()
	for skill, i in skills {
		fmt.sbprintf(&b, "%d. %s: %s\n", i + 1, skill.name, skill.description)
	}
	return strings.to_string(b)
}

// ---- 目录发现 ----

collect_skill_dirs :: proc(dirs: ^[dynamic]string, skills_home: string) {
	if !os.is_dir(skills_home) {
		return
	}
	entries, derr := os.read_directory_by_path(skills_home, -1, context.allocator)
	if derr != nil {
		log_debug("cannot list skills directory %s: %v", skills_home, derr)
		return
	}
	defer os.file_info_slice_delete(entries, context.allocator)

	for entry in entries {
		if entry.type != .Directory {
			continue
		}
		append(dirs, fmt.tprintf("%s/%s", skills_home, entry.name))
	}
}

// ---- 单个 skill 解析 ----

// 读 <dir>/SKILL.md：首行 `---` 开始 front matter，下一行 `---` 结束；
// 只取 name / description，之后是正文。三者齐全才算有效 skill。
load_skill :: proc(dir: string) -> (skill: Skill, ok: bool) {
	path := fmt.tprintf("%s/%s", dir, SKILL_FILE)
	if !os.is_file(path) {
		return {}, false
	}
	data, derr := os.read_entire_file_from_path(path, context.allocator)
	if derr != nil || !platform.valid_utf8(data) {
		return {}, false
	}

	text := string(data)
	if strings.has_prefix(text, "\xEF\xBB\xBF") {
		text = text[3:]
	}
	lines := platform.split_lines(text)
	if len(lines) == 0 || strings.trim_space(lines[0]) != "---" {
		return {}, false
	}

	close_index := -1
	for i in 1 ..< len(lines) {
		if strings.trim_space(lines[i]) == "---" {
			close_index = i
			break
		}
	}
	if close_index < 0 {
		return {}, false
	}

	for i in 1 ..< close_index {
		line := strings.trim_space(lines[i])
		if len(line) == 0 || strings.has_prefix(line, "#") {
			continue
		}
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			continue
		}
		key := strings.trim_space(line[:colon])
		value := front_value(line[colon + 1:])
		switch key {
		case "name":
			if len(skill.name) == 0 {
				skill.name = value
			}
		case "description":
			if len(skill.description) == 0 {
				skill.description = value
			}
		case "disable-model-invocation":
			skill.disable_model_invocation = front_bool(value)
		}
	}

	body := strings.builder_make()
	for i in close_index + 1 ..< len(lines) {
		strings.write_string(&body, lines[i])
		strings.write_byte(&body, '\n')
	}

	skill.location = path
	skill.content = strings.trim_space(strings.to_string(body))
	return skill, len(skill.name) > 0 && len(skill.description) > 0 && len(skill.content) > 0
}

// front matter 值：去掉包裹的引号；双引号内的常见转义还原。
front_value :: proc(value: string) -> string {
	trimmed := strings.trim_space(value)
	if len(trimmed) >= 2 {
		if trimmed[0] == '"' && trimmed[len(trimmed) - 1] == '"' {
			return unescape_double_quoted(trimmed[1 : len(trimmed) - 1])
		}
		if trimmed[0] == '\'' && trimmed[len(trimmed) - 1] == '\'' {
			return trimmed[1 : len(trimmed) - 1]
		}
	}
	return trimmed
}

// 仅识别 true（不区分大小写）；其它值一律视为 false。
front_bool :: proc(value: string) -> bool {
	return strings.equal_fold(strings.trim_space(value), "true")
}

unescape_double_quoted :: proc(value: string) -> string {
	if !strings.contains_rune(value, '\\') {
		return value
	}
	b := strings.builder_make()
	for i := 0; i < len(value); i += 1 {
		if value[i] != '\\' || i + 1 >= len(value) {
			strings.write_byte(&b, value[i])
			continue
		}
		next := value[i + 1]
		switch next {
		case '\\':
			strings.write_byte(&b, '\\')
		case '"':
			strings.write_byte(&b, '"')
		case 'n':
			strings.write_byte(&b, '\n')
		case 't':
			strings.write_byte(&b, '\t')
		case 'r':
			strings.write_byte(&b, '\r')
		case:
			strings.write_byte(&b, '\\')
			strings.write_byte(&b, next)
		}
		i += 1
	}
	return strings.to_string(b)
}

escape_xml :: proc(text: string) -> string {
	out := text
	out, _ = strings.replace_all(out, "&", "&amp;", context.allocator)
	out, _ = strings.replace_all(out, "<", "&lt;", context.allocator)
	out, _ = strings.replace_all(out, ">", "&gt;", context.allocator)
	out, _ = strings.replace_all(out, "\"", "&quot;", context.allocator)
	out, _ = strings.replace_all(out, "'", "&apos;", context.allocator)
	return out
}
