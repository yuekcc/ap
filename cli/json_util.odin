package ap

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// Odin 标准库的 json.marshal 会把非 Latin-1 的 Unicode 全部转成 \uXXXX。
// 这里在 marshal 之后把字符串里的合法 Unicode 转义还原成 UTF-8 原文；
// 控制字符、引号、反斜杠以及非法 UTF-8 序列仍然保持转义，保证 JSON 合法。
json_marshal_utf8 :: proc(v: any, allocator := context.allocator) -> ([]byte, json.Marshal_Error) {
	data, err := json.marshal(v, {}, allocator)
	if err != nil {
		return nil, err
	}
	return json_unescape_unicode(data, allocator), nil
}

json_hex_digit :: proc(c: byte) -> (u32, bool) {
	switch {
	case c >= '0' && c <= '9':
		return u32(c - '0'), true
	case c >= 'a' && c <= 'f':
		return u32(c - 'a' + 10), true
	case c >= 'A' && c <= 'F':
		return u32(c - 'A' + 10), true
	}
	return 0, false
}

json_hex4 :: proc(data: []byte, start: int) -> (u32, bool) {
	if start + 4 > len(data) {
		return 0, false
	}
	value: u32
	for i in 0 ..< 4 {
		digit, ok := json_hex_digit(data[start + i])
		if !ok {
			return 0, false
		}
		value = (value << 4) | digit
	}
	return value, true
}

json_write_u_escape :: proc(b: ^strings.Builder, code: u32) {
	digits := "0123456789abcdef"
	strings.write_string(b, `\u`)
	for shift := 12; shift >= 0; shift -= 4 {
		strings.write_byte(b, digits[(code >> uint(shift)) & 0xf])
	}
}

json_write_short_escape :: proc(b: ^strings.Builder, r: rune) -> bool {
	switch r {
	case '"':
		strings.write_string(b, `\"`)
		return true
	case '\\':
		strings.write_string(b, `\\`)
		return true
	case '\b':
		strings.write_string(b, `\b`)
		return true
	case '\f':
		strings.write_string(b, `\f`)
		return true
	case '\n':
		strings.write_string(b, `\n`)
		return true
	case '\r':
		strings.write_string(b, `\r`)
		return true
	case '\t':
		strings.write_string(b, `\t`)
		return true
	}
	return false
}

json_unescape_unicode :: proc(data: []byte, allocator := context.allocator) -> []byte {
	b := strings.builder_make(allocator)
	in_string := false
	i := 0
	for i < len(data) {
		c := data[i]
		if !in_string {
			strings.write_byte(&b, c)
			if c == '"' {
				in_string = true
			}
			i += 1
			continue
		}

		switch c {
		case '"':
			strings.write_byte(&b, c)
			in_string = false
			i += 1
		case '\\':
			if i + 1 >= len(data) {
				strings.write_byte(&b, c)
				i += 1
				continue
			}
			escape := data[i + 1]
			switch escape {
			case 'u':
				code, ok := json_hex4(data, i + 2)
				if !ok {
					strings.write_string(&b, `\u`)
					i += 2
					continue
				}
				if code >= 0xD800 && code <= 0xDBFF {
					// 可能是 UTF-16 代理对。
					if i + 11 < len(data) && data[i + 6] == '\\' && data[i + 7] == 'u' {
						low, low_ok := json_hex4(data, i + 8)
						if low_ok && low >= 0xDC00 && low <= 0xDFFF {
							combined := 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
							strings.write_rune(&b, rune(combined))
							i += 12
							continue
						}
					}
					json_write_u_escape(&b, 0xFFFD)
					i += 6
					continue
				}
				if code >= 0xDC00 && code <= 0xDFFF {
					json_write_u_escape(&b, 0xFFFD)
					i += 6
					continue
				}
				r := rune(code)
				if code < 0x20 {
					if !json_write_short_escape(&b, r) {
						json_write_u_escape(&b, code)
					}
				} else if !json_write_short_escape(&b, r) {
					strings.write_rune(&b, r)
				}
				i += 6
			case 'x':
				// Odin 对非法 UTF-8 字节会输出 \xNN；JSON 不接受这种转义，改成 \u00NN。
				if i + 3 < len(data) {
					hi, hi_ok := json_hex_digit(data[i + 2])
					lo, lo_ok := json_hex_digit(data[i + 3])
					if hi_ok && lo_ok {
						json_write_u_escape(&b, (hi << 4) | lo)
						i += 4
						continue
					}
				}
				strings.write_byte(&b, '\\')
				strings.write_byte(&b, 'x')
				i += 2
			case:
				strings.write_byte(&b, '\\')
				strings.write_byte(&b, escape)
				i += 2
			}
		case:
			if c < 0x80 {
				strings.write_byte(&b, c)
				i += 1
			} else {
				r, size := utf8.decode_rune(data[i:])
				if r == utf8.RUNE_ERROR && size == 1 {
					json_write_u_escape(&b, 0xFFFD)
					i += 1
				} else {
					strings.write_string(&b, string(data[i:i + size]))
					i += size
				}
			}
		}
	}
	text := strings.to_string(b)
	return transmute([]byte)text
}

json_canonical_string :: proc(value: json.Value) -> string {
	switch v in value {
	case json.Null:
		return "null"
	case json.Boolean:
		return "true" if bool(v) else "false"
	case json.Integer:
		return fmt.tprintf("%d", i64(v))
	case json.Float:
		return fmt.tprintf("%v", f64(v))
	case json.String:
		data, err := json_marshal_utf8(v)
		if err == nil {
			return string(data)
		}
		return `""`
	case json.Array:
		b := strings.builder_make()
		strings.write_byte(&b, '[')
		for item, i in v {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			strings.write_string(&b, json_canonical_string(item))
		}
		strings.write_byte(&b, ']')
		return strings.to_string(b)
	case json.Object:
		keys := make([dynamic]string, 0, len(v))
		for key in v {
			append(&keys, key)
		}
		// 小对象用插入排序，避免额外依赖并保证稳定输出。
		for i in 1 ..< len(keys) {
			j := i
			for j > 0 && keys[j] < keys[j - 1] {
				keys[j], keys[j - 1] = keys[j - 1], keys[j]
				j -= 1
			}
		}
		b := strings.builder_make()
		strings.write_byte(&b, '{')
		for key, i in keys {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			key_json, _ := json_marshal_utf8(key)
			strings.write_string(&b, string(key_json))
			strings.write_byte(&b, ':')
			strings.write_string(&b, json_canonical_string(v[key]))
		}
		strings.write_byte(&b, '}')
		return strings.to_string(b)
	}
	return "null"
}

json_value_or_empty_object :: proc(value: json.Value) -> json.Value {
	if value == nil {
		obj := json.Object{}
		return obj
	}
	return value
}

// 工具参数进入 provider 请求前做规范化；错误日志与 transcript 不依赖该顺序。
json_arguments_string :: proc(value: json.Value) -> string {
	return json_canonical_string(json_value_or_empty_object(value))
}
