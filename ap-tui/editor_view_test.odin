package aptui

import "core:os"
import "core:strings"
import "core:testing"

render_view :: proc(t: ^testing.T, e: ^Editor, cols, rows: int, with_finish: bool) -> string {
	dir := test_temp_dir("editor-view")
	defer os.remove_all(dir)

	path := strings.concatenate({dir, "/out.txt"}, context.temp_allocator)
	file, ferr := os.open(path, {.Read, .Write, .Create, .Trunc})
	testing.expect_value(t, ferr, nil)
	if ferr != nil {
		return ""
	}
	v := Editor_View {
		out = file,
	}
	editor_view_draw(&v, e, cols, rows)
	if with_finish {
		editor_view_finish(&v)
	}
	os.close(file)

	data, _ := os.read_entire_file_from_path(path, context.allocator)
	return string(data)
}

@(test)
test_view_single_line :: proc(t: ^testing.T) {
	e := editor_with("abc")
	defer editor_destroy(&e)
	out := render_view(t, &e, 40, 10, false)
	defer delete(out)

	testing.expect(t, strings.contains(out, "› abc"))
	testing.expect(t, strings.contains(out, "\x1b[5C"))
	testing.expect(t, !strings.contains(out, "\r\n"))
}

@(test)
test_view_multiline :: proc(t: ^testing.T) {
	e := editor_with("a\nb")
	defer editor_destroy(&e)
	out := render_view(t, &e, 40, 10, false)
	defer delete(out)

	testing.expect(t, strings.contains(out, "› a\r\n  b"))
	// 光标在第二行，列号含前缀宽度。
	testing.expect(t, strings.contains(out, "\x1b[3C"))
}

@(test)
test_view_scroll_header :: proc(t: ^testing.T) {
	e := editor_with("a\nb\nc\nd\ne")
	defer editor_destroy(&e)
	out := render_view(t, &e, 40, 3, false)
	defer delete(out)

	// 最后一行可见，被裁掉的内容用 “…” 提示。
	testing.expect(t, strings.contains(out, "  …"))
	testing.expect(t, strings.contains(out, "  e"))
	testing.expect(t, !strings.contains(out, "› "))
}

@(test)
test_view_finish_moves_below_block :: proc(t: ^testing.T) {
	e := editor_with("a\nb")
	defer editor_destroy(&e)
	out := render_view(t, &e, 40, 10, true)
	defer delete(out)

	testing.expect(t, strings.has_suffix(out, "\r\n"))

	e2 := editor_with("a\nb")
	defer editor_destroy(&e2)
	e2.cursor = 1
	out2 := render_view(t, &e2, 40, 10, true)
	defer delete(out2)
	// 光标在第一行，提交时要先下移到块底再换行。
	testing.expect(t, strings.contains(out2, "\r\x1b[1B\n"))
}
