package aptools

import platform "../../ap-core/platform"
import tool "../../ap-core/tool"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// edit_file：整批精确匹配、容错匹配，以及 BOM 与换行风格保留。

Edit :: struct {
	old_text: string,
	new_text: string,
}

detect_line_ending :: proc(content: string) -> string {
	lf := strings.index_byte(content, '\n')
	if lf < 0 {
		return "\n"
	}
	crlf := strings.index(content, "\r\n")
	if crlf < 0 {
		return "\n"
	}
	return "\r\n" if crlf < lf else "\n"
}

normalize_to_lf :: proc(text: string) -> string {
	crlf, _ := strings.replace_all(text, "\r\n", "\n", context.allocator)
	cr, _ := strings.replace_all(crlf, "\r", "\n", context.allocator)
	return cr
}

restore_line_endings :: proc(text, ending: string) -> string {
	if ending != "\r\n" {
		return text
	}
	out, _ := strings.replace_all(text, "\n", "\r\n", context.allocator)
	return out
}

split_bom :: proc(content: string) -> (bom, text: string) {
	if strings.has_prefix(content, BOM_UTF8) {
		return BOM_UTF8, content[len(BOM_UTF8):]
	}
	return "", content
}

is_trim_char :: proc(c: byte) -> bool {
	switch c {
	case ' ', '\t', '\r', '\v', '\f':
		return true
	}
	return false
}

// fuzzy_normalize 是 pi 的 normalizeForFuzzyMatch 的近似实现：去掉行尾空白，把弯引号、
// Unicode 破折号、特殊空格和全角 ASCII 归一为 ASCII。Odin 没有 NFKC 表，其余兼容字符
// 保持原样。
fuzzy_normalize :: proc(text: string) -> string {
	mapped := strings.builder_make()
	for r in text {
		switch {
		case r >= 0xFF01 && r <= 0xFF5E:
			strings.write_rune(&mapped, r - 0xFEE0)
		case r == 0x00A0, r >= 0x2000 && r <= 0x200A, r == 0x202F, r == 0x205F, r == 0x3000:
			strings.write_byte(&mapped, ' ')
		case r >= 0x2018 && r <= 0x201B:
			strings.write_byte(&mapped, '\'')
		case r >= 0x201C && r <= 0x201F:
			strings.write_byte(&mapped, '"')
		case r >= 0x2010 && r <= 0x2015, r == 0x2212:
			strings.write_byte(&mapped, '-')
		case:
			strings.write_rune(&mapped, r)
		}
	}

	mapped_text := strings.to_string(mapped)
	out := strings.builder_make()
	line_start := 0
	for i in 0 ..= len(mapped_text) {
		if i != len(mapped_text) && mapped_text[i] != '\n' {
			continue
		}
		line_end := i
		for line_end > line_start && is_trim_char(mapped_text[line_end - 1]) {
			line_end -= 1
		}
		strings.write_string(&out, mapped_text[line_start:line_end])
		if i < len(mapped_text) {
			strings.write_byte(&out, '\n')
		}
		line_start = i + 1
	}
	return strings.to_string(out)
}

Fuzzy_Match :: struct {
	found:           bool,
	index:           int,
	match_length:    int,
	used_fuzzy:      bool,
	replacement_base: string,
}

fuzzy_find_text :: proc(content, old_text: string) -> Fuzzy_Match {
	if index := strings.index(content, old_text); index >= 0 {
		return {found = true, index = index, match_length = len(old_text), replacement_base = content}
	}
	fuzzy_content := fuzzy_normalize(content)
	fuzzy_old := fuzzy_normalize(old_text)
	if len(fuzzy_old) == 0 {
		return {}
	}
	index := strings.index(fuzzy_content, fuzzy_old)
	if index < 0 {
		return {}
	}
	return {
		found = true,
		index = index,
		match_length = len(fuzzy_old),
		used_fuzzy = true,
		replacement_base = fuzzy_content,
	}
}

count_occurrences :: proc(content, old_text: string) -> int {
	fuzzy_content := fuzzy_normalize(content)
	fuzzy_old := fuzzy_normalize(old_text)
	if len(fuzzy_old) == 0 {
		return 0
	}
	count := 0
	offset := 0
	for offset <= len(fuzzy_content) {
		index := strings.index(fuzzy_content[offset:], fuzzy_old)
		if index < 0 {
			break
		}
		count += 1
		offset += index + len(fuzzy_old)
	}
	return count
}

