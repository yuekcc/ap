package engine

import "core:strings"

// 一次性文本调用（handoff、会话标题）共用的抓取器：不带工具、只要最终文本与用量。
// provider 的增量缓冲在 provider_stream 返回时释放，所以文本要在这里持有副本。

One_Shot_Capture :: struct {
	text:     [dynamic]byte,
	end_text: string,
	usage:    Usage,
	seen_end: bool,
	error:    Provider_Error,
}

one_shot_capture_destroy :: proc(c: ^One_Shot_Capture) {
	delete(c.text)
	delete(c.end_text)
}

one_shot_capture_event :: proc(user: rawptr, event: Provider_Event) {
	capture := (^One_Shot_Capture)(user)
	switch ev in event {
	case Provider_Text_Delta:
		append(&capture.text, ..transmute([]byte)ev.text)
	case Provider_Message_End:
		capture.seen_end = true
		capture.usage = ev.usage
		// 没有 delta 的 provider（或纯非流式替身）只在 message_end 里给全文。
		if len(capture.text) == 0 && len(ev.text) > 0 {
			delete(capture.end_text)
			capture.end_text = strings.clone(ev.text)
		}
	case Provider_Error_Event:
		capture.error = ev.err
	case Provider_Message_Start, Provider_Reasoning_Delta, Provider_Tool_Start,
	     Provider_Tool_Delta, Provider_Tool_End:
	}
}

// 抓到的全文（已去首尾空白）；流式 delta 优先，退回到 message_end 的整段。
one_shot_capture_text :: proc(c: ^One_Shot_Capture) -> string {
	if len(c.text) > 0 {
		return strings.trim_space(string(c.text[:]))
	}
	return strings.trim_space(c.end_text)
}
