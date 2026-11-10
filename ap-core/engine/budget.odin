package engine

import "../platform"

import "base:runtime"
import "core:fmt"
import "core:strings"

// 上下文预算：本地 token 估算、usage 校准、工具结果省略。
//
// 估算只用于「接近预算时怎么决策」，不追求绝对值准确；偏差由 usage 校准
// 吃掉。所有函数都是纯的：同样的输入得到同样的数字与同样的 messages，
// 不读时钟、不做 IO 决策。见 docs/context-management.md。

// ---- 估算 ----

// ASCII 字节数除 4，非 ASCII 字节数除 3：UTF-8 里中日韩字符约 3 字节 1 token。
ESTIMATE_ASCII_DIVISOR :: 4
ESTIMATE_NON_ASCII_DIVISOR :: 3
// 结构字段的固定小开销：每条消息 4 token，每个 tool_call 8 token。
ESTIMATE_MESSAGE_OVERHEAD :: 4
ESTIMATE_TOOL_CALL_OVERHEAD :: 8
// 图片 token 无法从字节数估算，按每张的固定值计入。这个值覆盖常见视觉
// 模型单张中高分辨率图片的开销，偏保守。
ESTIMATE_IMAGE_TOKENS :: 1600

// 校准系数上下限，防估算函数退化或脏 usage 带偏。
CALIBRATION_MIN_PERCENT :: 50
CALIBRATION_MAX_PERCENT :: 200

// 省略规则：最近 6 个工具结果永不省略；小于 2048 字节的结果省略收益低于噪声成本。
ELIDE_KEEP_RECENT_RESULTS :: 6
ELIDE_MIN_BYTES :: 2048

estimate_text_tokens :: proc(s: string) -> int {
	ascii := 0
	non_ascii := 0
	for i in 0 ..< len(s) {
		if s[i] < 0x80 {
			ascii += 1
		} else {
			non_ascii += 1
		}
	}
	return ceil_div(ascii, ESTIMATE_ASCII_DIVISOR) + ceil_div(non_ascii, ESTIMATE_NON_ASCII_DIVISOR)
}

ceil_div :: proc(value, divisor: int) -> int {
	if value <= 0 {
		return 0
	}
	return (value + divisor - 1) / divisor
}

estimate_message_tokens :: proc(msg: Chat_Message) -> int {
	total := ESTIMATE_MESSAGE_OVERHEAD
	if content, ok := msg.content.?; ok {
		total += estimate_text_tokens(content)
	}
	if reasoning, ok := msg.reasoning_content.?; ok {
		total += estimate_text_tokens(reasoning)
	}
	if call_id, ok := msg.tool_call_id.?; ok {
		total += estimate_text_tokens(call_id)
	}
	for image in msg.images {
		total += ESTIMATE_IMAGE_TOKENS
		// 图片消息额外的文本部分（文件名、MIME）很小，但仍计入。
		total += estimate_text_tokens(image.name)
		total += estimate_text_tokens(image.mime_type)
	}
	for call in msg.tool_calls {
		total += ESTIMATE_TOOL_CALL_OVERHEAD
		total += estimate_text_tokens(call.id)
		total += estimate_text_tokens(call.function.name)
		total += estimate_text_tokens(call.function.arguments)
	}
	return total
}

estimate_messages_tokens :: proc(messages: []Chat_Message) -> int {
	total := 0
	for msg in messages {
		total += estimate_message_tokens(msg)
	}
	return total
}

// 工具定义与 system prompt 一样计入 input_tokens，分开算会漏。
// 参数用 canonical JSON，保证同一份定义每次估出同一个数。
estimate_tool_defs_tokens :: proc(defs: []Tool_Def) -> int {
	total := 0
	for def in defs {
		total += estimate_text_tokens(def.function.name)
		total += estimate_text_tokens(def.function.description)
		total += estimate_text_tokens(platform.json_canonical_string(def.function.parameters))
	}
	return total
}

estimate_request_tokens :: proc(
	system_prompt: string,
	messages: []Chat_Message,
	tools_tokens: int,
) -> int {
	return estimate_text_tokens(system_prompt) + estimate_messages_tokens(messages) + tools_tokens
}

// ---- 校准 ----

