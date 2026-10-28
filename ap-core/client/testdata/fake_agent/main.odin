package fake_agent

// ap-web 集成测试用的假 agent：不实现任何 agent 能力，只按提示词里的
// 场景标记输出 canned stream-json 行，用来验证 runner / SSE / API 接线。
// 由 runner_test.odin 在测试时编译到临时目录，不参与 ap-web 本身构建。

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

emit :: proc(line: string) {
	fmt.println(line)
}

main :: proc() {
	prompt: [dynamic]u8
	buffer: [1024]u8
	for {
		n, err := os.read(os.stdin, buffer[:])
		if err != nil || n <= 0 {
			break
		}
		append(&prompt, ..buffer[:n])
	}
	text := string(prompt[:])

	switch {
	case strings.contains(text, "[scenario:stderr]"):
		fmt.eprintln("fake: boom")
		fmt.eprintln("fake: second line")
		os.exit(3)

	case strings.contains(text, "[scenario:cancel]"):
		// 先报到再挂着，测试据此确认 turn 已经跑起来，然后调 DELETE 取消。
		emit(`{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_cancel","parent_session_id":null}`)
		emit(`{"v":1,"seq":1,"ts":2,"type":"turn_start","turn":1}`)
		emit(`{"type":"message_update","ts":3,"message_id":"m1","delta":{"text":"working"}}`)
		for {
			time.sleep(100 * time.Millisecond)
		}

	case strings.contains(text, "[scenario:exit7]"):
		emit(`{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_exit7","parent_session_id":null}`)
		emit(`{"v":1,"seq":1,"ts":2,"type":"turn_end","turn":1,"stop_reason":"max_steps"}`)
		os.exit(7)
	}

	// 默认场景：一轮完整、成功的对话。future_field 用来验证 runner 是按
	// stdout 原始行转发，而不是用结构体重新序列化（那会丢未知字段）。
	emit(`{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_fake","parent_session_id":null,"future_field":{"nested":true}}`)
	emit(`{"v":1,"seq":1,"ts":2,"type":"user_message","content":"hello"}`)
	emit(`{"v":1,"seq":2,"ts":3,"type":"turn_start","turn":1}`)
	emit(`{"type":"message_update","ts":4,"message_id":"m1","delta":{"text":"hel"}}`)
	emit(`{"type":"message_update","ts":5,"message_id":"m1","delta":{"text":"lo"}}`)
	emit(`{"v":1,"seq":3,"ts":6,"type":"message_end","message_id":"m1","role":"assistant","content":[{"type":"text","text":"hello"}]}`)
	emit(`{"v":1,"seq":4,"ts":7,"type":"turn_end","turn":1,"stop_reason":"stop","usage":{"input_tokens":10,"output_tokens":2,"cached_tokens":null,"reasoning_tokens":null,"total_tokens":12}}`)
	emit(`{"v":1,"seq":5,"ts":8,"type":"session_end","reason":"exit","usage":{"input_tokens":10,"output_tokens":2,"cached_tokens":null,"reasoning_tokens":null,"total_tokens":12}}`)
	os.exit(0)
}
