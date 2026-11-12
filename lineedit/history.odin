package lineedit

import "core:os"
import "core:strings"

DEFAULT_HISTORY_MAX_LEN :: 100

// History 只负责条目和浏览位置。index == len(entries) 表示停在“当前草稿”。
History :: struct {
	entries:     [dynamic]string,
	max_len:     int,
	index:       int,
	draft:       string,
	draft_valid: bool,
}

history_init :: proc(h: ^History, max_len := DEFAULT_HISTORY_MAX_LEN) {
	h^ = {}
	h.max_len = max_len
	h.entries = make([dynamic]string, 0, 16)
}

history_destroy :: proc(h: ^History) {
	for s in h.entries {
		delete(s)
	}
	delete(h.entries)
	delete(h.draft)
	h^ = {}
}

history_len :: proc(h: ^History) -> int {
	return len(h.entries)
}

// 空行和与上一条完全相同的内容不入栈。返回是否真的加入。
history_add :: proc(h: ^History, line: string) -> bool {
	if len(line) == 0 || h.max_len <= 0 {
		return false
	}
	if len(h.entries) > 0 && h.entries[len(h.entries) - 1] == line {
		return false
	}
	cloned, err := strings.clone(line)
	if err != nil {
		return false
	}
	append(&h.entries, cloned)

	for len(h.entries) > h.max_len {
		delete(h.entries[0])
		ordered_remove(&h.entries, 0)
	}
	h.index = len(h.entries)
	return true
}

// 第一次向上时保存当前草稿；到顶后继续向上停在第 0 条。
history_prev :: proc(h: ^History, current: string) -> (text: string, ok: bool) {
	if len(h.entries) == 0 {
		return "", false
	}
	if h.index <= 0 {
		h.index = 0
		return h.entries[0], true
	}
	if h.index >= len(h.entries) {
		delete(h.draft)
		h.draft = ""
		h.draft_valid = false
		cloned, err := strings.clone(current)
		if err == nil {
			h.draft = cloned
			h.draft_valid = true
		}
		h.index = len(h.entries) - 1
		return h.entries[h.index], true
	}
	h.index -= 1
	return h.entries[h.index], true
}

// 向下到底时恢复第一次向上前保存的草稿。
history_next :: proc(h: ^History, current: string) -> (text: string, ok: bool) {
	if len(h.entries) == 0 || h.index >= len(h.entries) {
		return "", false
	}
	h.index += 1
	if h.index < len(h.entries) {
		return h.entries[h.index], true
	}
	h.index = len(h.entries)
	if h.draft_valid {
		return h.draft, true
	}
	return current, true
}

// 文件格式：每条一行，条目内部的 \n 写成 \r。这样多行历史也能用普通文本编辑器查看。
history_save :: proc(h: ^History, path: string) -> bool {
	data: [dynamic]u8
	defer delete(data)
	for entry in h.entries {
		for i in 0 ..< len(entry) {
			b := entry[i]
			if b == '\n' {
				append(&data, '\r')
			} else {
				append(&data, b)
			}
		}
		append(&data, '\n')
	}
	err := os.write_entire_file_from_bytes(path, data[:])
	return err == nil
}

history_load :: proc(h: ^History, path: string) -> bool {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return false
	}
	defer delete(data)

	start := 0
	for i in 0 ..= len(data) {
		if i < len(data) && data[i] != '\n' {
			continue
		}
		if i > start {
			entry := data[start:i]
			decoded: [dynamic]u8
			has_cr := false
			for b in entry {
				if b == '\r' {
					has_cr = true
					break
				}
			}
			if has_cr {
				decoded = make([dynamic]u8, 0, len(entry))
				for b in entry {
					if b == '\r' {
						append(&decoded, '\n')
					} else {
						append(&decoded, b)
					}
				}
				history_add(h, string(decoded[:]))
				delete(decoded)
			} else {
				history_add(h, string(entry))
			}
		}
		start = i + 1
	}
	history_reset(h)
	return true
}

history_reset :: proc(h: ^History) {
	h.index = len(h.entries)
	delete(h.draft)
	h.draft = ""
	h.draft_valid = false
}
