package ap

import "core:encoding/json"
import "core:fmt"
import "core:strings"

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
		data, err := json.marshal(v)
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
			key_json, _ := json.marshal(key)
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
