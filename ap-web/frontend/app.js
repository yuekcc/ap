// 页面交互：加载 config/current/history，订阅 SSE，发送/取消 turn，
// 切换或新建 session，Windows 下选择工作目录。所有异步错误都落成 notice，
// 不让页面因为一个接口 404/501 就白屏。
import { api } from "./api.js";
import { renderMarkdown } from "./markdown.js";
import { createEventStream } from "./sse.js";

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

			const store = this.$store.ap;
			store.reset(null);
			this.boot();
		},

		async boot() {
			const store = this.$store.ap;
			store.setLoading(true);
			try {
				await Promise.all([this.loadConfig(), this.loadSessions()]);
				await this.loadCwd();

				let sessionId = null;
				try {
					const current = await api.currentSession();
					sessionId = current?.session_id ?? null;
					store.syncCurrent(current ?? {});
				} catch (error) {
					this.fail("读取会话状态失败", error);
				}

				try {
					await this.loadHistory(sessionId);
				} catch (error) {
					this.fail("读取历史失败", error);
				}

				this.connect();
			} finally {
				store.setLoading(false);
				await this.$nextTick();
				this.autoScroll(true);
				this.$refs.input?.focus();
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
			if (this.stream) this.stream.close();
			this.wasOpen = false;
			this.stream = createEventStream({
				getLastSeq: () => this.$store.ap.lastSeq,
				onEvent: (event) => this.$store.ap.handleEvent(event),
				onTurnDone: (payload) => {
					this.$store.ap.handleTurnDone(payload);
					this.afterTurnDone();
				},
				onState: (state) => {
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

		// 首次订阅成功后补齐 history 与 subscribe 之间的空档；失败不打扰用户。
		async fillGap() {
			const store = this.$store.ap;
			const sessionId = store.sessionId;
			if (!sessionId) return;
			try {
				const data = await api.history(sessionId);
				if (this.$store.ap.sessionId !== sessionId) return;
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
			if (this.resyncing || !store.sessionId) return;
			this.resyncing = true;
			try {
				const current = await api.currentSession();
				store.syncCurrent(current ?? {});
				const data = await api.history(store.sessionId);
				store.mergeHistory(data?.events ?? []);
				await this.loadSessions();
				await this.$nextTick();
				this.autoScroll();
			} catch (error) {
				this.fail("重连后同步失败", error);
			} finally {
				this.resyncing = false;
			}
		},

		async send() {
			const store = this.$store.ap;
			const prompt = store.draft.trim();
			if (!prompt || store.running || store.loading) return;

			store.setDraft("");
			store.addUser(prompt);
			store.setRunning(true);
			store.setError("");
			await this.$nextTick();
			this.autoScroll(true);

			try {
				await api.startTurn({ prompt });
			} catch (error) {
				if (error?.status === 409 && error?.code === "turn_running") {
					store.setRunning(true);
					store.notice("已有 turn 正在运行", "warning");
					return;
				}
				store.setRunning(false);
				store.setDraft(prompt);
				this.fail("发送失败", error);
			}
		},

		async cancel() {
			const store = this.$store.ap;
			if (!store.running || store.cancelling) return;
			store.setCancelling(true);
			try {
				await api.cancelTurn();
			} catch (error) {
				store.setCancelling(false);
				this.fail("取消失败", error);
			}
		},

		async afterTurnDone() {
			const store = this.$store.ap;
			store.setCancelling(false);
			this.loadSessions();
			try {
				const current = await api.currentSession();
				store.syncCurrent(current ?? {});
			} catch {
				// turn 已经结束，current 读失败不影响画面。
			}
			await this.$nextTick();
			this.autoScroll();
		},

		async newSession() {
			const store = this.$store.ap;
			if (store.running) {
				store.notice("运行中不能新建会话", "warning");
				return false;
			}
			try {
				await api.newSession();
				store.reset(null);
				store.setError("");
				await this.$nextTick();
				this.autoScroll(true);
				this.$refs.input?.focus();
				return true;
			} catch (error) {
				this.fail("新建会话失败", error);
				return false;
			}
		},

		async resumeSession(sessionId, selectElement = null) {
			const store = this.$store.ap;
			if (!sessionId) return;
			if (store.running) {
				store.notice("运行中不能切换会话", "warning");
				if (selectElement) selectElement.value = store.sessionId ?? "";
				return;
			}
			store.setLoading(true);
			try {
				await api.resumeSession(sessionId);
				await this.loadHistory(sessionId);
				store.setError("");
				await this.$nextTick();
				this.autoScroll(true);
			} catch (error) {
				this.fail("恢复会话失败", error);
				if (selectElement) selectElement.value = store.sessionId ?? "";
			} finally {
				store.setLoading(false);
			}
		},

		async onSessionChange(event) {
			const value = event.target.value;
			const store = this.$store.ap;
			if (value === (store.sessionId ?? "")) return;
			if (!value) {
				await this.newSession();
				event.target.value = this.$store.ap.sessionId ?? "";
				return;
			}
			await this.resumeSession(value, event.target);
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
					// 服务器已清空 session 指针；前端同步丢弃旧 project 的 transcript。
					store.resetAfterCwdChange();
					await this.loadSessions();
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
