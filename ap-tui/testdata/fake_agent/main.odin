package fake_agent

// ap-tui 测试用的假 agent：不实现任何 agent 能力，只按提示词里的场景标记
// 输出 canned stream-json 行，用来验证取消后的收尾行与 stderr 抑制。
// 由 tui_test.odin 在测试时编译到临时目录，不参与 ap-tui 本身构建。

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
	case strings.contains(text, "[scenario:cancel]"):
		// 模拟真实 ap：进度块写 stderr，事件走 stdout，然后挂起直到被取消。
		fmt.eprintln("## Step 1")
		emit(`{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_cancel","parent_session_id":null}`)
		emit(`{"v":1,"seq":1,"ts":2,"type":"turn_start","turn":1}`)
		emit(`{"v":1,"seq":2,"ts":3,"type":"cancel","scope":"step","target_id":null}`)
		for {
			time.sleep(50 * time.Millisecond)
		}
	}
}
