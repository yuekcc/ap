// controller 的会话切换语义：新 history 到达前保留旧 transcript，失败才清空。
// 这里用注入的假 api / stream，不碰网络，也不依赖 DOM。
import test from "node:test";
import assert from "node:assert/strict";
import { createController } from "./controller.js";
import { createStore } from "./store.js";

function deferred() {
	let resolve;
	let reject;
	const promise = new Promise((onResolve, onReject) => {
		resolve = onResolve;
		reject = onReject;
	});
	return { promise, resolve, reject };
}

function tick() {
	return new Promise((resolve) => setTimeout(resolve, 0));
}

function createHarness(store, history) {
	const controller = createController(store, {
		api: {
			currentSession: async () => ({}),
			resumeSession: async (sessionId, cwd) => ({
				session_id: sessionId,
				session_key: sessionId,
				cwd,
			}),
			history,
			projects: async () => [],
			config: async () => ({}),
			cwd: async () => ({ cwd: "/repo" }),
		},
		streams: () => ({ close() {} }),
	});
	return controller;
}

function seedOldSession(store) {
	store.ingest(
		[
			{ type: "session_start", session_id: "ses_old", seq: 1 },
			{ type: "user_message", content: "旧消息", seq: 2 },
		],
		"ses_old",
	);
	store.setProjectCwd("/repo");
}

test("切换 session 时保留旧 transcript，history 到达后一次替换", async () => {
	const store = createStore();
	seedOldSession(store);
	assert.deepEqual(store.items().map((item) => item.text), ["旧消息"]);

	const history = deferred();
	const controller = createHarness(store, () => history.promise);
	const opening = controller.openSession("ses_new", "/repo", {
		reloadProjects: false,
	});

	// resumeSession 已返回、history 还在飞：会话指针切了，画面仍是旧内容。
	await tick();
	assert.equal(store.sessionId(), "ses_new");
	assert.deepEqual(
		store.items().map((item) => item.text),
		["旧消息"],
		"history 到达前不能把消息区清空成空状态",
	);

	history.resolve({
		events: [
			{ type: "session_start", session_id: "ses_new", seq: 1 },
			{ type: "user_message", content: "新消息", seq: 2 },
		],
	});
	await opening;

	assert.equal(store.sessionId(), "ses_new");
	assert.deepEqual(store.items().map((item) => item.text), ["新消息"]);
	assert.equal(store.projectCwd(), "/repo");
});

test("history 读取失败时清空旧 transcript，错误落成 notice", async () => {
	const store = createStore();
	seedOldSession(store);

	const history = deferred();
	const controller = createHarness(store, () => history.promise);
	const opening = controller.openSession("ses_new", "/repo", {
		reloadProjects: false,
	});
	await tick();

	history.reject(new Error("missing transcript"));
	await opening;

	assert.equal(store.sessionId(), "ses_new");
	assert.deepEqual(
		store.items().map((item) => item.kind),
		["notice"],
		"不能把上一个会话的内容留给新会话",
	);
	assert.match(store.items()[0].text, /读取历史失败/);
	assert.equal(store.items()[0].tone, "error");
});
