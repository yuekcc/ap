package apweb

import "core:strings"

// HTTP 层只实现够用的最小子集：MIME 静态表、percent-decode、状态行文本、
// 头部查找与 ETag 比较。所有 URL 相关逻辑集中在 http_util/server 两个文件里。

Http_Header :: struct {
	name:  string,
	value: string,
}

mime_type_for :: proc(name: string) -> string {
	dot := strings.last_index_byte(name, '.')
	slash := strings.last_index_byte(name, '/')
	if dot < 0 || dot < slash {
		return "application/octet-stream"
	}
	ext := strings.to_lower(name[dot + 1:], context.temp_allocator)
	switch ext {
	case "html", "htm":
		return "text/html; charset=utf-8"
	case "js", "mjs":
		return "text/javascript; charset=utf-8"
	case "css":
		return "text/css; charset=utf-8"
	case "json":
		return "application/json; charset=utf-8"
	case "svg":
		return "image/svg+xml"
	case "png":
		return "image/png"
	case "ico":
		return "image/x-icon"
	case "wasm":
		return "application/wasm"
	}
	return "application/octet-stream"
}

hex_digit :: proc(c: byte) -> (u8, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// 只做 percent-decode，不把 '+' 当空格：path 里的加号是普通字符。
percent_decode :: proc(text: string, allocator := context.temp_allocator) -> (string, bool) {
	if !strings.contains_rune(text, '%') {
		return text, true
	}
	out := make([]byte, len(text), allocator)
	n := 0
	i := 0
	for i < len(text) {
		if text[i] == '%' {
			if i + 2 >= len(text) {
				return "", false
			}
			hi, ok_hi := hex_digit(text[i + 1])
			lo, ok_lo := hex_digit(text[i + 2])
			if !ok_hi || !ok_lo {
				return "", false
			}
			out[n] = hi * 16 + lo
			n += 1
			i += 3
			continue
		}
		out[n] = text[i]
		n += 1
		i += 1
	}
	return string(out[:n]), true
}

split_target :: proc(target: string) -> (path, query: string) {
	if q := strings.index_byte(target, '?'); q >= 0 {
		return target[:q], target[q + 1:]
	}
	return target, ""
}

status_text :: proc(status: int) -> string {
	switch status {
	case 200:
		return "OK"
	case 202:
		return "Accepted"
	case 304:
		return "Not Modified"
	case 400:
		return "Bad Request"
	case 403:
		return "Forbidden"
	case 404:
		return "Not Found"
	case 405:
		return "Method Not Allowed"
	case 409:
		return "Conflict"
	case 413:
		return "Payload Too Large"
	case 500:
		return "Internal Server Error"
	case 501:
		return "Not Implemented"
	case 503:
		return "Service Unavailable"
	}
	return "Unknown"
}

header_value :: proc(headers: []Http_Header, name: string) -> (string, bool) {
	for header in headers {
		if strings.equal_fold(header.name, name) {
			return header.value, true
		}
	}
	return "", false
}

header_has_token :: proc(headers: []Http_Header, name, token: string) -> bool {
	value, ok := header_value(headers, name)
	if !ok {
		return false
	}
	for part in strings.split(value, ",", context.temp_allocator) {
		if strings.equal_fold(strings.trim_space(part), token) {
			return true
		}
	}
	return false
}

// If-None-Match 可能是逗号分隔的多个 ETag，也允许 W/ 弱比较前缀。
etag_matches :: proc(if_none_match, etag: string) -> bool {
	if len(if_none_match) == 0 {
		return false
	}
	for raw in strings.split(if_none_match, ",", context.temp_allocator) {
		candidate := strings.trim_space(raw)
		if candidate == "*" {
			return true
		}
		if strings.has_prefix(candidate, "W/") || strings.has_prefix(candidate, "w/") {
			candidate = strings.trim_space(candidate[2:])
		}
		if candidate == etag {
			return true
		}
	}
	return false
}
