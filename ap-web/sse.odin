package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import sync_chan "core:sync/chan"
import "core:time"

import "../internal"

// SSE 帧格式固定为 event / data / id 三行加一个空行（docs/web.md「SSE」）。
// id 由 hub 单点分配，编码器只负责按协议写出字节。
sse_encode_event :: proc(b: ^strings.Builder, event: string, data: string, id: u64) {
	fmt.sbprintf(b, "event: %s\n", event)
	sse_write_data_lines(b, data)
	fmt.sbprintf(b, "id: %d\n\n", id)
}

// data 可能含换行（stderr 预览等多行内容）：按 SSE 规范每个物理行都加
// data: 前缀，客户端再拼回 \n。少了这步，换行会直接截断帧结构。
sse_write_data_lines :: proc(b: ^strings.Builder, data: string) {
	start := 0
	for i in 0 ..< len(data) {
		if data[i] != '\n' {
			continue
		}
		fmt.sbprintf(b, "data: %s\n", data[start:i])
		start = i + 1
	}
	fmt.sbprintf(b, "data: %s\n", data[start:])
}

// 心跳注释行：EventSource 会忽略注释内容，代理与浏览器只据此判断连接还活着。
sse_encode_comment :: proc(b: ^strings.Builder, text: string) {
	fmt.sbprintf(b, ": %s\n\n", text)
}

// 一次心跳 = 注释行 + ping 事件；拼成同一个 chunk，调用方一次写出即可。
sse_encode_heartbeat :: proc(b: ^strings.Builder, ts: i64, id: u64) {
	sse_encode_comment(b, "ping")
	sse_encode_event(b, "ping", sse_ping_data(ts), id)
}

// ping 事件的 data（临时分配的短命字符串，编码完即丢弃）。
sse_ping_data :: proc(ts: i64) -> string {
	return fmt.tprintf("{{\"ts\":%d}}", ts)
}

// turn 结束信封。stop_reason 取自 turn_end，缺失时回退 session_end，两者都没有则 null；
// stderr_preview 只放尾部一小段供前端展示（可能是空/多行文本）。
// usage 用 internal.Usage：所有 token 字段可为 null，不用 0 冒充缺失。
Sse_Turn_Done :: struct {
	exit_code:      int            `json:"exit_code"`,
	stop_reason:    Maybe(string)  `json:"stop_reason"`,
	usage:          internal.Usage `json:"usage"`,
	stderr_preview: Maybe(string)  `json:"stderr_preview"`,
}

// 把信封序列化成 SSE data。返回的字符串归调用方所有（delete 释放）。
// 这里用标准库 marshal：非 ASCII 会转成 \uXXXX，JSON.parse 仍能正确还原。
sse_turn_done_json :: proc(envelope: Sse_Turn_Done, allocator := context.allocator) -> string {
	data, err := json.marshal(envelope, {}, allocator)
	if err != nil {
		return strings.clone("{}", allocator)
	}
	defer delete(data, allocator)
	return strings.clone(string(data), allocator)
}

// ---------------------------------------------------------------------------
// hub
// ---------------------------------------------------------------------------

// 订阅者 channel 的默认缓冲深度。够吸收一次 turn 的突发流式事件；
// 真满了说明连接线程已经不消费了，丢弃订阅者比反压 agent 更安全。
SSE_SUBSCRIBER_BUFFER :: 256

// 心跳间隔。hub 自己不持线程，由调用方按这个节拍调 sse_hub_heartbeat
// （与 server 的连接/关停生命周期同源，测试里也能直接手动驱动）。
SSE_HEARTBEAT_INTERVAL :: 15 * time.Second

// 一个订阅者对应一个 SSE 连接。channel 里放的是已经编码好的完整 chunk，
// 连接线程只需 recv → write → delete，hub 不碰 socket。
Sse_Subscriber :: struct {
	frames: sync_chan.Chan(string),
}

// 连接线程阻塞等待下一帧；ok=false 表示订阅已被关闭（hub 丢弃或关停），该收尾了。
// 返回的字符串归调用方所有，写完后 delete(frame)。
sse_subscriber_recv :: proc(sub: ^Sse_Subscriber) -> (frame: string, ok: bool) {
	return sync_chan.recv(sub.frames)
}

