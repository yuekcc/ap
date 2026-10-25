// Alpine.reactive store。render.js 只产出纯状态，这里负责：
// - 把纯状态发布到 Alpine 能追踪的字段上；
// - 维护 session / 运行状态 / 连接状态等 UI 状态；
// - 提供 render reducer 的薄入口（handleEvent / ingestHistory / handleTurnDone）。
import Alpine from "alpinejs";
import {
	appendNotice,
	appendUserMessage,
	applyEvent,
	applyTurnDone,
	createState,
	ingestHistory,
	stateAfterCwdChange,
} from "./render.js";

function asArray(value) {
	return Array.isArray(value) ? value : [];
}

export function createStore() {
	// view 是非响应式的纯状态；每次 reducer 返回新对象后 publish() 同步到 store。
	let view = createState();

	const store = Alpine.reactive({
		items: [],
		sessionId: null,
		turn: 0,
		lastSeq: 0,
		running: false,
		loading: false,
		picking: false,
		cancelling: false,
		connected: "connecting",
		error: "",
		config: null,
		sessions: [],
		draft: "",

		get platform() {
			return String(this.config?.platform ?? "").toLowerCase();
		},

		get isWindows() {
			return this.platform === "windows";
		},

		get statusKind() {
			if (this.cancelling) return "cancelling";
			if (this.running) return "running";
			if (this.loading) return "loading";
			if (this.connected === "reconnecting") return "reconnecting";
			if (this.connected === "closed") return "offline";
			if (this.connected === "open") return "idle";
			return "connecting";
		},

		get statusLabel() {
			switch (this.statusKind) {
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
		},

		reset(sessionId = null) {
			view = createState({ sessionId });
			publish();
		},

		// 目录切换成功后服务器已清空 session 指针；前端丢弃旧 transcript 并提示。
		resetAfterCwdChange() {
			view = stateAfterCwdChange();
			publish();
		},

		ingest(events, sessionId = null) {
			view = ingestHistory(createState({ sessionId }), asArray(events));
			publish();
		},

		// SSE 重连后补齐断线期间落盘的 transcript 事件。
		// user_message 已在本地回显，history 里再出现不重复画。
		mergeHistory(events) {
			for (const event of asArray(events)) {
				if (typeof event.seq === "number" && event.seq > 0 && event.seq <= view.lastSeq) {
					continue;
				}
				if (event.type === "user_message") {
					if (typeof event.seq === "number" && event.seq > 0) {
						view = { ...view, lastSeq: event.seq };
					}
					continue;
				}
				view = applyEvent(view, event, "history");
			}
			publish();
		},

		handleEvent(event) {
			view = applyEvent(view, event, "live");
			publish();
		},

		handleTurnDone(payload) {
			view = applyTurnDone(view, payload);
			publish();
		},

		addUser(text) {
			view = appendUserMessage(view, text);
			publish();
		},

		notice(text, tone = "muted") {
			view = appendNotice(view, text, tone);
			publish();
		},

		setSession(sessionId) {
			view = { ...view, sessionId: sessionId ?? null };
			publish();
		},

		syncCurrent(current = {}) {
			if (current.session_id) view = { ...view, sessionId: current.session_id };
			if (typeof current.running === "boolean") view = { ...view, running: current.running };
			if (typeof current.turn === "number") view = { ...view, turn: current.turn };
			publish();
		},

		setRunning(running) {
			view = { ...view, running: Boolean(running) };
			publish();
		},

		setLoading(loading) {
			this.loading = Boolean(loading);
		},

		setPicking(picking) {
			this.picking = Boolean(picking);
		},

		setCancelling(cancelling) {
			this.cancelling = Boolean(cancelling);
		},

		setConnection(state) {
			this.connected = state;
		},

		setError(message) {
			this.error = message || "";
		},

		setConfig(config) {
			this.config = config && typeof config === "object" ? config : null;
		},

		setCwd(cwd) {
			this.config = { ...(this.config ?? {}), cwd };
		},

		setSessions(sessions) {
			this.sessions = asArray(sessions);
		},

		setDraft(text) {
			this.draft = text;
		},
	});

	function publish() {
		store.items = view.items;
		store.sessionId = view.sessionId;
		store.turn = view.turn;
		store.lastSeq = view.lastSeq;
		store.running = view.running;
	}

	return store;
}
