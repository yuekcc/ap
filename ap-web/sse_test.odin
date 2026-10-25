package main

import "core:testing"
import "core:strings"
import "core:thread"

import "../internal"

// SSE 帧是逐字节的协议：测试直接断言完整输出，不用 contains 之类宽松匹配。
@(test)
test_sse_encode_event :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	sse_encode_event(&b, "ap", `{"type":"message_update","delta":{"text":"hi"}}`, 42)

	testing.expect_value(t, strings.to_string(b),
		"event: ap\n" +
		`data: {"type":"message_update","delta":{"text":"hi"}}` + "\n" +
		"id: 42\n\n")
}

// data 里的换行必须编码成多个 data: 行，否则客户端只会看到第一行。
@(test)
test_sse_encode_event_multiline_data :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	sse_encode_event(&b, "log", "alpha\nbeta\n", 7)

	testing.expect_value(t, strings.to_string(b),
		"event: log\n" +
		"data: alpha\n" +
		"data: beta\n" +
		"data: \n" +
		"id: 7\n\n")
}

@(test)
test_sse_encode_comment :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	sse_encode_comment(&b, "ping")

	testing.expect_value(t, strings.to_string(b), ": ping\n\n")
}

// 心跳 = 注释行 + ping 事件，拼成一个 chunk 便于调用方一次写出。
@(test)
test_sse_encode_heartbeat :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	sse_encode_heartbeat(&b, 1700000000, 9)

	testing.expect_value(t, strings.to_string(b),
		": ping\n\n" +
		"event: ping\n" +
		"data: {\"ts\":1700000000}\n" +
		"id: 9\n\n")
}

// turn_done 信封的字段顺序固定，前端按字段名读，测试锁住字节序防止漂移。
@(test)
test_sse_turn_done_json :: proc(t: ^testing.T) {
	done := Sse_Turn_Done {
		exit_code      = 0,
		stop_reason    = "stop",
		usage          = internal.Usage{input_tokens = 10, output_tokens = 5, total_tokens = 15},
		stderr_preview = "line one\nline two\n",
	}

	data := sse_turn_done_json(done)
	defer delete(data)

	// JSON 会把 stderr_preview 里的换行转义成 \n（两个字符），所以帧本身仍是单行 data；
	// 含原始换行的多行 data 编码由 test_sse_encode_event_multiline_data 覆盖。
	testing.expect_value(t, data,
		`{"exit_code":0,"stop_reason":"stop",` +
		`"usage":{"input_tokens":10,"output_tokens":5,` +
		`"cached_tokens":null,"reasoning_tokens":null,"total_tokens":15},` +
		`"stderr_preview":"line one\nline two\n"}`)
}

// 空 stderr 与缺失 stop_reason 都编码成 null，前端不用区分「字段不存在」和「空字符串」。
@(test)
test_sse_turn_done_json_nulls :: proc(t: ^testing.T) {
	data := sse_turn_done_json(Sse_Turn_Done{exit_code = 1})
	defer delete(data)

	testing.expect_value(t, data,
		`{"exit_code":1,"stop_reason":null,` +
		`"usage":{"input_tokens":null,"output_tokens":null,` +
		`"cached_tokens":null,"reasoning_tokens":null,"total_tokens":null},` +
		`"stderr_preview":null}`)
}

// 端到端：带换行的 stderr 预览进 turn_done 帧。JSON 先把它转义成 \n，
// 所以帧里只有一行 data；真正的多行 data 编码由 multiline 测试单独锁住。
@(test)
test_sse_turn_done_frame_bytes :: proc(t: ^testing.T) {
	done := Sse_Turn_Done {
		exit_code      = 1,
		stop_reason    = "max_steps",
		stderr_preview = "boom\nsecond line",
	}
	data := sse_turn_done_json(done)
	defer delete(data)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	sse_encode_event(&b, "turn_done", data, 43)

	testing.expect_value(t, strings.to_string(b),
		"event: turn_done\n" +
		`data: {"exit_code":1,"stop_reason":"max_steps",` +
		`"usage":{"input_tokens":null,"output_tokens":null,` +
		`"cached_tokens":null,"reasoning_tokens":null,"total_tokens":null},` +
		`"stderr_preview":"boom\nsecond line"}` + "\n" +
		"id: 43\n\n")
}

