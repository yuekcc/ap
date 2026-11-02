package tool

import "core:encoding/json"
import "core:fmt"
import "core:time"

// 按名字查找工具并执行。参数不是 JSON 对象或名字未知都返回工具失败，
// 由 Loop 决定是否终止 turn（只有 fatal 才终止）。
tool_execute :: proc(
	registry: ^Registry,
	name:     string,
	args:     json.Value,
	ctx:      ^Tool_Context,
) -> Tool_Result {
	start := time.tick_now()
	if _, is_obj := args.(json.Object); !is_obj {
		return tool_fail("tool arguments must be a JSON object")
	}
	tool, found := registry_find(registry, name)
	if !found {
		return tool_fail(fmt.tprintf("unknown tool %q", name))
	}
	result := tool.execute(tool.user, args, ctx)
	result.duration_ms = int(time.tick_since(start) / time.Millisecond)
	return result
}
