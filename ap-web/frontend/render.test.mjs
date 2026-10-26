// render.js 的纯函数验证：不依赖浏览器、Alpine 或任何第三方测试框架。
// 运行：node --test frontend/render.test.mjs
import test from "node:test";
import assert from "node:assert/strict";

import {
	applyEvent,
	applyTurnDone,
	createState,
	formatArgs,
	ingestHistory,
	previewContent,
	projectName,
	sessionMeta,
	sessionTitle,
	truncateUtf8,
} from "./render.js";

const ev = (type, fields = {}) => ({ type, ...fields });

test("会话列表标题取 id 里的日期时间，元信息带短 id 与轮数", () => {
	const session = { session_id: "ses_20261022_120000_abcdef123456", turns: 3 };
	assert.equal(sessionTitle(session), "10-22 12:00");
	assert.equal(sessionMeta(session), "abcdef12 · 3 轮");
	assert.equal(sessionMeta({ ...session, running: true }), "abcdef12 · 3 轮 · 运行中");
	// 不符合命名规则时原样回退，不伪造日期。
	assert.equal(sessionTitle({ session_id: "custom" }), "custom");
	assert.equal(sessionMeta({ session_id: "custom" }), "custom · 0 轮");
	assert.equal(sessionTitle({}), "会话");
});

test("侧栏 project 名称取工作目录最后一段，兼容 Windows 分隔符", () => {
	assert.equal(projectName("/home/me/projects/ap"), "ap");
	assert.equal(projectName("z:/projects/ap/"), "ap");
	assert.equal(projectName("C:\\Users\\me\\code\\ap"), "ap");
	assert.equal(projectName(""), "工作目录");
});

test("formatArgs 对齐 ap-tui：键排序、字符串不加引号、整体限 240 字节", () => {
	assert.equal(
		formatArgs({ file_path: "ap/main.odin", limit: 20, ok: true }),
		"file_path=ap/main.odin, limit=20, ok=true",
	);
	const long = formatArgs({ text: "x".repeat(400) });
	assert.equal(new TextEncoder().encode(long).length, 240);
});

test("truncateUtf8 不切开多字节字符", () => {
	const { text, truncated } = truncateUtf8("你好", 4); // 6 字节，切到 4 不合法，应回退到 3
	assert.equal(text, "你");
	assert.equal(truncated, true);
	assert.equal(new TextEncoder().encode(text).length, 3);
});

test("previewContent 先按 200 行截断，再按 20000 字节截断", () => {
	const lines = Array.from({ length: 300 }, (_, i) => `line ${i + 1}`).join("\n");
	const byLines = previewContent(lines);
	assert.equal(byLines.truncated, true);
	assert.equal(byLines.text.split("\n").length - 1, 200); // 保留 200 个换行
	assert.ok(byLines.text.endsWith("\n"));

	const huge = previewContent("a".repeat(30000));
	assert.equal(huge.truncated, true);
	assert.equal(new TextEncoder().encode(huge.text).length, 20000);
});

test("live：message_update 累积 delta，message_end 不再重复全文", () => {
	let state = createState();
	state = applyEvent(state, ev("message_start", { seq: 1, message_id: "m1" }));
	state = applyEvent(
		state,
		ev("message_update", { message_id: "m1", delta: { text: "hello " } }),
	);
	state = applyEvent(
		state,
		ev("message_update", { message_id: "m1", delta: { reasoning: "不应该出现" } }),
	);
	state = applyEvent(
		state,
		ev("message_update", { message_id: "m1", delta: { text: "world" } }),
	);
	state = applyEvent(
		state,
		ev("message_end", {
			seq: 2,
			message_id: "m1",
			content: [{ type: "text", text: "hello world" }],
		}),
	);

	const assistants = state.items.filter((item) => item.kind === "assistant");
	assert.equal(assistants.length, 1);
	assert.equal(assistants[0].text, "hello world");
	assert.equal(assistants[0].ended, true);
	assert.equal(state.items.some((item) => item.kind === "notice"), false);
});

test("live：没有 delta 时用 message_end 的 text blocks 补全文", () => {
	let state = createState();
	state = applyEvent(
		state,
		ev("message_end", {
			seq: 1,
			message_id: "m2",
			content: [
				{ type: "text", text: "fallback" },
				{ type: "tool_use" },
				{ type: "text", text_preview: " text" },
			],
		}),
	);
	assert.equal(state.items[0].kind, "assistant");
	assert.equal(state.items[0].text, "fallback text");
});