// 从订阅者 channel 取一帧；测试里总是期望有帧可读。
sse_test_take :: proc(t: ^testing.T, sub: ^Sse_Subscriber) -> string {
	frame, ok := sse_subscriber_recv(sub)
	testing.expect(t, ok, "expected one SSE frame")
	return frame
}

// hub 是 seq 的唯一分配点：每次广播 +1，所有订阅者看到同一个 id。
@(test)
test_hub_broadcast_assigns_monotonic_ids :: proc(t: ^testing.T) {
	hub: Sse_Hub
	sse_hub_init(&hub)
	defer sse_hub_destroy(&hub)

	sub: Sse_Subscriber
	testing.expect(t, sse_hub_subscribe(&hub, &sub, 4))
	defer sse_hub_unsubscribe(&hub, &sub)
	testing.expect_value(t, sse_hub_subscriber_count(&hub), 1)

	first := sse_hub_broadcast(&hub, "ap", `{"type":"message_update"}`)
	testing.expect_value(t, first, u64(1))

	frame := sse_test_take(t, &sub)
	defer delete(frame)
	testing.expect_value(t, frame, "event: ap\ndata: {\"type\":\"message_update\"}\nid: 1\n\n")

	second := sse_hub_broadcast(&hub, "ap", `{"type":"message_end"}`)
	testing.expect_value(t, second, u64(2))

	frame2 := sse_test_take(t, &sub)
	defer delete(frame2)
	testing.expect_value(t, frame2, "event: ap\ndata: {\"type\":\"message_end\"}\nid: 2\n\n")
}

// 多个订阅者各自拿到一份独立的字符串，但帧内容（含 id）完全一致。
@(test)
test_hub_broadcast_fans_out_to_every_subscriber :: proc(t: ^testing.T) {
	hub: Sse_Hub
	sse_hub_init(&hub)
	defer sse_hub_destroy(&hub)

	first, second: Sse_Subscriber
	testing.expect(t, sse_hub_subscribe(&hub, &first, 4))
	defer sse_hub_unsubscribe(&hub, &first)
	testing.expect(t, sse_hub_subscribe(&hub, &second, 4))
	defer sse_hub_unsubscribe(&hub, &second)
	testing.expect_value(t, sse_hub_subscriber_count(&hub), 2)

	id := sse_hub_broadcast(&hub, "ap", `{"type":"message_update","ts":1}`)
	testing.expect_value(t, id, u64(1))

	frame_a := sse_test_take(t, &first)
	defer delete(frame_a)
	frame_b := sse_test_take(t, &second)
	defer delete(frame_b)
	testing.expect_value(t, frame_a, frame_b)
	testing.expect_value(t, frame_a,
		"event: ap\ndata: {\"type\":\"message_update\",\"ts\":1}\nid: 1\n\n")
}

// 没有订阅者时广播照样推进 seq，不会悬挂也不会报错。
@(test)
test_hub_broadcast_without_subscribers :: proc(t: ^testing.T) {
	hub: Sse_Hub
	sse_hub_init(&hub)
	defer sse_hub_destroy(&hub)

	testing.expect_value(t, sse_hub_broadcast(&hub, "ap", `{}`), u64(1))
	testing.expect_value(t, sse_hub_broadcast(&hub, "ap", `{}`), u64(2))
	testing.expect_value(t, sse_hub_subscriber_count(&hub), 0)
}

// 退订即从订阅表移除：之后的广播不再投递给它。
@(test)
test_hub_unsubscribe_removes_subscriber :: proc(t: ^testing.T) {
	hub: Sse_Hub
	sse_hub_init(&hub)
	defer sse_hub_destroy(&hub)

	gone, alive: Sse_Subscriber
	testing.expect(t, sse_hub_subscribe(&hub, &gone, 4))
	testing.expect(t, sse_hub_subscribe(&hub, &alive, 4))
	defer sse_hub_unsubscribe(&hub, &alive)

	sse_hub_unsubscribe(&hub, &gone)
	testing.expect_value(t, sse_hub_subscriber_count(&hub), 1)

	testing.expect_value(t, sse_hub_broadcast(&hub, "ap", `{}`), u64(1))

	frame := sse_test_take(t, &alive)
	defer delete(frame)
	testing.expect_value(t, frame, "event: ap\ndata: {}\nid: 1\n\n")
}