Matched_Edit :: struct {
	edit_index:   int,
	match_index:  int,
	match_length: int,
	new_text:     string,
}

Line_Span :: struct {
	start: int,
	end:   int,
}

line_spans :: proc(content: string) -> []Line_Span {
	spans := make([dynamic]Line_Span, 0, 64)
	line_start := 0
	for i in 0 ..< len(content) {
		if content[i] == '\n' {
			append(&spans, Line_Span{start = line_start, end = i + 1})
			line_start = i + 1
		}
	}
	if line_start < len(content) {
		append(&spans, Line_Span{start = line_start, end = len(content)})
	}
	return spans[:]
}

split_lines_with_endings :: proc(content: string) -> []string {
	lines := make([dynamic]string, 0, 64)
	line_start := 0
	for i in 0 ..< len(content) {
		if content[i] == '\n' {
			append(&lines, content[line_start:i + 1])
			line_start = i + 1
		}
	}
	if line_start < len(content) {
		append(&lines, content[line_start:])
	}
	return lines[:]
}

apply_replacements :: proc(content: string, replacements: []Matched_Edit, base_offset: int) -> string {
	b := strings.builder_make()
	position := 0
	for replacement in replacements {
		start := replacement.match_index - base_offset
		strings.write_string(&b, content[position:start])
		strings.write_string(&b, replacement.new_text)
		position = start + replacement.match_length
	}
	strings.write_string(&b, content[position:])
	return strings.to_string(b)
}

replacement_line_range :: proc(lines: []Line_Span, replacement: Matched_Edit) -> (start_line, end_line: int, err: platform.Error) {
	replacement_start := replacement.match_index
	replacement_end := replacement.match_index + replacement.match_length

	start_line = -1
	for line, i in lines {
		if replacement_start >= line.start && replacement_start < line.end {
			start_line = i
			break
		}
	}
	if start_line == -1 {
		return 0, 0, platform.errorf("Replacement range is outside the base content.")
	}
	end_line = start_line
	for end_line < len(lines) && lines[end_line].end < replacement_end {
		end_line += 1
	}
	if end_line >= len(lines) {
		return 0, 0, platform.errorf("Replacement range is outside the base content.")
	}
	return start_line, end_line + 1, platform.ok_error()
}

// apply_replacements_preserving_unchanged_lines 只在被改动的行上写归一化后的内容，
// 其余行原样保留，避免为了匹配而重写整份文件。
apply_replacements_preserving_unchanged_lines :: proc(
	original_content, base_content: string,
	replacements: []Matched_Edit,
) -> (string, platform.Error) {
	original_lines := split_lines_with_endings(original_content)
	base_lines := line_spans(base_content)
	if len(original_lines) != len(base_lines) {
		return "", platform.errorf("Cannot preserve unchanged lines because the base content has a different line count.")
	}

	Group :: struct {
		start_line:   int,
		end_line:     int,
		replacements: [dynamic]Matched_Edit,
	}
	groups := make([dynamic]Group, 0, len(replacements))
	sorted := slice.clone(replacements, context.allocator)
	slice.sort_by(sorted, proc(a, b: Matched_Edit) -> bool {return a.match_index < b.match_index})

	for matched in sorted {
		replacement := Matched_Edit {
			match_index  = matched.match_index,
			match_length = matched.match_length,
			new_text     = matched.new_text,
		}
		range_start, range_end, rerr := replacement_line_range(base_lines, replacement)
		if !platform.is_ok(rerr) {
			return "", rerr
		}
		if len(groups) > 0 {
			current := &groups[len(groups) - 1]
			if range_start < current.end_line {
				current.end_line = max(current.end_line, range_end)
				append(&current.replacements, replacement)
				continue
			}
		}
		group := Group{start_line = range_start, end_line = range_end}
		append(&group.replacements, replacement)
		append(&groups, group)
	}

	b := strings.builder_make()
	original_index := 0
	for group in groups {
		for original_index < group.start_line {
			strings.write_string(&b, original_lines[original_index])
			original_index += 1
		}
		group_start := base_lines[group.start_line].start
		group_end := base_lines[group.end_line - 1].end
		strings.write_string(
			&b,
			apply_replacements(base_content[group_start:group_end], group.replacements[:], group_start),
		)
		original_index = group.end_line
	}
	for original_index < len(original_lines) {
		strings.write_string(&b, original_lines[original_index])
		original_index += 1
	}
	return strings.to_string(b), platform.ok_error()
}

