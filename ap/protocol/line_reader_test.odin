package protocol

import "core:strings"
import "core:testing"

collect_line :: proc(user: rawptr, line: string) {
	out := (^[dynamic]string)(user)
	append(out, strings.clone(line))
}

@(test)
test_line_reader_splits_chunks :: proc(t: ^testing.T) {
	lines: [dynamic]string
	defer {
		for line in lines {
			delete(line)
		}
		delete(lines)
	}

	reader: Line_Reader
	reader.callback = collect_line
	reader.user = &lines
	defer delete(reader.buf)

	line_reader_feed(&reader, transmute([]byte)string("one\ntw"))
	testing.expect_value(t, len(lines), 1)
	testing.expect_value(t, lines[0], "one")

	line_reader_feed(&reader, transmute([]byte)string("o\nthree\n"))
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[1], "two")
	testing.expect_value(t, lines[2], "three")

	line_reader_flush(&reader)
	testing.expect_value(t, len(lines), 3)

	line_reader_feed(&reader, transmute([]byte)string("tail"))
	line_reader_flush(&reader)
	testing.expect_value(t, len(lines), 4)
	testing.expect_value(t, lines[3], "tail")
}
