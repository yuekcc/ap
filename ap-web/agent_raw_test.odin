package main

import "core:strings"
import "core:testing"

Raw_Record :: struct {
	count: int,
	raw:   string,
	typ:   string,
}

record_raw_line :: proc(user: rawptr, ev: Event, raw: string) {
	rec := (^Raw_Record)(user)
	rec.count += 1
	rec.raw = strings.clone(raw, context.allocator)
	rec.typ = strings.clone(ev.type, context.allocator)
}

// runner 需要把 ap 的原始 JSON 行直接转发给浏览器；结构体重新序列化会丢字段，
// 所以事件回调额外带一份原始行（只在回调期间有效）。
@(test)
test_pump_forwards_raw_line_untouched :: proc(t: ^testing.T) {
	state: Pump_State
	defer delete(state.stderr_log)

	rec: Raw_Record
	defer {
		delete(rec.raw)
		delete(rec.typ)
	}
	callbacks := Turn_Callbacks {
		user         = &rec,
		on_event_line = record_raw_line,
	}
	ctx := Pump_Context {
		callbacks = &callbacks,
		state     = &state,
	}

	line := `{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_x","future_field":{"nested":true}}`
	on_agent_stdout_line(&ctx, line)

	testing.expect_value(t, rec.count, 1)
	testing.expect_value(t, rec.typ, "session_start")
	testing.expect_value(t, rec.raw, line)
}
