// 唯一状态源：alien-signals 的 signal / computed，加一组只改信号的 action。
//
// 分层约定：
// - render.js 继续是「事件 → 纯视图状态」的 reducer，这里只负责把结果发布到
//   view 信号，并把 UI 状态放在同一个 store 里；
// - 不碰 DOM、不读 localStorage、不发起请求：那些分别属于 ui/* 和 controller；
// - 信号按引用比较，嵌套数组/对象一律替换，不原地改；
// - 一次改多个信号的 action 走 batch()，一帧只 flush 一次。
import { computed, endBatch, signal, startBatch } from "alien-signals";
import {
	PANEL_DEFAULT_W,
	SORT_ORDERS,
	appendNotice,
	appendUserMessage,
	applyEvent,
	applyTurnDone,
	clampPanelWidth,
	createState,
	fileName,
	formatTokenCount,
	groupSessionsByTime,
	ingestHistory,
	sessionTitle,
	sortProjects,
	sortSessions,
	usageDetailText,
	usageTotal,
} from "./render.js";

function asArray(value) {
	return Array.isArray(value) ? value : [];
}

// 一次铺开多个信号写入：派生值和 DOM effect 在 endBatch 处统一跑一次。
function batch(fn) {
	startBatch();
	try {
		return fn();
	} finally {
		endBatch();
	}
}

