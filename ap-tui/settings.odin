package aptui

import client "../ap-core/client"

import "core:encoding/json"
import "core:fmt"
import "core:os"

// settings.json 由 ap-cli 负责校验；ap-tui 只读取自己的 tui 段。
// 其他字段的取值错误留给 ap 子进程报错，TUI 不重复实现整套配置规则。
Tui_Settings :: struct {
	enable_glow: bool,
}

// 返回的 warning 非空时由调用方在 banner 之后展示。读取失败不阻止启动：
// ap-tui 仍然可以拉起 ap，ap 会给出真正的配置错误。
load_tui_settings :: proc(config_dir: string) -> (settings: Tui_Settings, warning: string) {
	path := client.settings_path(config_dir)
	if len(path) == 0 {
		return {}, ""
	}
	defer delete(path)
	data, derr := os.read_entire_file_from_path(path, context.allocator)
	if derr != nil {
		return {}, fmt.tprintf("ap-tui: cannot read %s: %v", path, derr)
	}
	defer delete(data)

	value, perr := json.parse_string(string(data), .JSON5, true)
	if perr != nil {
		return {}, fmt.tprintf("ap-tui: invalid JSON in %s: %v", path, perr)
	}
	defer json.destroy_value(value)

	obj, is_obj := value.(json.Object)
	if !is_obj {
		return {}, fmt.tprintf("ap-tui: %s must contain a JSON object", path)
	}

	tui_value, exists := obj["tui"]
	if !exists {
		return {}, ""
	}
	tui_obj: json.Object
	#partial switch v in tui_value {
	case json.Null:
		// 显式 null 与 ap-cli 的规则一致，按缺失处理。
		return {}, ""
	case json.Object:
		tui_obj = v
	case:
		return {}, fmt.tprintf("ap-tui: %s: \"tui\" must be an object", path)
	}

	glow_value, glow_exists := tui_obj["enable_glow"]
	if !glow_exists {
		return {}, ""
	}
	#partial switch v in glow_value {
	case json.Null:
		return {}, ""
	case json.Boolean:
		return Tui_Settings{enable_glow = bool(v)}, ""
	case:
		return {}, fmt.tprintf("ap-tui: %s: \"tui.enable_glow\" must be a boolean", path)
	}
}
