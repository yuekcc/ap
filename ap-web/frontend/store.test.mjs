// store 不依赖 DOM：直接喂事件和偏好，断言信号、派生值和批量语义。
// 这里是「事件 → 视图状态」之外的第二层：signal 发布、派生、不可变更新。
import test from "node:test";
import assert from "node:assert/strict";
import { effect } from "alien-signals";
import { createStore } from "./store.js";

const DAY_MS = 24 * 60 * 60 * 1000;

test("handleEvents 一批增量只发布一次，effect 一帧只跑一次", () => {
	const store = createStore();
	let runs = 0;
	const stop = effect(() => {
		store.items();
		runs += 1;
	});
	assert.equal(runs, 1, "effect 挂载时先跑一次");

	store.handleEvents([
		{ type: "message_start", message_id: "m1" },
		{ type: "message_update", message_id: "m1", delta: { text: "你" } },
		{ type: "message_update", message_id: "m1", delta: { text: "好" } },
	]);

	assert.equal(runs, 2, "同一批里的两次 delta 只触发一次 effect");
	assert.equal(store.items().length, 1);
	assert.equal(store.items()[0].text, "你好");
	stop();
});

test("turn_done 与增量分开提交，但一次 action 只 flush 一次", () => {
	const store = createStore();
	let runs = 0;
	const stop = effect(() => {
		store.items();
		store.running();
		runs += 1;
	});

	store.handleEvents([{ type: "turn_start", turn: 1 }]);
	store.handleEvents([{ type: "message_start", message_id: "m1" }]);
	store.handleTurnDone({ exit_code: 0, stop_reason: "stop" });

	assert.equal(store.running(), false);
	assert.equal(store.items().length, 0, "正常结束不额外加 notice");
	// 初始一次 + turn_start 一次 + turn_done 一次；message_start 只改
	// hadDelta，不产生可见状态，所以不触发依赖 items/running 的 effect。
	assert.equal(runs, 3);
	stop();
});

test("标题、用量与状态由 transcript 投影派生", () => {
	const store = createStore();
	assert.equal(store.currentTitle(), "新会话");

	store.setConfig({ model: "gpt-test", agent: "coder" });
	store.ingest(
		[
			{ type: "session_start", session_id: "ses_20260101_120000_abcdef" },
			{ type: "session_title", session_id: "ses_20260101_120000_abcdef", title: "重构前端" },
			{
				type: "turn_end",
				stop_reason: "stop",
				usage: { input_tokens: 1200, output_tokens: 300, total_tokens: 1500 },
			},
		],
		"ses_20260101_120000_abcdef",
	);

	assert.equal(store.currentTitle(), "重构前端");
	assert.equal(store.usageLabel(), "1.5k tokens");
	assert.match(store.usageTitle(), /gpt-test/);
	assert.match(store.usageTitle(), /agent coder/);
	assert.match(store.usageTitle(), /输入 1200/);

	store.setConnection("open");
	assert.equal(store.statusKind(), "idle");
	assert.equal(store.statusLabel(), "空闲");
	store.setRunning(true);
	assert.equal(store.statusKind(), "running");
	store.setCancelling(true);
	assert.equal(store.statusKind(), "cancelling");
	store.setCancelling(false);
	store.setRunning(false);
	store.setConnection("reconnecting");
	assert.equal(store.statusKind(), "reconnecting");
});

