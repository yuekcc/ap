package engine

// SDK 设置只包含 agent 运行时机制相关的字段。
// 工具超时、最大捕获字节、子代理深度属于应用层工具配置。
Settings :: struct {
	model:                string,
	base_url:             string,
	api_key:              string,
	max_steps:            int,
	max_tokens:           int,
	llm_timeout_ms:       int,
	blob_threshold_bytes: int,
	stream_include_usage: bool,
	// 模型上下文窗口的总 token 数。预算计算的输入；0 表示关闭预算与自动
	// 交接，行为回到不计算 token 的版本（见 docs/context-management.md）。
	context_window_tokens:  int,
	// 预算公式 target = window - max_tokens - reserve 里 reserve 占输出上限的
	// 百分比。余量按当次调用的 max_tokens 等比算出，所以调小输出上限时余量
	// 自动收紧，不会出现「窗口装不下 max_tokens + 固定余量」的死锁。
	// 0 表示不留余量；只在预算开启时生效。
	context_reserve_percent: int,
	// 生成交接文档那次调用的 max_tokens。交接文本不需要 64K，所以单列一项；
	// 与 --max-tokens 无关。
	handoff_max_tokens:     int,
}

DEFAULT_BASE_URL :: "https://api.openai.com/v1"

// ap 面向 1M 上下文、64K 单次输出的模型设计，默认值按这个规格取。
DEFAULT_MAX_TOKENS :: 65536
DEFAULT_CONTEXT_WINDOW_TOKENS :: 1048576

// 预算公式里两个参数的默认值，同时是 settings.json 字段的缺省值。
// 余量取输出上限的一半：估算偏差与输出长度波动共用这份空间。用比例而不是
// 固定 token 数，是为了让 target 只随窗口与输出上限变化，调小 max_tokens
// 时余量自动跟着收紧。
DEFAULT_CONTEXT_RESERVE_PERCENT :: 50
// 交接输出上限是绝对 token 数：交接文本不需要 64K，和 --max-tokens 无关。
DEFAULT_HANDOFF_MAX_TOKENS :: 16384

// 唯一的上下文决策阈值：估算值达到 target 的 90% 就进入上下文管理流程
// （先试工具结果省略，仍超阈则 handoff）。
HANDOFF_TRIGGER_PERCENT :: 90
// 省略的收敛目标：一次省略把水位压到 target 的 80%，避免每 step 重排。
// 它不决定是否交接，决定交不交接的只有 HANDOFF_TRIGGER_PERCENT。
CONTEXT_ELIDE_TARGET_PERCENT :: 80

settings_defaults :: proc() -> Settings {
	return Settings {
		base_url = DEFAULT_BASE_URL,
		max_steps = 100,
		max_tokens = DEFAULT_MAX_TOKENS,
		llm_timeout_ms = 600000,
		blob_threshold_bytes = 102400,
		stream_include_usage = true,
		context_window_tokens = DEFAULT_CONTEXT_WINDOW_TOKENS,
		context_reserve_percent = DEFAULT_CONTEXT_RESERVE_PERCENT,
		handoff_max_tokens = DEFAULT_HANDOFF_MAX_TOKENS,
	}
}

// 余量按输出上限等比算出；百分比向下取整，0% 就是不留余量。
context_reserve_tokens_for :: proc(settings: ^Settings, max_tokens: int) -> int {
	if max_tokens <= 0 || settings.context_reserve_percent <= 0 {
		return 0
	}
	return max_tokens * settings.context_reserve_percent / 100
}

// 预算水位：target = window - max_tokens - reserve。
// 0 表示预算关闭，调用方据此回到不计算 token 的旧行为。
context_budget_target :: proc(settings: ^Settings, max_tokens: int) -> int {
	if settings.context_window_tokens <= 0 {
		return 0
	}
	return settings.context_window_tokens - max_tokens - context_reserve_tokens_for(settings, max_tokens)
}

// 交接调用的投影预算：窗口扣掉交接输出上限与按它算出的余量。
// 预算关闭时返回 0，表示不省略。
handoff_budget_target :: proc(settings: ^Settings) -> int {
	if settings.context_window_tokens <= 0 {
		return 0
	}
	reserve := context_reserve_tokens_for(settings, settings.handoff_max_tokens)
	return settings.context_window_tokens - settings.handoff_max_tokens - reserve
}

// 预算开启时 target <= 0 是配置错误：预算公式失去意义，继续跑只会把请求
// 推给 provider 等它报 context_too_long。context_window_tokens = 0 表示
// 关闭预算，不参与这条判断。
context_budget_invalid :: proc(settings: ^Settings, target: int) -> bool {
	return settings.context_window_tokens > 0 && target <= 0
}

parse_positive_int :: proc(s: string) -> (int, bool) {
	value := 0
	if len(s) == 0 {
		return 0, false
	}
	for ch in s {
		if ch < '0' || ch > '9' {
			return 0, false
		}
		value = value * 10 + int(ch - '0')
		if value > 1_000_000_000 {
			return 0, false
		}
	}
	return value, value > 0
}
