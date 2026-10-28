package platform

import "core:sync"

// 取消信号。生产者（信号处理器、前端）置位，消费者（provider、子进程泵）轮询。
Cancel_Token :: struct {
	value: i32,
}

cancel_token_cancel :: proc(token: ^Cancel_Token) {
	if token != nil {
		sync.atomic_store(&token.value, 1)
	}
}

cancel_token_cancelled :: proc(token: ^Cancel_Token) -> bool {
	if token == nil {
		return false
	}
	return sync.atomic_load(&token.value) != 0
}
