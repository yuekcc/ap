package tool

import "../platform"
import "../protocol"

// 读取 text 块：优先解析 blob 引用。task 与 context 投影共用。
content_block_text :: proc(
	project: platform.Project,
	block:   protocol.Content_Block,
) -> (string, platform.Error) {
	if ref, ok := block.text_ref.?; ok {
		data, berr := platform.blob_read(project, ref)
		if !platform.is_ok(berr) {
			return "", berr
		}
		return string(data), platform.ok_error()
	}
	if text, ok := block.text.?; ok {
		return text, platform.ok_error()
	}
	return "", platform.ok_error()
}
