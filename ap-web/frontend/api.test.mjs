// api.js 的纯请求构造：session_key 必须进入 turn body，SSE 需要按 session 过滤。
// 运行：node --test frontend/api.test.mjs
import test from "node:test";
import assert from "node:assert/strict";

import { cwdPath, eventsUrl, turnBody } from "./api.js";

test("turnBody 透传 session_key 与 cwd，空值不写进请求体", () => {
	assert.deepEqual(
		turnBody({ prompt: "hi", session_key: "web_new_1", cwd: "/work/a" }),
		{
			prompt: "hi",
			session_key: "web_new_1",
			cwd: "/work/a",
		},
	);
	assert.deepEqual(
		turnBody({ prompt: "hi", session_key: "", cwd: "", model: "", max_steps: 3 }),
		{
			prompt: "hi",
			max_steps: 3,
		},
	);
});

test("eventsUrl 按 session_key 过滤，空 key 保持旧的全量订阅", () => {
	assert.equal(eventsUrl("web_new_1"), "/api/events?session_key=web_new_1");
	assert.equal(eventsUrl("ses a&b"), "/api/events?session_key=ses%20a%26b");
	assert.equal(eventsUrl(), "/api/events");
	assert.equal(eventsUrl("   "), "/api/events");
});

test("cwdPath 把工作目录编码进已有 query", () => {
	assert.equal(cwdPath("/api/sessions", "/work/a"), "/api/sessions?cwd=%2Fwork%2Fa");
	assert.equal(
		cwdPath("/api/history?session_id=ses_1", "C:\\work\\a"),
		"/api/history?session_id=ses_1&cwd=C%3A%5Cwork%5Ca",
	);
	assert.equal(cwdPath("/api/history?session_id=ses_1", ""), "/api/history?session_id=ses_1");
});