export function createStore() {
	// ---- transcript 投影 ----
	// sessionKey 是客户端稳定标识（新会话 slot key 或真实 session id），不属于
	// transcript 视图，reset()/ingest() 都不会丢。
	const view = signal(createState());
	const sessionKey = signal(null);

	// ---- 会话与操作态 ----
	const projects = signal([]);
	const config = signal(null);
	const projectCwd = signal(null);
	const loading = signal(false);
	const picking = signal(false);
	const cancelling = signal(false);
	const titlePending = signal(false);
	const connected = signal("connecting");
	const error = signal("");

	// ---- 输入 ----
	const draft = signal("");

	// ---- 布局 ----
	// railCollapsed 是宽屏下的手动折叠；railOpen / sessionsOpen 是窄屏浮层。
	const railCollapsed = signal(false);
	const railOpen = signal(false);
	const sessionsOpen = signal(false);
	const layoutMode = signal("wide");
	const sortOrder = signal("recent");
	const railWidth = signal(PANEL_DEFAULT_W);
	const sessionsWidth = signal(PANEL_DEFAULT_W);

	// ---- 滚动与焦点 ----
	// UI 不写应用状态：controller 只递增这两个请求计数器，ui/* 自己监听并
	// 在下一帧读 DOM。scroll 的 force 表示「无条件贴底」。
	const atBottom = signal(true);
	const scrollRequest = signal({ nonce: 0, force: false });
	const focusNonce = signal(0);

	// ---- 派生值 ----
	const sessionId = computed(() => view().sessionId);
	const items = computed(() => view().items);
	const running = computed(() => view().running);
	const turn = computed(() => view().turn);
	const lastSeq = computed(() => view().lastSeq);
	const title = computed(() => view().title);
	const usage = computed(() => view().usage);
	const thinking = computed(() => running() && view().thinking === true);

	const currentTitle = computed(() => {
		const id = sessionId();
		return id ? sessionTitle({ session_id: id, title: title() }) : "新会话";
	});

	// 主区标题行：本 session 的累计 token（来自 session_end / turn_end）。
	const usageLabel = computed(() => {
		const total = usageTotal(usage());
		return total === null ? "" : `${formatTokenCount(total)} tokens`;
	});

	// 模型名、agent 从顶栏移除后，和 token 分项一起放在这个悬停提示里。
	const usageTitle = computed(() => usageDetailText(usage(), config()));

	// 工作空间列表：服务端 project 列表 + 当前目录（新选的目录还没 session
	// 文件），再按用户偏好排序。排序不改服务端返回顺序。
	const workspaceProjects = computed(() => {
		const groups = asArray(projects()).slice();
		const cwd = projectCwd();
		if (cwd && !groups.some((project) => project?.cwd === cwd)) {
			groups.unshift({ cwd, sessions: [] });
		}
		return sortProjects(groups, sortOrder());
	});

	const activeProject = computed(() => {
		const cwd = projectCwd();
		return workspaceProjects().find((project) => project?.cwd === cwd) ?? null;
	});

	// 对话栏只展示当前工作空间的对话记录，平铺、不分日组。
	const activeSessions = computed(() => asArray(activeProject()?.sessions));

	const sortedSessions = computed(() => sortSessions(activeSessions(), sortOrder()));

	// 对话栏按时间分组：今天 / 昨天 / 7天内 / 更早，空组不渲染。
	// 组内顺序跟随排序偏好，组本身的先后固定。
	const sessionGroups = computed(() => groupSessionsByTime(sortedSessions()));

	// 排序菜单按钮的提示：当前按什么排。
	const sortLabel = computed(() => (sortOrder() === "name" ? "名称" : "最近活动"));

	// 「当前修改的文件」：本会话最近一次 write_file / edit_file 的 file_path。
	const currentFile = computed(() => {
		const list = items();
		for (let index = list.length - 1; index >= 0; index -= 1) {
			const item = list[index];
			if (item?.kind === "tool" && item.path) return item.path;
		}
		return "";
	});

	const currentFileName = computed(() => fileName(currentFile()));

	// 窄屏时两个侧栏都是浮层，浮层打开时盖一层可点击的遮罩。
	const railVisible = computed(() =>
		layoutMode() === "wide" ? !railCollapsed() : railOpen(),
	);

	const sessionsVisible = computed(() =>
		layoutMode() === "compact" ? sessionsOpen() : true,
	);

	// 只有当前档位下真的是浮层的栏才算在遮罩范围内：窄屏的对话栏是内联的。
	const overlayOpen = computed(() => {
		const mode = layoutMode();
		if (mode === "wide") return false;
		return railOpen() || (mode === "compact" && sessionsOpen());
	});

	const statusKind = computed(() => {
		if (cancelling()) return "cancelling";
		if (running()) return "running";
		if (loading()) return "loading";
		if (connected() === "reconnecting") return "reconnecting";
		if (connected() === "closed") return "offline";
		if (connected() === "open") return "idle";
		return "connecting";
	});

	const statusLabel = computed(() => {
		switch (statusKind()) {
			case "cancelling":
				return "取消中";
			case "running":
				return "运行中";
			case "loading":
				return "加载中";
			case "reconnecting":
				return "重连中";
			case "offline":
				return "已离线";
			case "idle":
				return "空闲";
			default:
				return "连接中";
		}
	});

	// 当前活动 session 还没出现在对话列表里（新 slot 尚未落盘）时，
	// 在当前工作空间下显示一条占位会话。
	const showsDraftSession = computed(() => {
		const project = activeProject();
		if (!project) return false;
		const id = sessionId();
		return !asArray(project.sessions).some((item) => item?.session_id === id);
	});

	const showsEmptySessions = computed(
		() => activeSessions().length === 0 && !showsDraftSession(),
	);

	// ---- reducer 入口 ----

	function reset(id = null) {
		batch(() => {
			view(createState({ sessionId: id }));
			// 换 session 后消息区会被重新滚到底，按钮先收起。
			atBottom(true);
		});
	}

	function ingest(events, id = null) {
		view(ingestHistory(createState({ sessionId: id }), asArray(events)));
	}

	// SSE 重连后补齐断线期间落盘的 transcript 事件。
	// user_message 已在本地回显，history 里再出现不重复画。
	function mergeHistory(events) {
		batch(() => {
			let next = view();
			for (const event of asArray(events)) {
				if (typeof event?.seq === "number" && event.seq > 0 && event.seq <= next.lastSeq) {
					continue;
				}
				if (event?.type === "user_message") {
					if (typeof event.seq === "number" && event.seq > 0) {
						next = { ...next, lastSeq: event.seq };
					}
					continue;
				}
				next = applyEvent(next, event, "history");
			}
			view(next);
		});
	}

	function handleEvent(event) {
		handleEvents([event]);
	}

	// SSE 的 delta 可能每几毫秒一条；成批应用后只 publish 一次，
	// 避免同一段 Markdown 每个 token 都重渲染一遍整条消息。
	function handleEvents(events) {
		const list = asArray(events);
		if (list.length === 0) return;
		batch(() => {
			let next = view();
			for (const event of list) {
				next = applyEvent(next, event, "live");
				if (event?.type === "session_title") setSessionTitle(next.sessionId, event.title);
			}
			view(next);
		});
	}

	function handleTurnDone(payload) {
		batch(() => {
			view(applyTurnDone(view(), payload));
		});
	}

	function addUser(text) {
		view(appendUserMessage(view(), text));
	}

	function notice(text, tone = "muted") {
		view(appendNotice(view(), text, tone));
	}

	function setSession(id) {
		// 换了 session 就先清掉旧标题：history 里的 session_title 会补回来。
		view({ ...view(), sessionId: id ?? null, title: "" });
	}

	// 切换标签页自己的 session：key 变了才需要重连 SSE，id 用于载入 history。
	function setSessionKey(key) {
		sessionKey(key || null);
	}

	// 只同步运行态；key 由客户端持有，服务端的「最近活跃」指针不能覆盖它。
	function syncCurrent(current = {}) {
		batch(() => {
			let next = view();
			if (current.session_id) {
				next =
					current.session_id === next.sessionId
						? { ...next, sessionId: current.session_id }
						: { ...next, sessionId: current.session_id, title: "" };
			}
			// 刷新页面时可能正卡在模型思考中，还没等到任何增量：先按运行态亮起
			// 动画，后续文本/工具事件会把它关掉。
			if (typeof current.running === "boolean") {
				next = { ...next, running: current.running, thinking: current.running };
			}
			if (typeof current.turn === "number") next = { ...next, turn: current.turn };
			view(next);
			if (typeof current.cwd === "string" && current.cwd) setProjectCwd(current.cwd);
		});
	}

	function setRunning(value) {
		const runningNow = Boolean(value);
		view({ ...view(), running: runningNow, thinking: runningNow });
	}

	// ---- UI 状态 action ----

	function setLoading(value) {
		loading(Boolean(value));
	}

	function setPicking(value) {
		picking(Boolean(value));
	}

	function setCancelling(value) {
		cancelling(Boolean(value));
	}

	function setTitlePending(value) {
		titlePending(Boolean(value));
	}

	function setConnection(state) {
		connected(state);
	}

	function setError(message) {
		error(message || "");
	}

	function setConfig(next) {
		config(next && typeof next === "object" ? next : null);
	}

	function setCwd(cwd) {
		config({ ...(config() ?? {}), cwd });
	}

	function setProjects(next) {
		projects(
			asArray(next).map((project) => ({
				...(project && typeof project === "object" ? project : {}),
				sessions: asArray(project?.sessions),
			})),
		);
	}

	// 当前会话的标题：接口返回时会话可能还没收到 SSE 事件（例如断线）。
	function setTitle(next) {
		const value = typeof next === "string" ? next.trim() : "";
		if (!value) return;
		view({ ...view(), title: value });
	}

	// 标题已经写进 transcript；顺手把侧栏里同一个 session 的条目也改掉，
	// 否则要等下一次 /api/projects 才显示新标题。
	// 必须替换数组和 session 对象：信号按引用比较，原地改不会通知订阅者。
	function setSessionTitle(id, next) {
		const value = typeof next === "string" ? next.trim() : "";
		if (!id || !value) return;
		let changed = false;
		const nextProjects = asArray(projects()).map((project) => {
			const sessions = asArray(project.sessions);
			let projectChanged = false;
			const nextSessions = sessions.map((session) => {
				if (session?.session_id !== id || session.title === value) return session;
				projectChanged = true;
				return { ...session, title: value };
			});
			if (!projectChanged) return project;
			changed = true;
			return { ...project, sessions: nextSessions };
		});
		if (changed) projects(nextProjects);
	}

	function setProjectCwd(cwd) {
		projectCwd(cwd || null);
	}

	function setDraft(text) {
		draft(typeof text === "string" ? text : String(text ?? ""));
	}

	function setRailCollapsed(collapsed) {
		railCollapsed(Boolean(collapsed));
	}

	function setRailOpen(open) {
		railOpen(Boolean(open));
	}

	function setSessionsOpen(open) {
		sessionsOpen(Boolean(open));
	}

	function setLayoutMode(mode) {
		layoutMode(mode === "compact" || mode === "narrow" ? mode : "wide");
	}

	function setSortOrder(order) {
		sortOrder(SORT_ORDERS.includes(order) ? order : "recent");
	}

	function setRailWidth(width) {
		railWidth(clampPanelWidth(width));
	}

	function setSessionsWidth(width) {
		sessionsWidth(clampPanelWidth(width));
	}

	function setAtBottom(value) {
		atBottom(Boolean(value));
	}

	function requestFocus() {
		focusNonce(focusNonce() + 1);
	}

	function requestScroll(force = false) {
		const current = scrollRequest();
		scrollRequest({ nonce: current.nonce + 1, force: Boolean(force) });
	}

	return {
		// 状态信号
		view,
		sessionKey,
		projects,
		config,
		projectCwd,
		loading,
		picking,
		cancelling,
		titlePending,
		connected,
		error,
		draft,
		railCollapsed,
		railOpen,
		sessionsOpen,
		layoutMode,
		sortOrder,
		railWidth,
		sessionsWidth,
		atBottom,
		scrollRequest,
		focusNonce,
		// 派生值
		sessionId,
		items,
		running,
		turn,
		lastSeq,
		title,
		usage,
		thinking,
		currentTitle,
		usageLabel,
		usageTitle,
		workspaceProjects,
		activeProject,
		activeSessions,
		sortedSessions,
		sessionGroups,
		sortLabel,
		currentFile,
		currentFileName,
		railVisible,
		sessionsVisible,
		overlayOpen,
		statusKind,
		statusLabel,
		showsDraftSession,
		showsEmptySessions,
		// 批量与 action
		batch,
		reset,
		ingest,
		mergeHistory,
		handleEvent,
		handleEvents,
		handleTurnDone,
		addUser,
		notice,
		setSession,
		setSessionKey,
		syncCurrent,
		setRunning,
		setLoading,
		setPicking,
		setCancelling,
		setTitlePending,
		setConnection,
		setError,
		setConfig,
		setCwd,
		setProjects,
		setTitle,
		setSessionTitle,
		setProjectCwd,
		setDraft,
		setRailCollapsed,
		setRailOpen,
		setSessionsOpen,
		setLayoutMode,
		setSortOrder,
		setRailWidth,
		setSessionsWidth,
		setAtBottom,
		requestFocus,
		requestScroll,
	};
}
