package ap

import "core:strings"

SSE_MAX_LINE :: 16 * 1024 * 1024

Sse_Error :: enum {
	None,
	Line_Too_Long,
	Aborted,
}

Sse_Handler :: #type proc(user: rawptr, data: string) -> bool

Sse_Parser :: struct {
	line: [dynamic]byte,
	data: [dynamic]byte,
	done: bool,
}

sse_parser_init :: proc(p: ^Sse_Parser) {
	p.line = make([dynamic]byte, 0, 1024)
	p.data = make([dynamic]byte, 0, 1024)
	p.done = false
}

sse_parser_destroy :: proc(p: ^Sse_Parser) {
	delete(p.line)
	delete(p.data)
}

sse_parser_process_line :: proc(p: ^Sse_Parser, raw_line: []byte, handler: Sse_Handler, user: rawptr) -> (Sse_Error, bool) {
	line := raw_line
	if len(line) > 0 && line[len(line) - 1] == '\r' {
		line = line[:len(line) - 1]
	}
	if len(line) == 0 {
		if len(p.data) == 0 {
			return .None, true
		}
		payload := string(p.data[:])
		clear(&p.data)
		if payload == "[DONE]" {
			p.done = true
			return .None, false
		}
		if handler != nil && !handler(user, payload) {
			p.done = true
			return .Aborted, false
		}
		return .None, true
	}
	if line[0] == ':' {
		return .None, true
	}
	if strings.has_prefix(string(line), "data:") {
		value := line[5:]
		if len(value) > 0 && value[0] == ' ' {
			value = value[1:]
		}
		if len(p.data) > 0 {
			append(&p.data, '\n')
		}
		append(&p.data, ..value)
	}
	return .None, true
}

sse_feed :: proc(p: ^Sse_Parser, chunk: []byte, handler: Sse_Handler, user: rawptr) -> Sse_Error {
	if p.done {
		return .None
	}
	start := 0
	for i in 0 ..< len(chunk) {
		if chunk[i] != '\n' {
			continue
		}
		append(&p.line, ..chunk[start:i])
		if len(p.line) > SSE_MAX_LINE {
			return .Line_Too_Long
		}
		err, keep_going := sse_parser_process_line(p, p.line[:], handler, user)
		clear(&p.line)
		if err != .None {
			return err
		}
		if !keep_going {
			return .None
		}
		start = i + 1
	}
	if start < len(chunk) {
		append(&p.line, ..chunk[start:])
		if len(p.line) > SSE_MAX_LINE {
			return .Line_Too_Long
		}
	}
	return .None
}

// 处理连接关闭前的最后一行；返回是否看到 [DONE]。
sse_finish :: proc(p: ^Sse_Parser, handler: Sse_Handler, user: rawptr) -> (Sse_Error, bool) {
	if p.done {
		return .None, true
	}
	if len(p.line) > 0 {
		err, _ := sse_parser_process_line(p, p.line[:], handler, user)
		clear(&p.line)
		if err != .None {
			return err, p.done
		}
	}
	err, _ := sse_parser_process_line(p, []byte{}, handler, user)
	if err != .None {
		return err, p.done
	}
	return .None, p.done
}
