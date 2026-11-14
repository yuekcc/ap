package aptui

import client "../ap-core/client"

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:terminal"

// OSC 52：ESC ] 52 ; c ; <base64> ESC \。ap-tui 不碰系统剪贴板，只把文本
// 交给终端，由终端写入剪贴板，因此在 SSH、tmux 里也能用，但要求终端实现
// 这个序列并允许写入。
osc52_sequence :: proc(text: string, allocator := context.temp_allocator) -> (string, client.Error) {
	payload, berr := base64.encode(transmute([]byte)text, allocator = allocator)
	if berr != nil {
		return "", client.errorf("cannot base64-encode clipboard payload: %v", berr)
	}
	seq, serr := strings.concatenate({"\x1b]52;c;", payload, "\x1b\\"}, allocator)
	if serr != nil {
		return "", client.errorf("cannot build OSC 52 sequence: %v", serr)
	}
	return seq, client.ok_error()
}

write_osc52 :: proc(out: ^os.File, text: string) -> client.Error {
	seq, err := osc52_sequence(text)
	if !client.is_ok(err) {
		return err
	}
	if !client.write_all(out, transmute([]byte)seq) {
		return client.errorf("cannot write OSC 52 sequence to terminal")
	}
	return client.ok_error()
}

// /copy 复制最后一条 assistant 消息的原始 Markdown（不是 glow 渲染后的
// 文本），便于粘贴到编辑器或别的会话里。
copy_last_message :: proc(app: ^App) {
	text := app.renderer.last_assistant_text
	if len(text) == 0 {
		renderer_note(app, "nothing to copy: no assistant message yet")
		return
	}
	// OSC 52 由终端解释；写进管道只会得到垃圾字节。
	if !terminal.is_terminal(os.stdout) {
		renderer_note(app, "cannot copy: stdout is not a terminal")
		return
	}
	if err := write_osc52(os.stdout, text); !client.is_ok(err) {
		renderer_note(app, fmt.tprintf("copy failed: %s", err.message))
		return
	}
	renderer_note(app, fmt.tprintf("copied last assistant message (%d bytes)", len(text)))
}