not_found_error :: proc(path: string, edit_index, total_edits: int) -> platform.Error {
	if total_edits == 1 {
		return platform.errorf(
			"Could not find the exact text in %s. The old text must match exactly including all whitespace and newlines.",
			path,
		)
	}
	return platform.errorf(
		"Could not find edits[%d] in %s. The oldText must match exactly including all whitespace and newlines.",
		edit_index,
		path,
	)
}

duplicate_error :: proc(path: string, edit_index, total_edits, occurrences: int) -> platform.Error {
	if total_edits == 1 {
		return platform.errorf(
			"Found %d occurrences of the text in %s. The text must be unique. Please provide more context to make it unique.",
			occurrences,
			path,
		)
	}
	return platform.errorf(
		"Found %d occurrences of edits[%d] in %s. Each oldText must be unique. Please provide more context to make it unique.",
		occurrences,
		edit_index,
		path,
	)
}

empty_old_text_error :: proc(path: string, edit_index, total_edits: int) -> platform.Error {
	if total_edits == 1 {
		return platform.errorf("oldText must not be empty in %s.", path)
	}
	return platform.errorf("edits[%d].oldText must not be empty in %s.", edit_index, path)
}

no_change_error :: proc(path: string, total_edits: int) -> platform.Error {
	if total_edits == 1 {
		return platform.errorf(
			"No changes made to %s. The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected.",
			path,
		)
	}
	return platform.errorf("No changes made to %s. The replacements produced identical content.", path)
}

apply_edits_to_normalized_content :: proc(
	normalized_content: string,
	edits: []Edit,
	path: string,
) -> (base_content, new_content: string, err: platform.Error) {
	total := len(edits)
	normalized := make([]Edit, total)
	for edit, i in edits {
		normalized[i] = {old_text = normalize_to_lf(edit.old_text), new_text = normalize_to_lf(edit.new_text)}
	}
	for edit, i in normalized {
		if len(edit.old_text) == 0 {
			return "", "", empty_old_text_error(path, i, total)
		}
	}

	used_fuzzy := false
	for edit in normalized {
		if fuzzy_find_text(normalized_content, edit.old_text).used_fuzzy {
			used_fuzzy = true
			break
		}
	}
	replacement_base := normalized_content
	if used_fuzzy {
		replacement_base = fuzzy_normalize(normalized_content)
	}

	matched := make([dynamic]Matched_Edit, 0, total)
	for edit, i in normalized {
		match := fuzzy_find_text(replacement_base, edit.old_text)
		if !match.found {
			return "", "", not_found_error(path, i, total)
		}
		occurrences := count_occurrences(replacement_base, edit.old_text)
		if occurrences > 1 {
			return "", "", duplicate_error(path, i, total, occurrences)
		}
		append(
			&matched,
			Matched_Edit {
				edit_index = i,
				match_index = match.index,
				match_length = match.match_length,
				new_text = edit.new_text,
			},
		)
	}

	slice.sort_by(matched[:], proc(a, b: Matched_Edit) -> bool {return a.match_index < b.match_index})
	for i in 1 ..< len(matched) {
		previous := matched[i - 1]
		current := matched[i]
		if previous.match_index + previous.match_length > current.match_index {
			return "", "", platform.errorf(
				"edits[%d] and edits[%d] overlap in %s. Merge them into one edit or target disjoint regions.",
				previous.edit_index,
				current.edit_index,
				path,
			)
		}
	}

	if used_fuzzy {
		preserved, perr := apply_replacements_preserving_unchanged_lines(normalized_content, replacement_base, matched[:])
		if !platform.is_ok(perr) {
			return "", "", perr
		}
		new_content = preserved
	} else {
		new_content = apply_replacements(replacement_base, matched[:], 0)
	}
	base_content = normalized_content
	if base_content == new_content {
		return "", "", no_change_error(path, total)
	}
	return base_content, new_content, platform.ok_error()
}

edit_arg_string :: proc(obj: json.Object, names: []string) -> (string, bool) {
	for name in names {
		if value, ok := obj[name]; ok {
			if text, is_string := value.(json.String); is_string {
				return string(text), true
			}
		}
	}
	return "", false
}

