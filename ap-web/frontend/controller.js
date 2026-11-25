// 会话 / SSE 编排：boot、恢复指针、history、订阅、发送、交接、标题、取消、
// 目录选择。这里不碰 DOM：需要滚动或聚焦时只递增 store 的请求计数器，
// ui/* 自己监听并在下一帧处理。
//
// 多标签页 / 多 project：每个标签页持有自己的 session_key，SSE 只订阅该
// session；sessionStorage 记住本标签页的 {key, id, cwd}，刷新后优先按真实
// id + cwd 恢复。
import { api, eventsUrl } from "./api.js";
import {
	RAIL_STORAGE_KEY,
	SORT_STORAGE_KEY,
	clearSessionPrefs,
	readSessionPrefs,
	writeLocal,
	writeSessionPrefs,
} from "./prefs.js";
import { createEventStream } from "./sse.js";

// api / streams 可注入：controller 不依赖 DOM，测试可以直接喂假接口。
export function createController(store, { api: apiClient = api, streams = createEventStream } = {}) {
	let stream = null;
	let wasOpen = false;
	let resyncing = false;
	// 发起本轮时的 session id：turn 结束时 id 变了说明发生了交接。
	let turnSessionId = null;
	// SSE 增量先入队，按帧合并后一次性应用（见 queueEvent）。
	let pendingEvents = [];
	let flushHandle = 0;

	function defaultCwd() {
		return store.config()?.cwd ?? "";
	}

	// 服务端列表里没有记录时（slot、刚 pick 的新目录），回落到给定的 cwd。
	function projectCwdFor(sessionId, fallback = "") {
		for (const project of store.projects()) {
			if (asArray(project?.sessions).some((item) => item?.session_id === sessionId)) {
				return project.cwd;
			}
		}
		return fallback || defaultCwd();
	}

	function asArray(value) {
		return Array.isArray(value) ? value : [];
	}

	// ---- 本标签页的 session 指针 ----

	function persistSession() {
		const key = store.sessionKey();
		const id = store.sessionId();
		const cwd = store.projectCwd();
		if (!key && !id) {
			clearSessionPrefs();
			return;
		}
		writeSessionPrefs({ key: key ?? "", id: id ?? "", cwd: cwd ?? "" });
	}

	function activateSession(key, sessionId, cwd) {
		// 换 session 就把还没应用的增量扔掉，别把它们画到新会话里。
		dropEvents();
		// 三个信号一起换：一帧只渲染一次，避免中途出现「新 key + 旧视图」。
		store.batch(() => {
			store.setProjectCwd(cwd);
			store.setSessionKey(key);
			store.setSession(sessionId ?? null);
		});
		persistSession();
	}

	// ---- 启动与恢复 ----

	async function boot() {
		store.setLoading(true);
		try {
			await Promise.all([loadConfig(), loadProjects()]);
			await loadCwd();
			await resolveBootSession();
		} finally {
			store.setLoading(false);
			store.requestScroll(true);
			store.requestFocus();
		}
	}

	// 恢复顺序：sessionStorage 的真实 id → slot key → 最近 project 的最新
	// session → 默认目录新建 slot。cwd 随记录一起保存，因为同一个 session id
	// 只有在它自己的 project 里才能读到 transcript。
	async function resolveBootSession() {
		const saved = readSessionPrefs();

		if (saved?.id) {
			try {
				await openSession(saved.id, saved.cwd || projectCwdFor(saved.id), {
					reloadProjects: false,
				});
				return;
			} catch (error) {
				fail("恢复上次会话失败", error);
			}
		} else if (saved?.key) {
			try {
				const current = await apiClient.currentSession(saved.key);
				if (current?.session_key === saved.key) {
					const cwd = current.cwd || saved.cwd || defaultCwd();
					activateSession(saved.key, current.session_id || null, cwd);
					store.syncCurrent(current ?? {});
					persistSession();
					if (current.session_id) {
						await loadHistory(current.session_id, cwd);
					}
					connect();
					return;
				}
			} catch (error) {
				fail("读取上次会话失败", error);
			}
		}

		for (const project of store.projects()) {
			const session = asArray(project?.sessions)[0];
			if (!session) continue;
			try {
				await openSession(session.session_id, project.cwd, {
					reloadProjects: false,
				});
				return;
			} catch (error) {
				fail("恢复最近会话失败", error);
				break;
			}
		}

		await newSession(defaultCwd());
	}

	// 读取指定 session 的运行态；key 已切换时丢弃过期响应。
	async function syncSession(key = store.sessionKey()) {
		if (!key) return;
		try {
			const current = await apiClient.currentSession(key);
			if (store.sessionKey() !== key) return;
			store.syncCurrent(current ?? {});
			persistSession();
		} catch {
			// current 读失败不影响已经渲染的 transcript。
		}
	}

	// 打开一个已有 session：恢复指针 → 载入该 project 的 history → 订阅 SSE。
	// 不做 loading 守卫，boot 与公开入口都复用它。
	async function openSession(sessionId, cwd, { reloadProjects = true } = {}) {
		const resumed = await apiClient.resumeSession(sessionId, cwd);
		const key = resumed?.session_key || sessionId;
		const projectCwd = resumed?.cwd || cwd || projectCwdFor(sessionId);
		activateSession(key, sessionId, projectCwd);
		// 不先清空视图：新 transcript 到达后一次替换，切换对话时不会闪过空状态。
		try {
			await loadHistory(sessionId, projectCwd);
		} catch (error) {
			// history 失败时不能把上一个会话的内容留给新会话，再连 SSE 兜底。
			store.reset(sessionId);
			fail("读取历史失败", error);
		}
		// history 只还原 transcript；运行态与 turn 号以 current 为准。
		await syncSession(key);
		if (store.sessionKey() === key) connect();
		store.setError("");
		if (reloadProjects) await loadProjects();
		store.requestScroll(true);
	}

	async function loadConfig() {
		try {
			store.setConfig(await apiClient.config());
		} catch (error) {
			fail("读取配置失败", error);
		}
	}

	async function loadProjects() {
		try {
			store.setProjects(await apiClient.projects());
		} catch (error) {
			fail("读取工作目录失败", error);
		}
	}

	async function loadCwd() {
		try {
			const data = await apiClient.cwd();
			if (data?.cwd) store.setCwd(data.cwd);
		} catch {
			// 老服务端可能还没有这个端点；config.cwd 仍可作为回显。
		}
	}

	// 先渲染 history 再订阅 SSE；重叠的 transcript 事件由 seq 在 sse/store 里跳过。
	async function loadHistory(sessionId, cwd) {
		if (!sessionId) {
			store.reset(null);
			return;
		}
		const data = await apiClient.history(sessionId, cwd);
		store.ingest(data?.events ?? [], sessionId);
	}

	// ---- SSE ----

	function queueEvent(event) {
		pendingEvents.push(event);
		if (flushHandle) return;
		// 后台标签页不跑 rAF，改用定时器，避免队列无限长。
		flushHandle = document.hidden
			? setTimeout(() => flushEvents(), 250)
			: requestAnimationFrame(() => flushEvents());
	}

	function flushEvents() {
		cancelFlush();
		const events = pendingEvents;
		pendingEvents = [];
		if (events.length > 0) store.handleEvents(events);
	}

	function dropEvents() {
		cancelFlush();
		pendingEvents = [];
	}

	function cancelFlush() {
		if (!flushHandle) return;
		cancelAnimationFrame(flushHandle);
		clearTimeout(flushHandle);
		flushHandle = 0;
	}

	function connect() {
		const key = store.sessionKey();
		disconnect();
		wasOpen = false;
		if (!key) {
			store.setConnection("closed");
			return;
		}
		stream = streams({
			url: eventsUrl(key),
			getLastSeq: () => store.lastSeq(),
			onEvent: (event) => {
				if (store.sessionKey() !== key) return;
				queueEvent(event);
			},
			onTurnDone: (payload) => {
				if (store.sessionKey() !== key) return;
				// turn_done 必须排在本轮所有增量之后应用。
				flushEvents();
				store.handleTurnDone(payload);
				afterTurnDone();
			},
			onState: (state) => {
				if (store.sessionKey() !== key) return;
				flushEvents();
				store.setConnection(state);
				if (state !== "open") return;
				if (wasOpen) {
					resync();
				} else {
					wasOpen = true;
					// history → subscribe 之间可能漏掉刚落盘的事件，静默补一次。
					fillGap();
				}
			},
		});
	}

	function disconnect() {
		dropEvents();
		if (stream) {
			stream.close();
			stream = null;
		}
	}

	// 首次订阅成功后补齐 history 与 subscribe 之间的空档；失败不打扰用户。
	async function fillGap() {
		const key = store.sessionKey();
		const sessionId = store.sessionId();
		const cwd = store.projectCwd();
		if (!key || !sessionId || !cwd) return;
		try {
			const data = await apiClient.history(sessionId, cwd);
			if (store.sessionKey() !== key || store.sessionId() !== sessionId) return;
			store.mergeHistory(data?.events ?? []);
			store.requestScroll();
		} catch {
			// 下一次重连的 resync 还会再试。
		}
	}

	// 断线重连后：current 修正 running/turn，history 补齐落盘的事件。
	async function resync() {
		const key = store.sessionKey();
		if (resyncing || !key) return;
		resyncing = true;
		try {
			const current = await apiClient.currentSession(key);
			if (store.sessionKey() !== key) return;
			store.syncCurrent(current ?? {});
			persistSession();
			const sessionId = store.sessionId();
			const cwd = store.projectCwd();
			if (sessionId && cwd) {
				const data = await apiClient.history(sessionId, cwd);
				if (store.sessionKey() !== key) return;
				store.mergeHistory(data?.events ?? []);
			}
			await loadProjects();
			store.requestScroll();
		} catch (error) {
			if (store.sessionKey() === key) fail("重连后同步失败", error);
		} finally {
			resyncing = false;
		}
	}

	// ---- 发送与取消 ----

	async function send() {
		const prompt = store.draft().trim();
		if (!prompt || store.running() || store.loading()) return;
		const key = store.sessionKey();
		if (!key) {
			store.notice("会话尚未就绪，请新建会话", "warning");
			return;
		}

		store.batch(() => {
			store.setDraft("");
			store.addUser(prompt);
			store.setRunning(true);
			store.setError("");
		});
		turnSessionId = store.sessionId();
		store.requestScroll(true);

		try {
			await apiClient.startTurn({
				prompt,
				session_key: key,
				cwd: store.projectCwd() ?? "",
			});
		} catch (error) {
			if (store.sessionKey() !== key) return;
			if (error?.status === 409 && error?.code === "turn_running") {
				store.setRunning(true);
				store.notice("该会话已有 turn 正在运行", "warning");
				return;
			}
			store.batch(() => {
				store.setRunning(false);
				store.setDraft(prompt);
			});
			fail("发送失败", error);
		}
	}

	// 手动交接：让 ap 生成交接文档并创建新 session。输入框里的文字作为
	// 新 session 的聚焦提示词（为空则只交接，不跑 turn）。
	async function sendHandoff() {
		if (store.running() || store.loading()) return;
		const key = store.sessionKey();
		if (!key || !store.sessionId()) {
			store.notice("当前会话还没有产生对话，无法交接", "warning");
			return;
		}
		const focus = store.draft().trim();
		turnSessionId = store.sessionId();
		store.batch(() => {
			store.setDraft("");
			store.setRunning(true);
			store.setError("");
			store.notice(focus ? "正在交接并继续…" : "正在生成交接文档…", "muted");
		});
		try {
			await apiClient.startTurn({
				prompt: focus,
				handoff: true,
				session_key: key,
				cwd: store.projectCwd() ?? "",
			});
		} catch (error) {
			if (store.sessionKey() !== key) return;
			if (error?.status === 409 && error?.code === "turn_running") {
				store.setRunning(true);
				store.notice("该会话已有 turn 正在运行", "warning");
				return;
			}
			store.batch(() => {
				store.setRunning(false);
				store.setDraft(focus);
			});
			fail("交接失败", error);
		}
	}

	// 手动刷新标题：服务端同步跑一次 ap --session-title，返回最终标题。
	// 结果也会通过 SSE 的 session_title 事件到达，两条路径都只是覆盖同一个值。
	async function refreshTitle() {
		if (store.titlePending() || store.running() || store.loading() || !store.sessionId()) return;
		store.setTitlePending(true);
		try {
			const result = await apiClient.sessionTitle(store.sessionKey());
			const title = typeof result?.title === "string" ? result.title : "";
			store.setTitle(title);
			store.setSessionTitle(store.sessionId(), title);
			if (title) store.notice(`标题已更新：${title}`, "muted");
		} catch (error) {
			if (error?.status === 409 && error?.code === "turn_running") {
				store.notice("该会话正在运行，稍后再生成标题", "warning");
			} else if (error?.status === 409) {
				store.notice("当前会话还没有可用的对话，无法生成标题", "warning");
			} else {
				fail("生成标题失败", error);
			}
		} finally {
			store.setTitlePending(false);
		}
	}

	async function cancel() {
		const key = store.sessionKey();
		if (!store.running() || store.cancelling() || !key) return;
		store.setCancelling(true);
		try {
			const result = await apiClient.cancelTurn(key);
			if (store.sessionKey() !== key) return;
			if (!result?.cancelled) {
				store.batch(() => {
					store.setCancelling(false);
					store.setRunning(false);
				});
			}
		} catch (error) {
			if (store.sessionKey() !== key) return;
			store.setCancelling(false);
			fail("取消失败", error);
		}
	}

	async function afterTurnDone() {
		store.setCancelling(false);
		loadProjects();
		const key = store.sessionKey();
		if (!key) return;
		try {
			const current = await apiClient.currentSession(key);
			if (store.sessionKey() !== key) return;
			store.syncCurrent(current ?? {});
			persistSession();
		} catch {
			// turn 已经结束，current 读失败不影响画面。
		}
		// 交接会换一个新 session：重放它的 transcript，而不是把新旧混在一起。
		const sessionId = store.sessionId();
		if (turnSessionId && sessionId && sessionId !== turnSessionId) {
			const cwd = store.projectCwd();
			store.reset(sessionId);
			try {
				if (cwd) await loadHistory(sessionId, cwd);
			} catch (error) {
				fail("载入交接后的会话失败", error);
			}
			store.notice(`已交接，当前会话 ${sessionId}`, "muted");
			turnSessionId = sessionId;
			persistSession();
		}
		store.requestScroll();
	}

	// ---- 切换工作空间 / session ----

	// 在指定工作目录新建 slot；不传时沿用当前 project，再退到默认目录。
	async function newSession(cwd, { focus = true } = {}) {
		// 按钮的回调可能把 MouseEvent 当参数传进来；只接受路径字符串。
		const requested = typeof cwd === "string" ? cwd.trim() : "";
		const target = requested || store.projectCwd() || defaultCwd();
		// 紧凑屏下「新对话」在浮层里：开完就把浮层收起来。
		closeOverlays();
		store.setLoading(true);
		try {
			const created = await apiClient.newSession(target);
			const key = created?.session_key;
			if (!key) throw new Error("服务端没有返回 session_key");
			// 先设 key/cwd 再 reset：reset 只清空 transcript。
			dropEvents();
			store.batch(() => {
				store.setProjectCwd(created?.cwd || target);
				store.setSessionKey(key);
				store.reset(null);
				store.setError("");
			});
			persistSession();
			connect();
			await loadProjects();
			store.requestScroll(true);
			if (focus) store.requestFocus();
			return true;
		} catch (error) {
			fail("新建会话失败", error);
			return false;
		} finally {
			store.setLoading(false);
		}
	}

	// 点击工作空间栏的列表项：切到该目录最近一条对话；还没有对话就在该目录开新 slot。
	function switchWorkspace(project) {
		const cwd = project?.cwd;
		if (!cwd || store.loading()) return;
		closeOverlays();
		if (cwd === store.projectCwd()) return;
		const latest = asArray(project.sessions)[0];
		if (latest?.session_id) {
			return resumeSession(latest.session_id, cwd);
		}
		return newSession(cwd);
	}

	// 顶部「+」：打开系统目录选择框，在选中的目录开一个新工作空间。
	function openWorkspace() {
		return pickDirectory();
	}

	// 对话栏标题行两个按钮：在本机打开当前工作目录的文件管理器 / 终端。
	// 只是让服务端起一个外部进程，不改变任何 session 或 cwd。
	function openWorkdir(target) {
		const cwd = store.projectCwd() || defaultCwd();
		if (!cwd) return undefined;
		const request = target === "terminal" ? apiClient.openTerminal(cwd) : apiClient.openFiles(cwd);
		return request.catch((error) => {
			fail(target === "terminal" ? "打开终端失败" : "打开文件管理器失败", error);
		});
	}

	function openWorkdirFiles() {
		return openWorkdir("files");
	}

	function openWorkdirTerminal() {
		return openWorkdir("terminal");
	}

	async function resumeSession(sessionId, cwd) {
		if (!sessionId) return;
		if (
			sessionId === store.sessionId() &&
			store.sessionKey() &&
			cwd === store.projectCwd()
		) {
			return;
		}
		if (store.loading()) return;
		store.setLoading(true);
		try {
			await openSession(sessionId, cwd);
		} catch (error) {
			fail("恢复会话失败", error);
		} finally {
			store.setLoading(false);
		}
	}

	function selectSession(session) {
		const cwd = store.projectCwd();
		if (!cwd || !session?.session_id) return undefined;
		closeOverlays();
		return resumeSession(session.session_id, cwd);
	}

	async function pickDirectory() {
		if (store.picking()) return;
		store.setPicking(true);
		try {
			const result = await apiClient.pickCwd();
			if (result?.cwd) {
				// 目录只是「打开一个 project」，不再替换全局 cwd、也不再清空
				// 其他 project 的 session；直接在该目录开一个新 slot。
				await newSession(result.cwd);
			}
		} catch (error) {
			// 用户主动关掉对话框不是错误。
			if (error?.code === "cancelled") return;
			if (error?.code === "picker_busy") {
				store.notice("目录选择框已经打开", "warning");
				return;
			}
			if (error?.status === 501) {
				store.notice("当前平台不支持系统目录选择", "warning");
				return;
			}
			fail("选择目录失败", error);
		} finally {
			store.setPicking(false);
		}
	}

	// ---- 布局与偏好 ----

	// 侧栏折叠只改布局，不影响当前会话；宽度变化后贴底才需要重新跟随。
	// 宽屏下切换的是持久化的折叠偏好，窄屏下切换的是本次浮层。
	function toggleRail() {
		if (store.layoutMode() === "wide") {
			const collapsed = !store.railCollapsed();
			store.setRailCollapsed(collapsed);
			writeLocal(RAIL_STORAGE_KEY, collapsed ? "1" : "0");
		} else {
			const open = !store.railOpen();
			store.setRailOpen(open);
			// 两个浮层不堆叠：展开一个就收起另一个。
			if (open) store.setSessionsOpen(false);
		}
		store.requestScroll();
	}

	// 紧凑屏：对话栏是浮层，由主区标题行的按钮开关。
	function toggleSessions() {
		const open = !store.sessionsOpen();
		store.setSessionsOpen(open);
		if (open) store.setRailOpen(false);
	}

	function closeOverlays() {
		store.batch(() => {
			store.setRailOpen(false);
			store.setSessionsOpen(false);
		});
	}

	function setSortOrder(order) {
		store.setSortOrder(order);
		writeLocal(SORT_STORAGE_KEY, store.sortOrder());
	}

	// 「当前修改的文件」只显示文件名，点击复制完整路径。
	async function copyCurrentPath() {
		const path = store.currentFile();
		if (!path) return;
		try {
			await navigator.clipboard.writeText(path);
			store.notice(`已复制路径：${path}`, "muted");
		} catch {
			// 非安全上下文（http）下没有 clipboard API，退回一行提示而不静默失败。
			store.notice(`复制失败，路径：${path}`, "warning");
		}
	}

	function fail(prefix, error) {
		const message = error?.message ? `${prefix}：${error.message}` : prefix;
		store.setError(message);
		store.notice(message, "error");
	}

	// 切到后台时 rAF 会停，先把队列冲掉，之后的事件改走定时器合批。
	if (typeof document !== "undefined") {
		document.addEventListener("visibilitychange", () => {
			if (document.hidden) flushEvents();
		});
	}

	return {
		boot,
		resolveBootSession,
		openSession,
		syncSession,
		loadConfig,
		loadProjects,
		loadCwd,
		loadHistory,
		connect,
		disconnect,
		fillGap,
		resync,
		send,
		sendHandoff,
		refreshTitle,
		cancel,
		afterTurnDone,
		newSession,
		switchWorkspace,
		openWorkspace,
		openWorkdir,
		openWorkdirFiles,
		openWorkdirTerminal,
		resumeSession,
		selectSession,
		pickDirectory,
		copyCurrentPath,
		toggleRail,
		toggleSessions,
		closeOverlays,
		setSortOrder,
		queueEvent,
		flushEvents,
		dropEvents,
		persistSession,
		fail,
	};
}
