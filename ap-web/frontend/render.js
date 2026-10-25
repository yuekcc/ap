// 事件 → 视图模型。规则复刻 ap-tui/render.odin，但输出纯数据，不碰 DOM：
// store.js 只负责把结果同步进 Alpine reactive 对象，测试可以直接喂事件断言。
//
// 关键规则（docs/web.md「前端」、events-notes.md）：
// - message_update 按 delta.text 逐段累积；reasoning 不展示。
// - message_end 只在没有收到过 text delta 时补全文（history 模式则总是取全文）。
// - tool_execution_start 建卡；update 追加流式输出（不截断）；end 标 ✓/✗、
//   耗时/退出码，非流式结果按 200 行 / 20000 字节截断并标记。
// - transcript 事件按 seq 去重；流式事件没有 seq，靠 message ended 状态防重放。

export const MAX_PREVIEW_LINES = 200;
export const MAX_PREVIEW_BYTES = 20000;
export const MAX_ARG_BYTES = 240;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const NORMAL_STOP_REASONS = new Set(["", "stop", "tool_use"]);

// ---------------------------------------------------------------------------
// 纯工具函数
// ---------------------------------------------------------------------------

export function truncateUtf8(text, maxBytes) {
	const value = String(text ?? "");
	if (!(maxBytes > 0)) return { text: value, truncated: false };
	const bytes = encoder.encode(value);
	if (bytes.length <= maxBytes) return { text: value, truncated: false };
	// 从 maxBytes 往回退到 UTF-8 首字节，绝不切开多字节字符（同 ap-tui truncate_utf8）。
	let end = maxBytes;
	while (end > 0 && (bytes[end] & 0xc0) === 0x80) end -= 1;
	return { text: decoder.decode(bytes.subarray(0, end)), truncated: true };
}

export function truncateLines(text, maxLines) {
	const value = String(text ?? "");
	if (!(maxLines > 0)) return { text: value, truncated: false };
	let line = 1;
	for (let i = 0; i < value.length; i += 1) {
		if (value[i] !== "\n") continue;
		line += 1;
		// 保留截断处换行，与 ap-tui 的 text[:i+1] 一致。
		if (line > maxLines) return { text: value.slice(0, i + 1), truncated: true };
	}
	return { text: value, truncated: false };
}

export function previewContent(text) {
	const byLines = truncateLines(text, MAX_PREVIEW_LINES);
	const byBytes = truncateUtf8(byLines.text, MAX_PREVIEW_BYTES);
	return { text: byBytes.text, truncated: byLines.truncated || byBytes.truncated };
}

export function singleLine(text) {
	return String(text ?? "").replace(/[\n\r\t]+/g, " ").trim();
}

function formatArgValue(value) {
	if (value === null || value === undefined) return "null";
	if (typeof value === "string") return singleLine(value);
	if (typeof value === "number" || typeof value === "boolean") return String(value);
	if (Array.isArray(value) || typeof value === "object") return JSON.stringify(value);
	return String(value);
}

// 对齐 ap-tui format_args：对象键排序后输出 key=value, key2=value2；整体截到 240 字节。
export function formatArgs(value) {
	if (value === null || value === undefined) return "";
	if (typeof value === "string") {
		return truncateUtf8(singleLine(value), MAX_ARG_BYTES).text;
	}
	if (typeof value !== "object") {
		return truncateUtf8(singleLine(String(value)), MAX_ARG_BYTES).text;
	}
	if (Array.isArray(value)) {
		return truncateUtf8(JSON.stringify(value), MAX_ARG_BYTES).text;
	}
	const parts = Object.keys(value)
		.sort()
		.map((key) => `${key}=${formatArgValue(value[key])}`);
	return truncateUtf8(singleLine(parts.join(", ")), MAX_ARG_BYTES).text;
}

function blockText(block) {
	if (!block || typeof block !== "object") return "";
	if (typeof block.text === "string") return block.text;
	if (typeof block.text_preview === "string") return block.text_preview;
	return "";
}

export function messageTexts(event) {
	if (!Array.isArray(event?.content)) return [];
	const out = [];
	for (const block of event.content) {
		if (!block || typeof block !== "object" || block.type !== "text") continue;
		const text = blockText(block);
		if (text) out.push(text);
	}
	return out;
}

export function userMessageText(event) {
	return typeof event?.content === "string" ? event.content : "";
}

// history 接口已经把 *_ref 解析成 text/content；没有 blob 时退回 preview。
export function toolArgsText(event) {
	if (typeof event?.args_preview === "string" && event.args_preview.length > 0) {
		return truncateUtf8(singleLine(event.args_preview), MAX_ARG_BYTES).text;
	}
	if (event?.args !== undefined && event?.args !== null) return formatArgs(event.args);
	return "";
}

