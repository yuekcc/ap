package main

import "core:strings"
import "core:testing"

Recorded_Event :: struct {
	count: int,
	typ:   string,
	text:  string,
}

record_event :: proc(user: rawptr, ev: Event) {
	rec := (^Recorded_Event)(user)
	rec.count += 1
	rec.typ = strings.clone(ev.type)
	if text, ok := ev.delta.text.?; ok {
		rec.text = strings.clone(text)
	}
}

Recorded_Stderr :: struct {
	count: int,
	last:  string,
}

record_stderr :: proc(user: rawptr, line: string) {
	rec := (^Recorded_Stderr)(user)
	rec.count += 1
	rec.last = line
}

@(test)
test_pump_forwards_events_and_captures_session :: proc(t: ^testing.T) {
	state: Pump_State
	defer if len(state.session_id) > 0 {
		delete(state.session_id, context.allocator)
	}

	rec: Recorded_Event
	defer {
		if len(rec.text) > 0 {
			delete(rec.text, context.allocator)
		}
		if len(rec.typ) > 0 {
			delete(rec.typ, context.allocator)
		}
	}
	callbacks := Turn_Callbacks {
		user     = &rec,
		on_event = record_event,
	}
	ctx := Pump_Context {
		callbacks = &callbacks,
		state     = &state,
	}

	on_agent_stdout_line(&ctx, `{"v":1,"seq":0,"ts":1,"type":"session_start","session_id":"ses_x"}`)
	on_agent_stdout_line(&ctx, `{"type":"message_update","message_id":"m1","delta":{"text":"hi"}}`)
	on_agent_stdout_line(&ctx, `not json`)

	testing.expect_value(t, rec.count, 2)
	testing.expect_value(t, state.session_id, "ses_x")
	testing.expect_value(t, rec.typ, "message_update")
	testing.expect_value(t, rec.text, "hi")
}

@(test)
test_pump_caches_and_forwards_stderr :: proc(t: ^testing.T) {
	state: Pump_State
	defer delete(state.stderr_log)

	rec: Recorded_Stderr
	callbacks := Turn_Callbacks {
		user      = &rec,
		on_stderr = record_stderr,
	}
	ctx := Pump_Context {
		callbacks = &callbacks,
		state     = &state,
	}

	on_agent_stderr_line(&ctx, "ap: warning: one")
	on_agent_stderr_line(&ctx, "ap: error: two")

	testing.expect_value(t, rec.count, 2)
	testing.expect_value(t, rec.last, "ap: error: two")
	testing.expect_value(t, string(state.stderr_log[:]), "ap: warning: one\nap: error: two\n")
}