// 上一次请求的本地估算与 provider 回报的真实 input_tokens 之比。
// 没有任何观测值时返回 100；退化观测（0、异常大）被钳制在 [50, 200]。
calibration_percent_from :: proc(last_estimate, observed_input: int) -> int {
	if last_estimate <= 0 || observed_input <= 0 {
		return 100
	}
	percent := observed_input * 100 / last_estimate
	if percent < CALIBRATION_MIN_PERCENT {
		return CALIBRATION_MIN_PERCENT
	}
	if percent > CALIBRATION_MAX_PERCENT {
		return CALIBRATION_MAX_PERCENT
	}
	return percent
}

calibrate_tokens :: proc(raw_estimate, percent: int) -> int {
	if percent == 100 {
		return raw_estimate
	}
	return raw_estimate * percent / 100
}

// ---- 省略 ----

// 一条可省略候选：投影后 tool 消息在 messages 里的位置，以及决策需要的元数据。
Tool_Result_Slot :: struct {
	message_index: int,
	name:          string,
	ok:            bool,
	bytes:         int,
}

// 桩文本只含确定性字段：没有时间、没有 seq、没有「第几步」。
// 同一 transcript 因此在任何精度下都算出逐字节相同的文本。
elided_stub :: proc(name: string, bytes: int) -> string {
	return fmt.tprintf(
		"[tool output elided: %s, %d bytes. Re-run the tool or re-read the file if you need it again.]",
		name,
		bytes,
	)
}

Elide_Result :: struct {
	elided_results: int,
	elided_bytes:   int,
	// 省略后的原始估算（未乘校准系数）。
	raw_estimate:   int,
}

// 把较早的大工具输出替换成桩，直到估算落到 target_tokens 以内。
// 从旧到新，跳过失败结果、小结果与最近 ELIDE_KEEP_RECENT_RESULTS 个结果。
// 只改 tool 消息的 content，不动消息条数、顺序与 assistant.tool_calls。
elide_tool_results :: proc(
	messages: []Chat_Message,
	slots: []Tool_Result_Slot,
	target_tokens: int,
	calibration_percent: int,
	base_raw_estimate: int,
	allocator: runtime.Allocator,
) -> Elide_Result {
	result := Elide_Result{raw_estimate = base_raw_estimate}
	if target_tokens <= 0 || len(slots) == 0 {
		return result
	}

	// 先按排除规则筛出可省略候选，保持消息顺序（旧到新）。
	candidates := make([dynamic]int, 0, len(slots), allocator)
	for slot, i in slots {
		if !slot.ok {
			continue
		}
		if slot.bytes < ELIDE_MIN_BYTES {
			continue
		}
		append(&candidates, i)
	}
	limit := len(candidates) - ELIDE_KEEP_RECENT_RESULTS
	if limit <= 0 {
		return result
	}
	elidable := candidates[:limit]

	estimated := calibrate_tokens(result.raw_estimate, calibration_percent)
	for index in elidable {
		if estimated * 100 <= target_tokens * CONTEXT_ELIDE_TARGET_PERCENT {
			break
		}
		slot := slots[index]
		msg := &messages[slot.message_index]
		old, has_old := msg.content.?
		if !has_old {
			continue
		}
		stub := elided_stub(slot.name, slot.bytes)
		before := estimate_text_tokens(old)
		for image in msg.images {
			before += ESTIMATE_IMAGE_TOKENS
			before += estimate_text_tokens(image.name)
			before += estimate_text_tokens(image.mime_type)
		}
		after := estimate_text_tokens(stub)
		msg.content = stub
		msg.images = nil
		result.raw_estimate += after - before
		result.elided_results += 1
		result.elided_bytes += slot.bytes
		estimated = calibrate_tokens(result.raw_estimate, calibration_percent)
	}
	return result
}

// 生成交接提示词与 system prompt 拼接。
// 冻结 prompt 作为稳定前缀，handoff.md 拼在后面：技能清单与 AGENTS.md 硬约束
// 只在冻结 prompt 里，替换掉会让模型只能从对话里反推。
HANDOFF_PROMPT :: #load("prompts/handoff.md", string)

handoff_system_prompt :: proc(frozen_system_prompt: string, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, frozen_system_prompt)
	if !strings.has_suffix(frozen_system_prompt, "\n") {
		strings.write_byte(&b, '\n')
	}
	strings.write_byte(&b, '\n')
	strings.write_string(&b, HANDOFF_PROMPT)
	return strings.to_string(b)
}

// 交接文档进入新 session 的首条 user_message；判定「这条是交接」靠首行文本，
// 不加字段，免得旧前端误解析。
handoff_user_message :: proc(source_session_id, content: string) -> string {
	return fmt.tprintf("## 上一会话交接\n来源 session: %s\n\n%s", source_session_id, content)
}