function inlineContentText(event) {
	if (typeof event?.content === "string") return event.content;
	if (Array.isArray(event?.content)) {
		const text = event.content.map(blockText).join("");
		return text.length > 0 ? text : null;
	}
	if (event?.content && typeof event.content === "object") {
		const text = blockText(event.content);
		if (text) return text;
	}
	return null;
}

export function toolResultText(event) {
	const inline = inlineContentText(event);
	if (inline !== null) return inline;
	if (typeof event?.content_preview === "string") return event.content_preview;
	return "";
}

// ---------------------------------------------------------------------------
// 视图状态
// ---------------------------------------------------------------------------

export function createState(overrides = {}) {
	return {
		items: [],
		messages: {},
		tools: {},
		hadDelta: {},
		lastSeq: 0,
		localIds: 0,
		sessionId: null,
		turn: 0,
		running: false,
		turnEndedNotice: false,
		...overrides,
	};
}

function appendItem(state, item) {
	return { ...state, items: [...state.items, item] };
}

function replaceItem(state, index, item) {
	const items = state.items.slice();
	items[index] = item;
	return { ...state, items };
}

function messageIndex(state, messageId) {
	const index = state.messages[messageId];
	return typeof index === "number" ? index : -1;
}

function addMessage(state, messageId, text, ended) {
	const id = messageId || `anonymous-${state.localIds + 1}`;
	const item = {
		kind: "assistant",
		key: `msg:${id}`,
		messageId: id,
		text,
		ended,
	};
	const next = appendItem(
		{ ...state, localIds: messageId ? state.localIds : state.localIds + 1 },
		item,
	);
	next.messages = { ...state.messages, [id]: next.items.length - 1 };
	return next;
}

function addTool(state, toolId, name, args) {
	const id = toolId || `tool-${state.localIds + 1}`;
	const item = {
		kind: "tool",
		key: `tool:${id}`,
		toolId: id,
		name: name || "tool",
		args: args || "",
		streamed: "",
		result: "",
		status: "running",
		durationMs: null,
		exitCode: null,
		error: "",
		truncated: false,
	};
	const next = appendItem(
		{ ...state, localIds: toolId ? state.localIds : state.localIds + 1 },
		item,
	);
	next.tools = { ...state.tools, [id]: next.items.length - 1 };
	return next;
}

function addNotice(state, text, tone = "muted") {
	const id = state.localIds + 1;
	return appendItem(
		{ ...state, localIds: id },
		{ kind: "notice", key: `notice:${id}`, text, tone, ended: true },
	);
}

export function appendUserMessage(state, text) {
	const id = state.localIds + 1;
	return appendItem(
		{ ...state, localIds: id },
		{ kind: "user", key: `user:${id}`, text, ended: true },
	);
}

export function appendNotice(state, text, tone = "muted") {
	return addNotice(state, text, tone);
}

// ---------------------------------------------------------------------------
// 事件归约
// ---------------------------------------------------------------------------

function applyMessageUpdate(state, event) {
	const text = typeof event?.delta?.text === "string" ? event.delta.text : "";
	if (!text) return state; // reasoning / tool_call delta 在 phase 1 不展示。

	const messageId = event.message_id || "";
	const index = messageIndex(state, messageId);

	let next;
	if (index >= 0) {
		const item = state.items[index];
		if (item.ended) return state; // 重放的 delta 不能污染已收尾的消息。
		next = replaceItem(state, index, { ...item, text: item.text + text });
	} else {
		next = addMessage(state, messageId, text, false);
	}
	return { ...next, hadDelta: { ...state.hadDelta, [messageId]: true } };
}

function applyMessageEnd(state, event, mode) {
	const messageId = event.message_id || "";
	const text = messageTexts(event).join("");
	const hadDelta = state.hadDelta[messageId] === true;
	const index = messageIndex(state, messageId);

	let next = state;
	if (index >= 0) {
		const item = state.items[index];
		// history 是落盘事实，直接以全文为准；live 收到过 delta 就以 delta 为准，只补缺。
		const nextText =
			mode === "history" ? text || item.text : !hadDelta && !item.text ? text : item.text;
		next = replaceItem(state, index, { ...item, text: nextText, ended: true });
	} else if (text) {
		next = addMessage(state, messageId, text, true);
	}

	if (messageId in next.hadDelta) {
		const hadDeltaNext = { ...next.hadDelta };
		delete hadDeltaNext[messageId];
		next = { ...next, hadDelta: hadDeltaNext };
	}
	return next;
}

function applyToolStart(state, event) {
	const toolId = event.tool_call_id || "";
	const index = state.tools[toolId];
	if (typeof index === "number") return state; // 同一 tool_call_id 重放，跳过。
	return addTool(state, toolId, event.name, toolArgsText(event));
}

