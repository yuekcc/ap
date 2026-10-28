package platform

import "core:strings"
import "core:unicode/utf8"

split_lines :: proc(s: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 8, allocator)
	start := 0
	for i in 0 ..= len(s) {
		if i == len(s) || s[i] == '\n' {
			line := s[start:i]
			if len(line) > 0 && line[len(line) - 1] == '\r' {
				line = line[:len(line) - 1]
			}
			cloned, _ := strings.clone(line, allocator)
			append(&out, cloned)
			start = i + 1
		}
	}
	return out[:]
}

valid_utf8 :: proc(data: []byte) -> bool {
	return utf8.valid_string(string(data))
}

// 把可能包含非法 UTF-8 的字节转成合法字符串，用于 JSON transcript。
sanitize_utf8 :: proc(data: []byte) -> string {
	if utf8.valid_string(string(data)) {
		return string(data)
	}
	b := strings.builder_make()
	remaining := data
	for len(remaining) > 0 {
		r, size := utf8.decode_rune(remaining)
		if r == utf8.RUNE_ERROR && size == 1 {
			strings.write_string(&b, "\uFFFD")
			remaining = remaining[1:]
			continue
		}
		strings.write_rune(&b, r)
		remaining = remaining[size:]
	}
	return strings.to_string(b)
}

utf8_prefix :: proc(data: []byte, max_bytes: int) -> string {
	if len(data) <= max_bytes {
		return string(data)
	}
	cut := max_bytes
	for cut > 0 && !utf8.valid_string(string(data[:cut])) {
		// 只截断可能不完整的多字节序列，最多回退 3 字节。
		if max_bytes - cut >= 3 {
			break
		}
		cut -= 1
	}
	return string(data[:cut])
}
