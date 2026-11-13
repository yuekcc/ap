package protocol

// wire 取值的唯一权威：事件名、stop_reason、session_end reason、error/cancel
// scope、消息角色与内容块类型。消费者一律引用这里的常量；裸 JSON 测试样例
// 是 wire 格式本身，可以继续写字面量。

// ---- 事件类型 ----

EVENT_SESSION_START :: "session_start"
EVENT_SESSION_END :: "session_end"
EVENT_USER_MESSAGE :: "user_message"
EVENT_TURN_START :: "turn_start"
EVENT_TURN_END :: "turn_end"
EVENT_STEP_START :: "step_start"
EVENT_MESSAGE_START :: "message_start"
EVENT_MESSAGE_UPDATE :: "message_update"
EVENT_MESSAGE_END :: "message_end"
EVENT_TOOL_EXECUTION_START :: "tool_execution_start"
EVENT_TOOL_EXECUTION_UPDATE :: "tool_execution_update"
EVENT_TOOL_EXECUTION_END :: "tool_execution_end"
EVENT_ERROR :: "error"
EVENT_CANCEL :: "cancel"
EVENT_HANDOFF :: "handoff"
EVENT_SESSION_TITLE :: "session_title"

// ---- turn_end / message_end 的 stop_reason ----

STOP_REASON_STOP :: "stop"
STOP_REASON_TOOL_USE :: "tool_use"
STOP_REASON_MAX_TOKENS :: "max_tokens"
STOP_REASON_MAX_STEPS :: "max_steps"
STOP_REASON_CANCELLED :: "cancelled"
STOP_REASON_CONTEXT_TOO_LONG :: "context_too_long"
STOP_REASON_HANDOFF :: "handoff"

// ---- handoff.reason ----

HANDOFF_REASON_BUDGET_EXHAUSTED :: "budget_exhausted"
HANDOFF_REASON_CONTEXT_TOO_LONG :: "context_too_long"
HANDOFF_REASON_MANUAL :: "manual"

// ---- session_end.reason ----

SESSION_END_EXIT :: "exit"
SESSION_END_SIGNAL :: "signal"
SESSION_END_ERROR :: "error"

// ---- error.scope 与 cancel.scope ----

SCOPE_LLM :: "llm"
SCOPE_TOOL :: "tool"
SCOPE_SESSION :: "session"
SCOPE_STEP :: "step"
SCOPE_TURN :: "turn"

// ---- 消息角色 ----

ROLE_SYSTEM :: "system"
ROLE_USER :: "user"
ROLE_ASSISTANT :: "assistant"
ROLE_TOOL :: "tool"

// ---- message_end.content 的块类型 ----

BLOCK_TEXT :: "text"
BLOCK_TOOL_USE :: "tool_use"

// ---- tool_execution_end.error 的取消取值 ----

TOOL_ERROR_CANCELLED :: "cancelled"

// transcript 事件的已知类型集合。恢复时未知类型跳过；新增持久事件类型必须
// 同时登记在这里，否则旧版本恢复会把它当未知事件丢掉。
event_type_known :: proc(typ: string) -> bool {
	switch typ {
	case EVENT_SESSION_START,
	     EVENT_SESSION_END,
	     EVENT_USER_MESSAGE,
	     EVENT_TURN_START,
	     EVENT_TURN_END,
	     EVENT_STEP_START,
	     EVENT_MESSAGE_START,
	     EVENT_MESSAGE_END,
	     EVENT_TOOL_EXECUTION_START,
	     EVENT_TOOL_EXECUTION_END,
	     EVENT_ERROR,
	     EVENT_CANCEL,
	     EVENT_HANDOFF,
	     EVENT_SESSION_TITLE:
		return true
	}
	return false
}

// 把已知类型映射到静态字面量，让 Transcript_Event.type 不需要所有权管理。
// 调用方必须先经 event_type_known 过滤；未知类型原样返回。
event_type_canonical :: proc(typ: string) -> string {
	switch typ {
	case EVENT_SESSION_START:
		return EVENT_SESSION_START
	case EVENT_SESSION_END:
		return EVENT_SESSION_END
	case EVENT_USER_MESSAGE:
		return EVENT_USER_MESSAGE
	case EVENT_TURN_START:
		return EVENT_TURN_START
	case EVENT_TURN_END:
		return EVENT_TURN_END
	case EVENT_STEP_START:
		return EVENT_STEP_START
	case EVENT_MESSAGE_START:
		return EVENT_MESSAGE_START
	case EVENT_MESSAGE_END:
		return EVENT_MESSAGE_END
	case EVENT_TOOL_EXECUTION_START:
		return EVENT_TOOL_EXECUTION_START
	case EVENT_TOOL_EXECUTION_END:
		return EVENT_TOOL_EXECUTION_END
	case EVENT_ERROR:
		return EVENT_ERROR
	case EVENT_CANCEL:
		return EVENT_CANCEL
	case EVENT_HANDOFF:
		return EVENT_HANDOFF
	case EVENT_SESSION_TITLE:
		return EVENT_SESSION_TITLE
	}
	return typ
}