test("history：user_message 展示，message_update 忽略，message_end 总是取全文", () => {
	let state = createState();
	state = ingestHistory(state, [
		ev("user_message", { seq: 1, content: "你好" }),
		ev("message_update", { message_id: "m1", delta: { text: "不该出现" } }),
		ev("message_end", {
			seq: 2,
			message_id: "m1",
			content: [{ type: "text", text: "历史回答" }],
		}),
	]);
	assert.deepEqual(
		state.items.map((item) => [item.kind, item.text]),
		[
			["user", "你好"],
			["assistant", "历史回答"],
		],
	);
	assert.equal(state.lastSeq, 2);
});

test("live：user_message 不再回显（prompt 已由界面自己加过）", () => {
	let state = createState();
	state = applyEvent(state, ev("user_message", { seq: 1, content: "重复" }));
	assert.equal(state.items.length, 0);
});

test("工具卡片：start 建卡、update 增量、end 标 ✓/耗时/退出码且不重复结果", () => {
	let state = createState();
	state = applyEvent(
		state,
		ev("tool_execution_start", {
			seq: 3,
			tool_call_id: "c1",
			name: "bash",
			args: { cmd: "ls", ok: true },
		}),
	);
	state = applyEvent(
		state,
		ev("tool_execution_update", { tool_call_id: "c1", chunk: "a.txt\n" }),
	);
	state = applyEvent(
		state,
		ev("tool_execution_update", { tool_call_id: "c1", chunk: "b.txt\n" }),
	);
	state = applyEvent(
		state,
		ev("tool_execution_end", {
			seq: 4,
			tool_call_id: "c1",
			ok: true,
			content: "完整结果不应覆盖流式输出",
			duration_ms: 42,
			exit_code: 0,
		}),
	);

	const tool = state.items.find((item) => item.kind === "tool");
	assert.equal(tool.name, "bash");
	assert.equal(tool.args, "cmd=ls, ok=true");
	assert.equal(tool.streamed, "a.txt\nb.txt\n");
	assert.equal(tool.result, "");
	assert.equal(tool.status, "ok");
	assert.equal(tool.durationMs, 42);
	assert.equal(tool.exitCode, 0);
});

test("工具卡片：非流式结果超 200 行时截断并提示", () => {
	let state = createState();
	state = applyEvent(
		state,
		ev("tool_execution_start", { seq: 1, tool_call_id: "c2", name: "read" }),
	);
	const content = Array.from({ length: 260 }, (_, i) => `row ${i}`).join("\n");
	state = applyEvent(
		state,
		ev("tool_execution_end", {
			seq: 2,
			tool_call_id: "c2",
			ok: true,
			content,
		}),
	);
	const tool = state.items.find((item) => item.kind === "tool");
	assert.equal(tool.truncated, true);
	assert.equal(tool.result.split("\n").length - 1, 200);
});

test("工具卡片：history 只给 content_preview 时也标记截断", () => {
	let state = createState();
	state = applyEvent(
		state,
		ev("tool_execution_start", { seq: 1, tool_call_id: "c4", name: "read" }),
	);
	state = applyEvent(
		state,
		ev("tool_execution_end", {
			seq: 2,
			tool_call_id: "c4",
			ok: true,
			content: null,
			content_preview: "前 8KB…",
			content_bytes: 123456,
		}),
	);
	const tool = state.items.find((item) => item.kind === "tool");
	assert.equal(tool.result, "前 8KB…");
	assert.equal(tool.truncated, true);
});

test("已结束的工具卡片忽略重放的流式片段", () => {
	let state = createState();
	state = applyEvent(
		state,
		ev("tool_execution_start", { seq: 1, tool_call_id: "c5", name: "bash" }),
	);
	state = applyEvent(
		state,
		ev("tool_execution_end", { seq: 2, tool_call_id: "c5", ok: true, content: "done" }),
	);
	state = applyEvent(
		state,
		ev("tool_execution_update", { tool_call_id: "c5", chunk: "重放" }),
	);
	const tool = state.items.find((item) => item.kind === "tool");
	assert.equal(tool.streamed, "");
	assert.equal(tool.result, "done");
});