// 订阅表 = 互斥锁 + 动态数组（docs/web.md「风险与对策」：不引入复杂并发原语）。
// next_id 与订阅表共用一把锁，保证 id 分配和投递顺序一致。
Sse_Hub :: struct {
	mu:          sync.Mutex,
	subscribers: [dynamic]^Sse_Subscriber,
	next_id:     u64,
}

sse_hub_init :: proc(hub: ^Sse_Hub) {
	hub.mu = {}
	hub.subscribers = make([dynamic]^Sse_Subscriber)
	hub.next_id = 0
}

// 订阅：调用方持有 Sse_Subscriber 本身（通常挂在连接结构上），hub 只存指针。
sse_hub_subscribe :: proc(hub: ^Sse_Hub, sub: ^Sse_Subscriber, buffer := SSE_SUBSCRIBER_BUFFER) -> bool {
	frames, err := sync_chan.create(sync_chan.Chan(string), buffer, context.allocator)
	if err != nil {
		return false
	}
	sub.frames = frames

	sync.mutex_lock(&hub.mu)
	defer sync.mutex_unlock(&hub.mu)
	append(&hub.subscribers, sub)
	return true
}

// 退订：连接线程收尾（正常断开或写失败）时调用一次。
// 会关闭并销毁 channel；hub 因缓冲区满丢弃订阅者时已经关过 channel，这里重复关闭是安全的。
sse_hub_unsubscribe :: proc(hub: ^Sse_Hub, sub: ^Sse_Subscriber) {
	sync.mutex_lock(&hub.mu)
	defer sync.mutex_unlock(&hub.mu)

	for existing, i in hub.subscribers {
		if existing == sub {
			ordered_remove(&hub.subscribers, i)
			break
		}
	}
	sync_chan.close(sub.frames)
	sync_chan.destroy(sub.frames)
}

sse_hub_subscriber_count :: proc(hub: ^Sse_Hub) -> int {
	sync.mutex_lock(&hub.mu)
	defer sync.mutex_unlock(&hub.mu)
	return len(hub.subscribers)
}

// 广播一个事件：分配 id、编码一次、给每个订阅者投递一份。
// 非阻塞：channel 满就丢弃该订阅者并关闭它的 channel（唤醒阻塞的 recv），turn 不受影响。
sse_hub_broadcast :: proc(hub: ^Sse_Hub, event: string, data: string) -> u64 {
	sync.mutex_lock(&hub.mu)
	defer sync.mutex_unlock(&hub.mu)

	hub.next_id += 1
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	sse_encode_event(&b, event, data, hub.next_id)
	sse_hub_fanout_locked(hub, strings.to_string(b))
	return hub.next_id
}

// 心跳：注释行 + ping 事件拼成一个 chunk，同样走一遍 id 分配与广播。
sse_hub_heartbeat :: proc(hub: ^Sse_Hub, ts: i64) -> u64 {
	sync.mutex_lock(&hub.mu)
	defer sync.mutex_unlock(&hub.mu)

	hub.next_id += 1
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	sse_encode_heartbeat(&b, ts, hub.next_id)
	sse_hub_fanout_locked(hub, strings.to_string(b))
	return hub.next_id
}

// 持 hub.mu 调用。channel 里的字符串归接收方所有，因此每个订阅者拿一份 clone；
// 丢弃订阅者时顺便释放没送出去的那份。
sse_hub_fanout_locked :: proc(hub: ^Sse_Hub, chunk: string) {
	i := 0
	for i < len(hub.subscribers) {
		sub := hub.subscribers[i]
		frame := strings.clone(chunk)
		if sync_chan.try_send(sub.frames, frame) {
			i += 1
			continue
		}
		delete(frame)
		sync_chan.close(sub.frames)
		ordered_remove(&hub.subscribers, i)
	}
}

// 关停时调用：关闭所有仍注册的订阅者 channel（唤醒阻塞的 recv），释放订阅表。
// 只 close 不 destroy：channel 归连接线程所有，它退出时会调 sse_hub_unsubscribe 收尾，
// 所以调用方应先让连接线程结束、再销毁 hub，避免和线程里的 destroy 抢跑。
sse_hub_destroy :: proc(hub: ^Sse_Hub) {
	sync.mutex_lock(&hub.mu)
	defer sync.mutex_unlock(&hub.mu)

	for sub in hub.subscribers {
		sync_chan.close(sub.frames)
	}
	clear(&hub.subscribers)
	delete(hub.subscribers)
	hub.subscribers = nil
	hub.next_id = 0
}