test("工作空间、会话与时间分组跟随 projectCwd 和排序偏好", () => {
	const store = createStore();
	const now = Date.now();
	store.setProjects([
		{
			cwd: "/work/beta",
			sessions: [{ session_id: "ses_b", ts: now - 2 * DAY_MS, title: "Beta" }],
		},
		{
			cwd: "/work/alpha",
			sessions: [{ session_id: "ses_a", ts: now - 1000, title: "Alpha" }],
		},
	]);

	assert.deepEqual(
		store.workspaceProjects().map((project) => project.cwd),
		["/work/alpha", "/work/beta"],
		"默认按最近活动排序",
	);
	store.setSortOrder("name");
	assert.deepEqual(
		store.workspaceProjects().map((project) => project.cwd),
		["/work/alpha", "/work/beta"],
		"名称排序：alpha 在 beta 前",
	);

	store.setProjectCwd("/work/beta");
	assert.equal(store.activeProject().cwd, "/work/beta");
	assert.deepEqual(store.activeSessions().map((session) => session.session_id), ["ses_b"]);
	assert.deepEqual(store.sessionGroups().map((group) => group.key), ["week"]);

	store.setProjectCwd("/work/alpha");
	assert.deepEqual(store.sessionGroups().map((group) => group.key), ["today"]);
	assert.equal(store.sortedSessions()[0].session_id, "ses_a");
	assert.equal(store.sortLabel(), "名称");

	// 新选的目录还没落盘：本地合成一个空组，按最近活动排在最后。
	store.setSortOrder("recent");
	store.setProjectCwd("/work/new");
	assert.deepEqual(
		store.workspaceProjects().map((project) => project.cwd),
		["/work/alpha", "/work/beta", "/work/new"],
	);
	assert.ok(store.activeProject(), "当前目录即使没有 session 也在列表里");
});

test("当前修改的文件取最后一条带 path 的工具条目", () => {
	const store = createStore();
	store.handleEvents([
		{ type: "tool_execution_start", tool_call_id: "t1", name: "bash", args: { command: "ls" } },
		{
			type: "tool_execution_start",
			tool_call_id: "t2",
			name: "write_file",
			args: { file_path: "/repo/src/app.js" },
		},
	]);
	assert.equal(store.currentFile(), "/repo/src/app.js");
	assert.equal(store.currentFileName(), "app.js");
	assert.equal(store.items()[1].kind, "tool");
});

test("syncCurrent 同步运行态与 turn，setSession 清掉旧标题", () => {
	const store = createStore();
	store.setProjectCwd("/repo");
	store.ingest(
		[
			{ type: "session_start", session_id: "ses_a" },
			{ type: "session_title", title: "旧标题" },
		],
		"ses_a",
	);
	assert.equal(store.title(), "旧标题");

	store.syncCurrent({ session_id: "ses_a", running: true, turn: 3 });
	assert.equal(store.running(), true);
	assert.equal(store.thinking(), true);
	assert.equal(store.turn(), 3);

	store.setSession("ses_a");
	assert.equal(store.title(), "", "换 session 先清标题，等 history 补回来");

	store.syncCurrent({ session_id: "ses_b", cwd: "/elsewhere", running: false });
	assert.equal(store.sessionId(), "ses_b");
	assert.equal(store.projectCwd(), "/elsewhere");
	assert.equal(store.running(), false);
	assert.equal(store.thinking(), false);
});

test("session_start 换 id 时重置 transcript，但保留运行态", () => {
	const store = createStore();
	store.ingest([{ type: "session_start", session_id: "ses_a" }], "ses_a");
	store.addUser("旧会话的一轮");
	store.setRunning(true);
	assert.equal(store.items().length, 1);

	store.handleEvents([{ type: "session_start", session_id: "ses_b" }]);

	assert.equal(store.sessionId(), "ses_b");
	assert.equal(store.running(), true, "交接后正在跑的 turn 不能闪成空闲");
	assert.ok(store.items().every((item) => item.kind === "notice"));
});

test("mergeHistory 按 seq 去重，并跳过已经本地回显的 user_message", () => {
	const store = createStore();
	store.ingest([{ type: "session_start", session_id: "ses_a", seq: 1 }], "ses_a");
	assert.equal(store.lastSeq(), 1);

	store.mergeHistory([
		{
			type: "message_end",
			seq: 2,
			message_id: "m1",
			content: [{ type: "text", text: "重放" }],
		},
		{
			type: "message_end",
			seq: 2,
			message_id: "m2",
			content: [{ type: "text", text: "同 seq 的重放" }],
		},
		{ type: "user_message", seq: 3, content: "用户输入" },
	]);

	assert.equal(store.items().length, 1);
	assert.equal(store.items()[0].text, "重放");
	assert.equal(store.lastSeq(), 3, "user_message 跳过内容，但 seq 要推进");
});

