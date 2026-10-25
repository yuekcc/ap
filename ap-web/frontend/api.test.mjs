// api.js 的纯请求构造：session_key 必须进入 turn body，SSE 需要按 session 过滤。
// 运行：node --test frontend/api.test.mjs
import test from "node:test";
import assert from "node:assert/strict";

import { eventsUrl, turnBody } from "./api.js";

test("turnBody 透传 session_key，空值不写进请求体", () => {
	assert.deepEqual(turnBody({ prompt: "hi", session_key: "web_new_1" }), {
		prompt: "hi",
		session_key: "web_new_1",
	});
	assert.deepEqual(turnBody({ prompt: "hi", session_key: "", model: "", max_steps: 3 }), {
		prompt: "hi",
		max_steps: 3,
	});
});

test("eventsUrl 按 session_key 过滤，空 key 保持旧的全量订阅", () => {
	assert.equal(eventsUrl("web_new_1"), "/api/events?session_key=web_new_1");
	assert.equal(eventsUrl("ses a&b"), "/api/events?session_key=ses%20a%26b");
	assert.equal(eventsUrl(), "/api/events");
	assert.equal(eventsUrl("   "), "/api/events");
});
