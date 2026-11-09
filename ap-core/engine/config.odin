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
	// 预算公式 target = window - max_tokens - reserve 里 reserve 占**窗口**的
	// 百分比。真正要防的是本地估算的偏差，它随输入规模走、与输出上限无关，
	// 所以余量按窗口算而不是按 max_tokens 算。
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
// 余量取窗口的 5%：1M 窗口下是 52428，够覆盖本地估算的系统性偏差，又不会
// 明显压缩可用输入。用比例而不是固定 token 数，是为了让余量跟着窗口规模
// 走——小窗口换成大模型时不必手工重调。
DEFAULT_CONTEXT_RESERVE_PERCENT :: 5
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

// 余量按窗口等比算出；百分比向下取整，0% 就是不留余量。
// 基准是窗口而不是 max_tokens：max_tokens 已经是输出的硬上限，不再需要
// 额外余量；真正会漂移的是输入侧的 token 估算。
context_reserve_tokens_for :: proc(settings: ^Settings) -> int {
	if settings.context_window_tokens <= 0 || settings.context_reserve_percent <= 0 {
		return 0
	}
	return settings.context_window_tokens * settings.context_reserve_percent / 100
}

// 预算水位：target = window - max_tokens - reserve。
// 0 表示预算关闭，调用方据此回到不计算 token 的旧行为。
context_budget_target :: proc(settings: ^Settings, max_tokens: int) -> int {
	if settings.context_window_tokens <= 0 {
		return 0
	}
	return settings.context_window_tokens - max_tokens - context_reserve_tokens_for(settings)
}

// 交接调用的投影预算：窗口扣掉交接输出上限与**同一个**窗口余量。
// 余量是预算的安全垫，交接请求也要留，不能因为输出上限不同就换一份。
// 预算关闭时返回 0，表示不省略。
handoff_budget_target :: proc(settings: ^Settings) -> int {
	if settings.context_window_tokens <= 0 {
		return 0
	}
	return settings.context_window_tokens - settings.handoff_max_tokens - context_reserve_tokens_for(settings)
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
