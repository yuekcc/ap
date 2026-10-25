// 切目录后必须丢弃旧 session 的前端状态：服务器已经清空了 session 指针，
// 旧 transcript 属于旧 project，下一轮会让 ap 新建 session。
// 这里返回一个全新的空状态，只留一条操作提示。
import test from "node:test";
import assert from "node:assert/strict";
import {
	applyEvent,
	createState,
	ingestHistory,
	stateAfterCwdChange,
} from "./render.js";

test("切目录后重置 session 指针、消息与去重游标", () => {
	const before = ingestHistory(createState({ sessionId: "ses_old" }), [
		{ v: 1, seq: 0, ts: 1, type: "session_start", session_id: "ses_old" },
		{ v: 1, seq: 1, ts: 2, type: "user_message", content: "old prompt" },
		{
			v: 1,
			seq: 2,
			ts: 3,
			type: "message_end",
			message_id: "m1",
			role: "assistant",
			content: [{ type: "text", text: "old answer" }],
		},
	]);
	assert.equal(before.sessionId, "ses_old");
	assert.equal(before.lastSeq, 2);
	assert.ok(before.items.length >= 2);

	const after = stateAfterCwdChange();
	assert.equal(after.sessionId, null);
	assert.equal(after.lastSeq, 0);
	assert.equal(after.running, false);
	assert.deepEqual(after.messages, {});
	assert.deepEqual(after.tools, {});
	assert.equal(after.items.length, 1);
	assert.equal(after.items[0].kind, "notice");
	assert.match(after.items[0].text, /已切换工作目录，请新建会话/);

	// 重置后第一条新事件从新 session 开始，不会与旧 transcript 的 seq 冲突。
	const next = applyEvent(after, {
		v: 1,
		seq: 1,
		ts: 10,
		type: "session_start",
		session_id: "ses_new",
	});
	assert.equal(next.sessionId, "ses_new");
	assert.equal(next.lastSeq, 1);
});