test("setSessionTitle 替换数组与 session 对象，旧引用不被改写", () => {
	const store = createStore();
	store.setProjects([
		{
			cwd: "/repo",
			sessions: [{ session_id: "ses_a", title: "旧标题" }],
		},
	]);
	const beforeProjects = store.projects();
	const beforeSession = beforeProjects[0].sessions[0];

	let runs = 0;
	const stop = effect(() => {
		store.projects();
		runs += 1;
	});
	const mountedRuns = runs;

	store.setSessionTitle("ses_a", "新标题");

	const afterProjects = store.projects();
	assert.notEqual(afterProjects, beforeProjects, "projects 数组必须换新");
	assert.notEqual(afterProjects[0].sessions, beforeProjects[0].sessions, "sessions 数组必须换新");
	assert.notEqual(afterProjects[0].sessions[0], beforeSession, "session 对象必须换新");
	assert.equal(afterProjects[0].sessions[0].title, "新标题");
	assert.equal(beforeSession.title, "旧标题", "旧引用保持原值");
	assert.ok(runs > mountedRuns, "订阅者能收到通知");
	stop();
});

test("标题相同或 session 不认识时不制造新引用", () => {
	const store = createStore();
	store.setProjects([{ cwd: "/repo", sessions: [{ session_id: "ses_a", title: "同一个" }] }]);
	const before = store.projects();
	store.setSessionTitle("ses_a", "同一个");
	assert.equal(store.projects(), before);
	store.setSessionTitle("ses_missing", "别的");
	assert.equal(store.projects(), before);
});

test("requestFocus / requestScroll 只递增请求计数器", () => {
	const store = createStore();
	const draftBefore = store.draft();
	const focusBefore = store.focusNonce();
	store.requestFocus();
	assert.equal(store.focusNonce(), focusBefore + 1);
	assert.equal(store.draft(), draftBefore);

	const first = store.scrollRequest();
	store.requestScroll();
	const second = store.scrollRequest();
	assert.equal(second.nonce, first.nonce + 1);
	assert.equal(second.force, false);
	store.requestScroll(true);
	const third = store.scrollRequest();
	assert.equal(third.nonce, second.nonce + 1);
	assert.equal(third.force, true);
});

test("侧栏可见性与遮罩由布局档位决定", () => {
	const store = createStore();
	assert.equal(store.layoutMode(), "wide");
	assert.equal(store.railVisible(), true);
	assert.equal(store.sessionsVisible(), true);
	assert.equal(store.overlayOpen(), false);

	store.setLayoutMode("narrow");
	assert.equal(store.railVisible(), false);
	assert.equal(store.sessionsVisible(), true, "窄屏的对话栏仍是内联的");
	store.setRailOpen(true);
	assert.equal(store.railVisible(), true);
	assert.equal(store.overlayOpen(), true);

	store.setLayoutMode("compact");
	store.setSessionsOpen(true);
	assert.equal(store.sessionsVisible(), true);
	assert.equal(store.overlayOpen(), true);

	store.setLayoutMode("wide");
	assert.equal(store.overlayOpen(), false);
	assert.equal(store.railVisible(), true);
});

test("草稿会话与空状态互斥", () => {
	// 还没有工作空间：既没有占位会话，也没有对话，显示空状态。
	const store = createStore();
	assert.equal(store.showsDraftSession(), false);
	assert.equal(store.showsEmptySessions(), true);

	// 当前工作空间还没有落盘 session：占位会话顶替空状态。
	store.setProjects([{ cwd: "/repo", sessions: [] }]);
	store.setProjectCwd("/repo");
	assert.equal(store.showsDraftSession(), true);
	assert.equal(store.showsEmptySessions(), false);

	// 当前 session 已经在列表里：占位会话收起，列表有真实条目。
	store.setProjects([{ cwd: "/repo", sessions: [{ session_id: "ses_a", title: "A" }] }]);
	store.setSession("ses_a");
	assert.equal(store.showsDraftSession(), false);
	assert.equal(store.showsEmptySessions(), false);

	// 新目录还没落盘：本地合成的空 project 仍然给出占位会话。
	store.setProjectCwd("/missing");
	assert.equal(store.showsDraftSession(), true);
	assert.equal(store.showsEmptySessions(), false);
});