function applyToolUpdate(state, event) {
	const toolId = event.tool_call_id || "";
	const chunk = typeof event.chunk === "string" ? event.chunk : "";
	if (!chunk) return state;

	let next = state;
	if (typeof state.tools[toolId] !== "number") {
		// 没收到 start（例如刚订阅上来的流）也要有卡片可追加。
		next = addTool(state, toolId, "tool", "");
	}
	const index = next.tools[toolId];
	const item = next.items[index];
	if (item.status !== "running") return next; // 已收尾的卡片不接受重放的流式片段。
	return replaceItem(next, index, { ...item, streamed: item.streamed + chunk });
}

function applyToolEnd(state, event) {
	const toolId = event.tool_call_id || "";
	let next = state;
	if (typeof state.tools[toolId] !== "number") {
		next = addTool(state, toolId, event.name || "tool", "");
	}

	const index = next.tools[toolId];
	const item = next.items[index];
	const content = toolResultText(event);
	// history 接口可能已经把超限结果换成 content_preview；用了它就意味着截断过。
	const usedPreview =
		inlineContentText(event) === null && typeof event.content_preview === "string";
	let result = item.result;
	let truncated = item.truncated;

	// 流式输出已经展示过内容时不再重复；非流式结果只给预览窗口。
	if (event.ok === true && !item.streamed && content) {
		const preview = previewContent(content);
		result = preview.text;
		truncated = preview.truncated || usedPreview;
	}

	return replaceItem(next, index, {
		...item,
		status: event.ok === true ? "ok" : "error",
		durationMs: typeof event.duration_ms === "number" ? event.duration_ms : null,
		exitCode: typeof event.exit_code === "number" ? event.exit_code : null,
		error: typeof event.error === "string" ? event.error : "",
		result,
		truncated,
	});
}

function errorNotice(event) {
	const scope = typeof event.scope === "string" && event.scope ? `[${event.scope}] ` : "";
	const message = typeof event.message === "string" ? event.message : "";
	return `${scope}${message}`;
}

function applyTurnEnd(state, event) {
	const reason = typeof event.stop_reason === "string" ? event.stop_reason : "";
	if (NORMAL_STOP_REASONS.has(reason)) return state;
	return {
		...addNotice(state, `turn ended: ${reason}`, "warning"),
		turnEndedNotice: true,
	};
}

export function applyEvent(state, event, mode = "live") {
	if (!event || typeof event.type !== "string") return state;

	// transcript 事件带 seq；history 与 SSE 重放重叠时以 seq 去重。
	if (typeof event.seq === "number" && event.seq > 0) {
		if (event.seq <= state.lastSeq) return state;
		state = { ...state, lastSeq: event.seq };
	}

	switch (event.type) {
		case "user_message":
			return mode === "history"
				? appendUserMessage(state, userMessageText(event))
				: state;
		case "message_start":
			if (mode !== "live") return state;
			return { ...state, hadDelta: { ...state.hadDelta, [event.message_id || ""]: false } };
		case "message_update":
			return mode === "live" ? applyMessageUpdate(state, event) : state;
		case "message_end":
			return applyMessageEnd(state, event, mode);
		case "tool_execution_start":
			return applyToolStart(state, event);
		case "tool_execution_update":
			return mode === "live" ? applyToolUpdate(state, event) : state;
		case "tool_execution_end":
			return applyToolEnd(state, event);
		case "error":
			return addNotice(
				state,
				errorNotice(event),
				event.retryable === true ? "warning" : "error",
			);
		case "cancel":
			return addNotice(state, `cancelled [${event.scope || ""}]`, "muted");
		case "turn_start":
			if (mode !== "live") return state;
			return {
				...state,
				running: true,
				turn: typeof event.turn === "number" ? event.turn : state.turn,
			};
		case "turn_end":
			return applyTurnEnd(state, event);
		case "session_start":
			return event.session_id
				? { ...state, sessionId: event.session_id }
				: state;
		default:
			return state;
	}
}

export function ingestHistory(state, events) {
	if (!Array.isArray(events)) return state;
	let next = state;
	for (const event of events) next = applyEvent(next, event, "history");
	return next;
}

export function applyTurnDone(state, payload = {}) {
	let next = { ...state, running: false, turnEndedNotice: false };
	const exitCode = typeof payload.exit_code === "number" ? payload.exit_code : 0;

	if (exitCode !== 0) {
		const stderr =
			typeof payload.stderr_preview === "string" ? payload.stderr_preview.trim() : "";
		const text = stderr
			? `turn failed (exit ${exitCode})\n${stderr}`
			: `turn failed (exit ${exitCode})`;
		next = addNotice(next, text, "error");
		return next;
	}

	const reason = typeof payload.stop_reason === "string" ? payload.stop_reason : "";
	if (!NORMAL_STOP_REASONS.has(reason) && !state.turnEndedNotice) {
		next = addNotice(next, `turn ended: ${reason}`, "warning");
	}
	return next;
}
