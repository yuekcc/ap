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

@(test)
test_line_reader_strips_carriage_return :: proc(t: ^testing.T) {
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

	line_reader_feed(&reader, transmute([]byte)string("one\r\ntwo\r\nhalf\r"))
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines[0], "one")
	testing.expect_value(t, lines[1], "two")

	line_reader_flush(&reader)
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[2], "half")
}

line_reader_noop :: proc(user: rawptr, line: string) {
}

// 子进程输出一条永不换行的行时，读取器必须拒绝继续缓冲。
@(test)
test_line_reader_rejects_unbounded_line :: proc(t: ^testing.T) {
	reader: Line_Reader
	reader.callback = line_reader_noop
	defer delete(reader.buf)

	chunk := make([]byte, MAX_EVENT_LINE_BYTES + 1, context.temp_allocator)
	line_reader_feed(&reader, chunk)
	testing.expect(t, line_reader_failed(&reader))
	testing.expect_value(t, len(reader.buf), 0)

	// 失败后继续喂数据既不追加也不回调。
	line_reader_feed(&reader, transmute([]byte)string("more\n"))
	testing.expect_value(t, len(reader.buf), 0)
	line_reader_flush(&reader)
	testing.expect_value(t, len(reader.buf), 0)
}