test("工具卡片：失败时标 ✗ 并保留 error", () => {
	let state = createState();
	state = applyEvent(
		state,
		ev("tool_execution_start", { seq: 1, tool_call_id: "c3", name: "bash" }),
	);
	state = applyEvent(
		state,
		ev("tool_execution_end", {
			seq: 2,
			tool_call_id: "c3",
			ok: false,
			error: "boom",
			exit_code: 2,
		}),
	);
	const tool = state.items.find((item) => item.kind === "tool");
	assert.equal(tool.status, "error");
	assert.equal(tool.error, "boom");
	assert.equal(tool.exitCode, 2);
});

test("seq 去重：重复 transcript 事件直接跳过", () => {
	let state = createState();
	const event = ev("message_end", {
		seq: 5,
		message_id: "m1",
		content: [{ type: "text", text: "一次" }],
	});
	state = applyEvent(state, event);
	state = applyEvent(state, event);
	assert.equal(state.items.length, 1);
	assert.equal(state.lastSeq, 5);
});

test("message_end 之后重放的 delta 不会重复追加", () => {
	let state = createState();
	state = applyEvent(
		state,
		ev("message_end", {
			seq: 2,
			message_id: "m1",
			content: [{ type: "text", text: "最终" }],
		}),
	);
	state = applyEvent(
		state,
		ev("message_update", { message_id: "m1", delta: { text: "重放" } }),
	);
	assert.equal(state.items[0].text, "最终");
});

test("error / cancel / turn_end 落成 notice，正常 stop 不打扰", () => {
	let state = createState();
	state = applyEvent(
		state,
		ev("error", { scope: "llm", message: "rate limited", retryable: true }),
	);
	state = applyEvent(state, ev("cancel", { scope: "turn" }));
	state = applyEvent(state, ev("turn_end", { stop_reason: "stop" }));
	state = applyEvent(state, ev("turn_end", { stop_reason: "max_steps" }));

	assert.deepEqual(
		state.items.map((item) => [item.tone, item.text]),
		[
			["warning", "[llm] rate limited"],
			["muted", "cancelled [turn]"],
			["warning", "turn ended: max_steps"],
		],
	);
	assert.equal(state.turnEndedNotice, true);
});

test("turn_done：异常退出带 stderr，正常结束清空 running", () => {
	let state = { ...createState(), running: true };
	state = applyTurnDone(state, {
		exit_code: 0,
		stop_reason: "stop",
		usage: {},
		stderr_preview: null,
	});
	assert.equal(state.running, false);
	assert.equal(state.items.length, 0);

	state = applyTurnDone(
		{ ...state, running: true },
		{ exit_code: 1, stop_reason: null, stderr_preview: "ap: error: boom\n" },
	);
	assert.equal(state.items.length, 1);
	assert.equal(state.items[0].tone, "error");
	assert.match(state.items[0].text, /exit 1/);
	assert.match(state.items[0].text, /boom/);
});

test("turn_done：用户取消不算失败，也不把 stderr 当成错误", () => {
	let state = { ...createState(), running: true };
	state = applyTurnDone(state, {
		exit_code: 1,
		stop_reason: "cancelled",
		usage: {},
		stderr_preview: "[step 1] calling model\n[tool] bash\n",
	});
	assert.equal(state.running, false);
	assert.equal(state.items.length, 1);
	assert.equal(state.items[0].tone, "muted");
	assert.equal(state.items[0].text, "cancelled");
});

test("turn_end：cancelled 落成静默提示，不显示 turn ended warning", () => {
	let state = createState();
	state = applyEvent(state, ev("turn_end", { seq: 1, stop_reason: "cancelled" }));
	assert.deepEqual(
		state.items.map((item) => [item.tone, item.text]),
		[["muted", "cancelled"]],
	);
	// 之后到达的 turn_done 不应再追加第二条 notice。
	state = applyTurnDone(state, { exit_code: 1, stop_reason: "cancelled" });
	assert.equal(state.items.length, 1);
});

test("history：turn_start 不把 UI 状态改成运行中（running 以 /api/session/current 为准）", () => {
	let state = createState();
	state = ingestHistory(state, [
		ev("turn_start", { seq: 1, turn: 1 }),
		ev("turn_end", { seq: 2, turn: 1, stop_reason: "stop" }),
	]);
	assert.equal(state.running, false);
	assert.equal(state.turn, 0);
});

test("session_start 更新当前 session", () => {
	let state = createState();
	state = applyEvent(state, ev("session_start", { seq: 1, session_id: "ses_1" }));
	assert.equal(state.sessionId, "ses_1");
	assert.equal(state.lastSeq, 1);
});
