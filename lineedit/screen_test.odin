package lineedit

// 测试用的最小 VT100 屏幕模型。只实现 renderer 实际会发出的序列：
// CR/LF、CU A/B/C/D、ED 0、EL 0，以及 SGR/OSC/DCS 的忽略。

import "core:strings"
import "core:unicode/utf8"

Screen_Cell :: struct {
	text: string,
	cont: bool,
}

Screen :: struct {
	cols, rows: int,
	cells:      []Screen_Cell,
	cur_row:    int,
	cur_col:    int,
}

screen_init :: proc(cols, rows: int) -> Screen {
	s: Screen
	s.cols = cols
	s.rows = rows
	s.cells = make([]Screen_Cell, cols * rows)
	return s
}

screen_destroy :: proc(s: ^Screen) {
	for &c in s.cells {
		delete(c.text)
	}
	delete(s.cells)
	s^ = {}
}

screen_feed_string :: proc(s: ^Screen, text: string) {
	screen_feed(s, transmute([]u8)text)
}

screen_feed :: proc(s: ^Screen, data: []u8) {
	i := 0
	for i < len(data) {
		b := data[i]
		switch {
		case b == '\r':
			s.cur_col = 0
			i += 1
		case b == '\n':
			s.cur_col = 0
			s.cur_row += 1
			if s.cur_row >= s.rows {
				s.cur_row = s.rows - 1
				screen_scroll(s)
			}
			i += 1
		case b == 0x1b:
			i = screen_escape(s, data, i)
		case:
			it := utf8.decode_grapheme_iterator_make(string(data[i:]))
			text, g, ok := utf8.decode_grapheme_iterate(&it)
			if !ok || len(text) == 0 {
				i += 1
				continue
			}
			w := g.width
			if w < 0 {
				w = 0
			}
			if w == 0 {
				w = 1
			}
			screen_put(s, text, w)
			i += len(text)
		}
	}
}

screen_put :: proc(s: ^Screen, text: string, width: int) {
	if s.cur_col + width > s.cols && s.cur_col > 0 {
		s.cur_col = 0
		s.cur_row += 1
		if s.cur_row >= s.rows {
			s.cur_row = s.rows - 1
			screen_scroll(s)
		}
	}
	if s.cur_row < 0 || s.cur_row >= s.rows || s.cur_col < 0 || s.cur_col >= s.cols {
		return
	}
	idx := s.cur_row * s.cols + s.cur_col
	delete(s.cells[idx].text)
	s.cells[idx] = Screen_Cell{text = strings.clone(text)}
	if width >= 2 && s.cur_col + 1 < s.cols {
		delete(s.cells[idx + 1].text)
		s.cells[idx + 1] = Screen_Cell{cont = true}
	}
	s.cur_col += width
	if s.cur_col > s.cols {
		s.cur_col = s.cols
	}
}

screen_escape :: proc(s: ^Screen, data: []u8, i: int) -> int {
	if i + 1 >= len(data) {
		return len(data)
	}
	switch data[i + 1] {
	case '[':
		j := i + 2
		for j < len(data) && !(data[j] >= 0x40 && data[j] <= 0x7e) {
			j += 1
		}
		if j >= len(data) {
			return len(data)
		}
		final := data[j]
		p := parse_csi_params(data[i + 2:j])
		screen_csi(s, &p, final)
		return j + 1
	case ']':
		j := i + 2
		for j < len(data) {
			if data[j] == 0x07 {
				return j + 1
			}
			if data[j] == 0x1b && j + 1 < len(data) && data[j + 1] == '\\' {
				return j + 2
			}
			j += 1
		}
		return len(data)
	case:
		return i + 2
	}
}

screen_csi :: proc(s: ^Screen, p: ^Csi_Params, final: u8) {
	n := 1
	if p.count > 0 {
		n = p.nums[0]
	}
	switch final {
	case 'A':
		s.cur_row = max(0, s.cur_row - max(n, 1))
	case 'B':
		s.cur_row += max(n, 1)
		if s.cur_row >= s.rows {
			s.cur_row = s.rows - 1
			screen_scroll(s)
		}
	case 'C':
		s.cur_col = min(s.cols, s.cur_col + max(n, 1))
	case 'D':
		s.cur_col = max(0, s.cur_col - max(n, 1))
	case 'J':
		if n == 0 {
			screen_clear_from(s, s.cur_row, s.cur_col)
		} else if n == 2 {
			screen_clear_from(s, 0, 0)
		}
	case 'K':
		if n == 0 {
			screen_clear_line_from(s, s.cur_row, s.cur_col)
		} else if n == 2 {
			screen_clear_line_from(s, s.cur_row, 0)
		}
	case:
		// SGR、私有模式等：忽略。
	}
}

screen_clear_from :: proc(s: ^Screen, row, col: int) {
	screen_clear_line_from(s, row, col)
	for r := row + 1; r < s.rows; r += 1 {
		screen_clear_line_from(s, r, 0)
	}
}

screen_clear_line_from :: proc(s: ^Screen, row, col: int) {
	if row < 0 || row >= s.rows {
		return
	}
	for c := max(col, 0); c < s.cols; c += 1 {
		idx := row * s.cols + c
		delete(s.cells[idx].text)
		s.cells[idx] = {}
	}
}

screen_scroll :: proc(s: ^Screen) {
	if s.rows <= 1 {
		screen_clear_line_from(s, 0, 0)
		return
	}
	for c := 0; c < s.cols; c += 1 {
		delete(s.cells[c].text)
	}
	copy(s.cells[:], s.cells[s.cols:])
	for c := 0; c < s.cols; c += 1 {
		idx := (s.rows - 1) * s.cols + c
		s.cells[idx] = {}
	}
}

screen_row_text :: proc(s: ^Screen, row: int) -> string {
	if row < 0 || row >= s.rows {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	for c := 0; c < s.cols; c += 1 {
		cell := s.cells[row * s.cols + c]
		if cell.cont {
			continue
		}
		if len(cell.text) == 0 {
			strings.write_byte(&b, ' ')
		} else {
			strings.write_string(&b, cell.text)
		}
	}
	return strings.trim_right_space(strings.to_string(b))
}

screen_cursor :: proc(s: ^Screen) -> (row, col: int) {
	return s.cur_row, s.cur_col
}