// 缓冲满 = 连接线程不再消费：丢弃订阅者并关闭 channel，绝不阻塞 turn。
@(test)
test_hub_drops_subscriber_when_buffer_is_full :: proc(t: ^testing.T) {
	hub: Sse_Hub
	sse_hub_init(&hub)
	defer sse_hub_destroy(&hub)

	sub: Sse_Subscriber
	testing.expect(t, sse_hub_subscribe(&hub, &sub, 1))

	testing.expect_value(t, sse_hub_broadcast(&hub, "ap", `{"n":1}`), u64(1))
	testing.expect_value(t, sse_hub_broadcast(&hub, "ap", `{"n":2}`), u64(2))
	testing.expect_value(t, sse_hub_subscriber_count(&hub), 0)

	// 已投递的第一帧还在缓冲里，之后 channel 已关闭。
	frame := sse_test_take(t, &sub)
	defer delete(frame)
	testing.expect_value(t, frame, "event: ap\ndata: {\"n\":1}\nid: 1\n\n")

	_, open := sse_subscriber_recv(&sub)
	testing.expect(t, !open, "dropped subscriber's channel must be closed")

	sse_hub_unsubscribe(&hub, &sub)
}

// 心跳 = 注释行 + ping 事件，同样消耗一个 id，后续事件的 id 接着往下走。
@(test)
test_hub_heartbeat_sends_comment_and_ping :: proc(t: ^testing.T) {
	hub: Sse_Hub
	sse_hub_init(&hub)
	defer sse_hub_destroy(&hub)

	sub: Sse_Subscriber
	testing.expect(t, sse_hub_subscribe(&hub, &sub, 4))
	defer sse_hub_unsubscribe(&hub, &sub)

	testing.expect_value(t, sse_hub_heartbeat(&hub, 1700000000), u64(1))

	frame := sse_test_take(t, &sub)
	defer delete(frame)
	testing.expect_value(t, frame,
		": ping\n\n" +
		"event: ping\n" +
		"data: {\"ts\":1700000000}\n" +
		"id: 1\n\n")

	testing.expect_value(t, sse_hub_broadcast(&hub, "ap", `{}`), u64(2))
}

// 关停时 hub 关闭仍注册的 channel，阻塞在 recv 的连接线程会立刻拿到 !ok 退出；
// channel 本身留到线程收尾时由 sse_hub_unsubscribe 销毁。
@(test)
test_hub_destroy_closes_subscriber_channels :: proc(t: ^testing.T) {
	hub: Sse_Hub
	sse_hub_init(&hub)

	sub: Sse_Subscriber
	testing.expect(t, sse_hub_subscribe(&hub, &sub, 4))

	sse_hub_destroy(&hub)

	_, open := sse_subscriber_recv(&sub)
	testing.expect(t, !open, "destroyed hub must close subscriber channels")

	sse_hub_unsubscribe(&hub, &sub)
}

// 事件泵线程和心跳线程会并发广播：id 必须无重复地覆盖 1..N。
ID_STRESS_COUNT :: 200

Id_Stress_Job :: struct {
	hub: ^Sse_Hub,
	ids: [ID_STRESS_COUNT]u64,
}

id_stress_worker :: proc(data: rawptr) {
	job := (^Id_Stress_Job)(data)
	for i in 0 ..< ID_STRESS_COUNT {
		job.ids[i] = sse_hub_broadcast(job.hub, "ap", `{}`)
	}
}

@(test)
test_hub_allocates_ids_across_threads :: proc(t: ^testing.T) {
	hub: Sse_Hub
	sse_hub_init(&hub)
	defer sse_hub_destroy(&hub)

	first, second: Id_Stress_Job
	first.hub = &hub
	second.hub = &hub

	t1 := thread.create_and_start_with_data(rawptr(&first), id_stress_worker, name = "sse-ids-1")
	t2 := thread.create_and_start_with_data(rawptr(&second), id_stress_worker, name = "sse-ids-2")
	thread.join(t1)
	thread.join(t2)

	total := 2 * ID_STRESS_COUNT
	seen := make([]bool, total + 1)
	defer delete(seen)

	for job in ([]^Id_Stress_Job{&first, &second}) {
		for id in job.ids {
			testing.expectf(t, id >= 1 && id <= u64(total), "id %d out of range", id)
			testing.expectf(t, !seen[id], "id %d assigned twice", id)
			seen[id] = true
		}
	}
	for id in 1 ..= total {
		testing.expectf(t, seen[id], "id %d was never assigned", id)
	}
}