append_edit_from_object :: proc(obj: json.Object, edits: ^[dynamic]Edit) -> platform.Error {
	old_text, has_old := edit_arg_string(obj, []string{"oldText", "old_string"})
	new_text, has_new := edit_arg_string(obj, []string{"newText", "new_string"})
	if !has_old {
		return platform.errorf("each edit must have a string oldText")
	}
	if !has_new {
		return platform.errorf("each edit must have a string newText")
	}
	append(edits, Edit{old_text = old_text, new_text = new_text})
	return platform.ok_error()
}

// parse_edits 兼容 pi 的宽松输入：edits 可以是数组、单个对象或 JSON 字符串；
// 旧式顶层 oldText/newText（以及 ap 过去的 old_string/new_string）视为单条编辑。
parse_edits :: proc(args: json.Object) -> ([]Edit, platform.Error) {
	edits := make([dynamic]Edit, 0, 1)

	if value, ok := args["edits"]; ok {
		parsed := value
		if text, is_string := value.(json.String); is_string {
			decoded, derr := json.parse_string(string(text), .JSON, true)
			if derr != nil {
				return nil, platform.errorf("edits is a string but not valid JSON")
			}
			parsed = decoded
		}
		if array, is_array := parsed.(json.Array); is_array {
			for item in array {
				obj, is_object := item.(json.Object)
				if !is_object {
					return nil, platform.errorf("each edit must be an object")
				}
				if err := append_edit_from_object(obj, &edits); !platform.is_ok(err) {
					return nil, err
				}
			}
		} else if obj, is_object := parsed.(json.Object); is_object {
			if err := append_edit_from_object(obj, &edits); !platform.is_ok(err) {
				return nil, err
			}
		} else {
			return nil, platform.errorf("edits must be an array of objects")
		}
	} else {
		old_text, has_old := edit_arg_string(args, []string{"oldText", "old_string"})
		new_text, has_new := edit_arg_string(args, []string{"newText", "new_string"})
		if !has_old || !has_new {
			return nil, platform.errorf("missing parameter \"edits\"")
		}
		append(&edits, Edit{old_text = old_text, new_text = new_text})
	}

	if len(edits) == 0 {
		return nil, platform.errorf("Edit tool input is invalid. edits must contain at least one replacement.")
	}
	return edits[:], platform.ok_error()
}

tool_edit_file :: proc(args: json.Object, cfg: ^Tool_Config, ctx: ^tool.Tool_Context) -> tool.Tool_Result {
	raw_path, perr := tool.tool_arg_string(args, "file_path")
	if !platform.is_ok(perr) {
		return arg_error(perr)
	}
	if replace_all, ok := args["replace_all"]; ok {
		if flag, is_bool := replace_all.(json.Boolean); is_bool && bool(flag) {
			return tool.tool_fail("replace_all is not supported; pass one edit per occurrence")
		}
	}
	edits, eerr := parse_edits(args)
	if !platform.is_ok(eerr) {
		return arg_error(eerr)
	}

	resolved, rerr := platform.resolve_tool_path(ctx.cwd, raw_path)
	if !platform.is_ok(rerr) {
		return arg_error(rerr)
	}
	info, serr := os.stat(resolved, context.allocator)
	if serr != nil {
		return tool.tool_fail(fmt.tprintf("Could not edit file: %s. %v.", raw_path, serr))
	}
	defer os.file_info_delete(info, context.allocator)
	if info.type == .Directory {
		return tool.tool_fail(fmt.tprintf("not a file (directory): %s", resolved))
	}
	if info.size > i64(cfg.max_capture_bytes) {
		return tool.tool_fail("file is larger than max_capture_bytes; edit it with bash instead")
	}
	data, derr := os.read_entire_file_from_path(resolved, context.allocator)
	if derr != nil {
		return tool.tool_fail(fmt.tprintf("cannot read %s: %v", resolved, derr))
	}
	if !platform.valid_utf8(data) {
		return tool.tool_fail("file is not valid UTF-8; use bash instead")
	}

	raw := string(data)
	bom, text := split_bom(raw)
	ending := detect_line_ending(text)
	normalized := normalize_to_lf(text)
	_, new_content, aerr := apply_edits_to_normalized_content(normalized, edits, raw_path)
	if !platform.is_ok(aerr) {
		return arg_error(aerr)
	}

	final := strings.concatenate({bom, restore_line_endings(new_content, ending)}, context.allocator)
	if werr := atomic_write_text(resolved, final); !platform.is_ok(werr) {
		return arg_error(werr)
	}
	return tool.tool_ok(fmt.tprintf("Successfully replaced %d block(s) in %s.", len(edits), raw_path))
}
