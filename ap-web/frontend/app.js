// 页面交互：加载 config/session/history，订阅 SSE，发送/取消 turn，
// 切换或新建 session，Windows 下选择工作目录。所有异步错误都落成 notice，
// 不让页面因为一个接口 404/501 就白屏。
//
// 多标签页：每个标签页持有自己的 session_key，SSE 只订阅该 session；
// sessionStorage 记住本标签页的 {key, id}，刷新后优先按真实 id 恢复。
import { api, eventsUrl } from "./api.js";
import { renderMarkdown } from "./markdown.js";
import { sessionMeta, sessionTitle } from "./render.js";
import { createEventStream } from "./sse.js";

const SESSION_STORAGE_KEY = "ap-web:session";

export function registerApp(Alpine) {
	Alpine.data("apApp", () => ({
		stream: null,
		wasOpen: false,
		resyncing: false,

		// 绑定给 x-html：assistant 文本按 Markdown 渲染。
		renderMarkdown,

		init() {
			// 消息区只在用户本来就在底部时自动跟随，避免打断向上翻看。
			this.$watch("$store.ap.items", () => this.autoScroll());
			this.$watch("$store.ap.sessionId", () => this.$nextTick(() => this.autoScroll()));
			this.$watch("$store.ap.sessionKey", () => this.persistSession());
			this.$watch("$store.ap.sessionId", () => this.persistSession());

			const store = this.$store.ap;
			store.reset(null);
			this.boot();
		},

		// 本标签页的 session 只影响自己；不同标签页各自独立。
		persistSession() {
			const { sessionKey, sessionId } = this.$store.ap;
			try {
				if (!sessionKey && !sessionId) {
					sessionStorage.removeItem(SESSION_STORAGE_KEY);
					return;
				}
				sessionStorage.setItem(
					SESSION_STORAGE_KEY,
					JSON.stringify({ key: sessionKey ?? "", id: sessionId ?? "" }),
				);
			} catch {
				// 隐私模式/禁用存储不影响当前会话。
			}
		},

		restoreSession() {
			try {
				const raw = sessionStorage.getItem(SESSION_STORAGE_KEY);
				if (!raw) return null;
				const saved = JSON.parse(raw);
				if (!saved || typeof saved !== "object") return null;
				const key = typeof saved.key === "string" ? saved.key : "";
				const id = typeof saved.id === "string" ? saved.id : "";
				return key || id ? { key, id } : null;
			} catch {
				return null;
			}
		},

		async boot() {
			const store = this.$store.ap;
			store.setLoading(true);
			try {
				await Promise.all([this.loadConfig(), this.loadSessions()]);
				await this.loadCwd();
				const key = await this.resolveBootSession();
				if (key) {
					try {
						await this.loadHistory(store.sessionId);
					} catch (error) {
						this.fail("读取历史失败", error);
					}
					this.connect();
				}
			} finally {
				store.setLoading(false);
				await this.$nextTick();
				this.autoScroll(true);
				this.$refs.input?.focus();
			}
		},

		// 恢复顺序：sessionStorage 的真实 id → sessionStorage 的 slot key →
		// 服务端「最近活跃」session → 新建 slot。slot key 在进程重启后已无意义，
		// 所以存了 id 时优先用 id，让服务端重新给出该 session 的规范 key。
		async resolveBootSession() {
			const store = this.$store.ap;
			const saved = this.restoreSession();

			if (saved?.id) {
				try {
					const resumed = await api.resumeSession(saved.id);
					const key = resumed?.session_key || saved.id;
					this.activateSession(key, saved.id);
					await this.syncSession(key);
					return key;
				} catch (error) {
					this.fail("恢复上次会话失败", error);
				}
			} else if (saved?.key) {
				try {
					const current = await api.currentSession(saved.key);
					if (current?.session_key === saved.key) {
						this.activateSession(saved.key, current.session_id || null);
						store.syncCurrent(current ?? {});
						return saved.key;
					}
				} catch (error) {
					this.fail("读取上次会话失败", error);
				}
			}

			try {
				const current = await api.currentSession();
				if (current?.session_key) {
					this.activateSession(current.session_key, current.session_id || null);
					store.syncCurrent(current ?? {});
					return current.session_key;
				}
			} catch (error) {
				this.fail("读取会话状态失败", error);
			}

			try {
				const created = await api.newSession();
				const key = created?.session_key;
				if (!key) throw new Error("服务端没有返回 session_key");
				this.activateSession(key, null);
				return key;
			} catch (error) {
				this.fail("新建会话失败", error);
				return null;
			}
		},

		activateSession(key, sessionId) {
			const store = this.$store.ap;
			store.setSessionKey(key);
			store.setSession(sessionId ?? null);
		},

		// 读取指定 session 的运行态；key 已切换时丢弃过期响应。
		async syncSession(key = this.$store.ap.sessionKey) {
			if (!key) return;
			try {
				const current = await api.currentSession(key);
				if (this.$store.ap.sessionKey !== key) return;
				this.$store.ap.syncCurrent(current ?? {});
			} catch {
				// current 读失败不影响已经渲染的 transcript。
			}
		},

		async loadConfig() {
			try {
				this.$store.ap.setConfig(await api.config());
			} catch (error) {
				this.fail("读取配置失败", error);
			}
		},

		async loadSessions() {
			try {
				this.$store.ap.setSessions(await api.sessions());
			} catch (error) {
				this.fail("读取会话列表失败", error);
			}
		},

		// /api/config 给的是启动参数里的 cwd；运行期切换过目录后以 /api/cwd 为准。
		async loadCwd() {
			try {
				const data = await api.cwd();
				if (data?.cwd) this.$store.ap.setCwd(data.cwd);
			} catch {
				// 老服务端可能还没有这个端点；config.cwd 仍可作为回显。
			}
		},

		// 先渲染 history 再订阅 SSE；重叠的 transcript 事件由 seq 在 sse/store 里跳过。
		async loadHistory(sessionId) {
			const store = this.$store.ap;
			if (!sessionId) {
				store.reset(null);
				return;
			}
			const data = await api.history(sessionId);
			store.ingest(data?.events ?? [], sessionId);
		},

		connect() {
			const store = this.$store.ap;
			const key = store.sessionKey;
			this.disconnect();
			this.wasOpen = false;
			if (!key) {
				store.setConnection("closed");
				return;
			}
			this.stream = createEventStream({
				url: eventsUrl(key),
				getLastSeq: () => this.$store.ap.lastSeq,
				onEvent: (event) => {
					if (this.$store.ap.sessionKey !== key) return;
					this.$store.ap.handleEvent(event);
				},
				onTurnDone: (payload) => {
					if (this.$store.ap.sessionKey !== key) return;
					this.$store.ap.handleTurnDone(payload);
					this.afterTurnDone();
				},
				onState: (state) => {
					if (this.$store.ap.sessionKey !== key) return;
					this.$store.ap.setConnection(state);
					if (state !== "open") return;
					if (this.wasOpen) {
						this.resync();
					} else {
						this.wasOpen = true;
						// history → subscribe 之间可能漏掉刚落盘的事件，静默补一次。
						this.fillGap();
					}
				},
			});
		},

		disconnect() {
			if (this.stream) {
				this.stream.close();
				this.stream = null;
			}
		},

		// 首次订阅成功后补齐 history 与 subscribe 之间的空档；失败不打扰用户。
		async fillGap() {
			const store = this.$store.ap;
			const key = store.sessionKey;
			const sessionId = store.sessionId;
			if (!key || !sessionId) return;
			try {
				const data = await api.history(sessionId);
				if (store.sessionKey !== key || store.sessionId !== sessionId) return;
				store.mergeHistory(data?.events ?? []);
				await this.$nextTick();
				this.autoScroll();
			} catch {
				// 下一次重连的 resync 还会再试。
			}
		},

		// 断线重连后：current 修正 running/turn，history 补齐落盘的事件。
		async resync() {
			const store = this.$store.ap;
			const key = store.sessionKey;
			if (this.resyncing || !key) return;
			this.resyncing = true;
			try {
				const current = await api.currentSession(key);
				if (store.sessionKey !== key) return;
				store.syncCurrent(current ?? {});
				const sessionId = store.sessionId;
				if (sessionId) {
					const data = await api.history(sessionId);
					if (store.sessionKey !== key) return;
					store.mergeHistory(data?.events ?? []);
				}
				await this.loadSessions();
				await this.$nextTick();
				this.autoScroll();
			} catch (error) {
				if (store.sessionKey === key) this.fail("重连后同步失败", error);
			} finally {
				this.resyncing = false;
			}
		},

		async send() {
			const store = this.$store.ap;
			const prompt = store.draft.trim();
			if (!prompt || store.running || store.loading) return;
			const key = store.sessionKey;
			if (!key) {
				store.notice("会话尚未就绪，请新建会话", "warning");
				return;
			}

			store.setDraft("");
			store.addUser(prompt);
			store.setRunning(true);
			store.setError("");
			await this.$nextTick();
			this.autoScroll(true);

			try {
				await api.startTurn({ prompt, session_key: key });
			} catch (error) {
				if (store.sessionKey !== key) return;
				if (error?.status === 409 && error?.code === "turn_running") {
					store.setRunning(true);
					store.notice("该会话已有 turn 正在运行", "warning");
					return;
				}
				store.setRunning(false);
				store.setDraft(prompt);
				this.fail("发送失败", error);
			}
		},

		async cancel() {
			const store = this.$store.ap;
			const key = store.sessionKey;
			if (!store.running || store.cancelling || !key) return;
			store.setCancelling(true);
			try {
				const result = await api.cancelTurn(key);
				if (store.sessionKey !== key) return;
				if (!result?.cancelled) {
					store.setCancelling(false);
					store.setRunning(false);
				}
			} catch (error) {
				if (store.sessionKey !== key) return;
				store.setCancelling(false);
				this.fail("取消失败", error);
			}
		},

		async afterTurnDone() {
			const store = this.$store.ap;
			store.setCancelling(false);
			this.loadSessions();
			const key = store.sessionKey;
			if (!key) return;
			try {
				const current = await api.currentSession(key);
				if (store.sessionKey !== key) return;
				store.syncCurrent(current ?? {});
			} catch {
				// turn 已经结束，current 读失败不影响画面。
			}
			await this.$nextTick();
			this.autoScroll();
		},

		async newSession() {
			const store = this.$store.ap;
			if (store.loading) return false;
			store.setLoading(true);
			try {
				const created = await api.newSession();
				const key = created?.session_key;
				if (!key) throw new Error("服务端没有返回 session_key");
				// 先设 key 再 reset：reset 保留当前 key，只清空 transcript。
				store.setSessionKey(key);
				store.reset(null);
				store.setError("");
				this.connect();
				await this.$nextTick();
				this.autoScroll(true);
				this.$refs.input?.focus();
				return true;
			} catch (error) {
				this.fail("新建会话失败", error);
				return false;
			} finally {
				store.setLoading(false);
			}
		},

		async resumeSession(sessionId, selectElement = null) {
			const store = this.$store.ap;
			if (!sessionId) return;
			if (sessionId === store.sessionId && store.sessionKey) return;
			if (store.loading) return;
			store.setLoading(true);
			try {
				const resumed = await api.resumeSession(sessionId);
				const key = resumed?.session_key || sessionId;
				store.setSessionKey(key);
				store.setSession(sessionId);
				store.reset(sessionId);
				try {
					await this.loadHistory(sessionId);
				} catch (error) {
					// history 失败也要连上 SSE；运行中的 session 仍能继续显示增量。
					this.fail("读取历史失败", error);
				}
				// history 只还原 transcript；运行态与 turn 号以 current 为准。
				await this.syncSession(key);
				if (store.sessionKey === key) this.connect();
				store.setError("");
				await this.loadSessions();
				await this.$nextTick();
				this.autoScroll(true);
			} catch (error) {
				this.fail("恢复会话失败", error);
				if (selectElement) selectElement.value = store.sessionId ?? "";
			} finally {
				store.setLoading(false);
			}
		},

		async onSessionSelect(sessionId) {
			const store = this.$store.ap;
			if (!sessionId || sessionId === (store.sessionId ?? "")) return;
			await this.resumeSession(sessionId);
		},

		selectSession(sessionId) {
			return this.onSessionSelect(sessionId);
		},

		async pickDirectory() {
			const store = this.$store.ap;
			if (store.running) {
				store.notice("运行中不能切换工作目录", "warning");
				return;
			}
			if (store.picking) return;

			store.setPicking(true);
			try {
				const result = await api.pickCwd();
				if (result?.cwd) {
					store.setCwd(result.cwd);
					// 服务器已清空所有 session 运行态；前端同步丢弃旧 project 的 transcript，
					// 并为这个标签页分配新的 slot。
					this.disconnect();
					store.setSessionKey(null);
					store.resetAfterCwdChange();
					await this.loadSessions();
					try {
						const created = await api.newSession();
						const key = created?.session_key;
						if (!key) throw new Error("服务端没有返回 session_key");
						store.setSessionKey(key);
						this.connect();
						await this.$nextTick();
						this.autoScroll(true);
					} catch (error) {
						this.fail("新建会话失败", error);
					}
				}
			} catch (error) {
				// 用户主动关掉对话框不是错误。
				if (error?.code === "cancelled") return;
				if (error?.code === "picker_busy") {
					store.notice("目录选择框已经打开", "warning");
					return;
				}
				if (error?.code === "turn_running") {
					store.notice("有会话正在运行，不能切换工作目录", "warning");
					return;
				}
				if (error?.status === 501) {
					store.notice("当前平台不支持系统目录选择", "warning");
					return;
				}
				this.fail("选择目录失败", error);
			} finally {
				store.setPicking(false);
			}
		},

		sessionLabel(session) {
			const id = session?.session_id ?? "";
			const turns = Number.isFinite(session?.turns) ? session.turns : 0;
			return `${id} · ${turns} 轮`;
		},

		sessionTitle(session) {
			return sessionTitle(session);
		},

		sessionMeta(session) {
			return sessionMeta(session);
		},

		onKeydown(event) {
			if (
				event.key === "Enter" &&
				!event.shiftKey &&
				!event.isComposing &&
				event.keyCode !== 229
			) {
				event.preventDefault();
				this.send();
			}
		},

		autoScroll(force = false) {
			const element = this.$refs.messages;
			if (!element) return;
			const distance = element.scrollHeight - element.scrollTop - element.clientHeight;
			if (!force && distance > 120) return;
			element.scrollTop = element.scrollHeight;
		},

		fail(prefix, error) {
			const message = error?.message ? `${prefix}：${error.message}` : prefix;
			this.$store.ap.setError(message);
			this.$store.ap.notice(message, "error");
		},
	}));
}
