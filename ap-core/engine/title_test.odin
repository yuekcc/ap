package engine

import "../platform"

import "core:encoding/json"
import "core:strings"
import "core:testing"

// ---- 标题清洗 ----

@(test)
test_title_sanitize_strips_labels_and_punctuation :: proc(t: ^testing.T) {
	cases := []struct {
		raw:     string,
		expects: string,
	} {
		{"修复 ap-web 侧栏标题", "修复 ap-web 侧栏标题"},
		{"标题：修复 ap-web 侧栏标题。", "修复 ap-web 侧栏标题"},
		{"**修复 ap-web 侧栏标题**", "修复 ap-web 侧栏标题"},
		{"「修复 ap-web 侧栏标题」", "修复 ap-web 侧栏标题"},
		{"# 修复 ap-web 侧栏标题！", "修复 ap-web 侧栏标题"},
		{"Title: fix sidebar titles", "fix sidebar titles"},
		{"  \n\n修复 ap-web 侧栏标题\n\n上面是标题，下面是解释", "修复 ap-web 侧栏标题"},
		{"给  ap-web\t加   标题", "给 ap-web 加 标题"},
	}
	for c in cases {
		got := title_sanitize(c.raw, context.temp_allocator)
		testing.expectf(t, got == c.expects, "raw %q -> %q, want %q", c.raw, got, c.expects)
	}
}

@(test)
test_title_sanitize_truncates_by_runes :: proc(t: ^testing.T) {
	raw := strings.repeat("中", 100, context.temp_allocator)
	got := title_sanitize(raw, context.temp_allocator)
	count := 0
	for _ in got {
		count += 1
	}
	testing.expect_value(t, count, TITLE_MAX_RUNES)
	testing.expect(t, strings.has_prefix(got, "中中中"))
}

@(test)
test_title_sanitize_empty :: proc(t: ^testing.T) {
	testing.expect_value(t, title_sanitize("   \n\n", context.temp_allocator), "")
	testing.expect_value(t, title_sanitize("。", context.temp_allocator), "")
}

// ---- 生成与事件 ----

@(test)
test_session_title_generate_writes_event :: proc(t: ^testing.T) {
	session, project, dir := handoff_test_session(t, "session-title")
	defer test_cleanup(dir)
	handoff_test_append_user(&session, "给 ap-web 的侧栏生成标题")

	state := Fake_Provider {
		responses = []Fake_Response {
			{text = "标题：侧栏标题生成。", stop = .Stop, usage = Usage{input_tokens = 30, output_tokens = 4}},
		},
	}
	fake_provider_state = &state
	result, err := session_title_generate(&session, new(platform.Cancel_Token), {})
	testing.expect_value(t, err.kind, Error_Kind.None)
	defer session_title_destroy(&result)
	testing.expect_value(t, result.title, "侧栏标题生成")
	testing.expect_value(t, result.usage.input_tokens.?, 30)

	events, _ := transcript_read_all(project, session.session_id)
	titles := make([dynamic]Session_Title_Event, 0, 1)
	for ev in events {
		if ev.type != EVENT_SESSION_TITLE {
			continue
		}
		title: Session_Title_Event
		testing.expect_value(t, json.unmarshal_string(ev.line, &title), nil)
		append(&titles, title)
	}
	testing.expect_value(t, len(titles), 1)
	testing.expect_value(t, titles[0].title, "侧栏标题生成")
	testing.expect_value(t, titles[0].usage.?.input_tokens.?, 30)
	delete(titles)

	// 标题事件计入 session 用量，但不出现在 messages 里。
	testing.expect_value(t, historical_usage_from_events(events).input_tokens.?, 30)
	_, messages, cerr := context_build(project, events)
	testing.expect_value(t, cerr.kind, Error_Kind.None)
	for message in messages {
		text, has_text := message.content.?
		if has_text {
			testing.expect(t, !strings.contains(text, "侧栏标题生成"))
		}
	}
}

@(test)
test_session_title_from_events_uses_last :: proc(t: ^testing.T) {
	session, project, dir := handoff_test_session(t, "session-title-last")
	defer test_cleanup(dir)
	for value in ([]string{"第一版", "第二版"}) {
		header := make_header(&session.store, EVENT_SESSION_TITLE)
		_, err := transcript_append_line(&session.store, Session_Title_Event{header = header, title = value})
		testing.expect_value(t, err.kind, Error_Kind.None)
	}
	events, _ := transcript_read_all(project, session.session_id)
	title, ok := session_title_from_events(events)
	testing.expect(t, ok)
	testing.expect_value(t, title, "第二版")
}

@(test)
test_session_title_generate_without_user_message_fails :: proc(t: ^testing.T) {
	session, _, dir := handoff_test_session(t, "session-title-empty")
	defer test_cleanup(dir)
	state := Fake_Provider{}
	fake_provider_state = &state
	_, err := session_title_generate(&session, new(platform.Cancel_Token), {})
	testing.expect_value(t, err.kind, Error_Kind.Usage)
}
