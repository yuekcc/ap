package protocol

// transcript / stream-json 共用的协议常量与信封结构。
// 这个包只依赖 core，不放任何本地包逻辑。

SCHEMA_VERSION :: 1
PROVIDER_NAME :: "openai-chat-completions"
VERSION :: "0.1.0"

// transcript/stream 事件的公共信封字段。
Event_Header :: struct {
	v:    int    `json:"v"`,
	seq:  int    `json:"seq"`,
	ts:   i64    `json:"ts"`,
	type: string `json:"type"`,
}

// transcript 与 stream 事件共用的 usage 结构。
Usage :: struct {
	input_tokens:     Maybe(int) `json:"input_tokens"`,
	output_tokens:    Maybe(int) `json:"output_tokens"`,
	cached_tokens:    Maybe(int) `json:"cached_tokens"`,
	reasoning_tokens: Maybe(int) `json:"reasoning_tokens"`,
	total_tokens:     Maybe(int) `json:"total_tokens"`,
}
