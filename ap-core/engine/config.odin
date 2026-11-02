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
}

DEFAULT_BASE_URL :: "https://api.openai.com/v1"

settings_defaults :: proc() -> Settings {
	return Settings {
		base_url = DEFAULT_BASE_URL,
		max_steps = 100,
		max_tokens = 8192,
		llm_timeout_ms = 600000,
		blob_threshold_bytes = 102400,
		stream_include_usage = true,
	}
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
