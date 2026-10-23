package internal

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
