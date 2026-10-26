// 页面交互：加载 config/session/history，订阅 SSE，发送/取消 turn，
// 切换或新建 session，Windows 下选择工作目录。所有异步错误都落成 notice，
// 不让页面因为一个接口 404/501 就白屏。
//
// 多标签页 / 多 project：每个标签页持有自己的 session_key，SSE 只订阅该 session；
// sessionStorage 记住本标签页的 {key, id, cwd}，刷新后优先按真实 id + cwd 恢复。
import { api, eventsUrl } from "./api.js";
import { renderMarkdown } from "./markdown.js";
import { projectName as projectDisplayName, sessionMeta, sessionTitle } from "./render.js";
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
			this.$watch("$store.ap.projectCwd", () => this.persistSession());

			const store = this.$store.ap;
			store.reset(null);
			this.boot();
		},

		// 本标签页的 session 只影响自己；不同标签页各自独立。
		persistSession() {
			const { sessionKey, sessionId, projectCwd } = this.$store.ap;
			try {
				if (!sessionKey && !sessionId) {
					sessionStorage.removeItem(SESSION_STORAGE_KEY);
					return;
				}
				sessionStorage.setItem(
					SESSION_STORAGE_KEY,
					JSON.stringify({
						key: sessionKey ?? "",
						id: sessionId ?? "",
						cwd: projectCwd ?? "",
					}),
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
				const cwd = typeof saved.cwd === "string" ? saved.cwd : "";
				return key || id ? { key, id, cwd } : null;
			} catch {
				return null;
			}
		},

		async boot() {
			const store = this.$store.ap;
			store.setLoading(true);
			try {
				await Promise.all([this.loadConfig(), this.loadProjects()]);
				await this.loadCwd();
				await this.resolveBootSession();
			} finally {
				store.setLoading(false);
				await this.$nextTick();
				this.autoScroll(true);
				this.$refs.input?.focus();
			}
		},

		defaultCwd() {
			return this.$store.ap.config?.cwd ?? "";
		},

		// 服务端列表里没有记录时（slot、刚 pick 的新目录），回落到给定的 cwd。
		projectCwdFor(sessionId, fallback = "") {
			for (const project of this.$store.ap.projects) {
				if (project.sessions?.some((item) => item.session_id === sessionId)) {
					return project.cwd;
				}
			}
			return fallback || this.defaultCwd();
		},

		// 恢复顺序：sessionStorage 的真实 id → slot key → 最近 project 的最新
		// session → 默认目录新建 slot。cwd 随记录一起保存，因为同一个 session id
		// 只有在它自己的 project 里才能读到 transcript。
		async resolveBootSession() {
			const store = this.$store.ap;
			const saved = this.restoreSession();

			if (saved?.id) {
				try {
					await this.openSession(
						saved.id,
						saved.cwd || this.projectCwdFor(saved.id),
						{ reloadProjects: false },
					);
					return;
				} catch (error) {
					this.fail("恢复上次会话失败", error);
				}
			} else if (saved?.key) {
				try {
					const current = await api.currentSession(saved.key);
					if (current?.session_key === saved.key) {
						const cwd = current.cwd || saved.cwd || this.defaultCwd();
						this.activateSession(saved.key, current.session_id || null, cwd);
						store.syncCurrent(current ?? {});
						if (current.session_id) {
							await this.loadHistory(current.session_id, cwd);
						}
						this.connect();
						return;
					}
				} catch (error) {
					this.fail("读取上次会话失败", error);
				}
			}

			for (const project of store.projects) {
				const session = project.sessions?.[0];
				if (!session) continue;
				try {
					await this.openSession(session.session_id, project.cwd, {
						reloadProjects: false,
					});
					return;
				} catch (error) {
					this.fail("恢复最近会话失败", error);
					break;
				}
			}

			await this.newSession(this.defaultCwd());
		},

		activateSession(key, sessionId, cwd) {
			const store = this.$store.ap;
			store.setProjectCwd(cwd);
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

		// 打开一个已有 session：恢复指针 → 载入该 project 的 history → 订阅 SSE。
		// 不做 loading 守卫，boot 与公开入口都复用它。
		async openSession(sessionId, cwd, { reloadProjects = true } = {}) {
			const store = this.$store.ap;
			const resumed = await api.resumeSession(sessionId, cwd);
			const key = resumed?.session_key || sessionId;
			const projectCwd = resumed?.cwd || cwd || this.projectCwdFor(sessionId);
			this.activateSession(key, sessionId, projectCwd);
			store.reset(sessionId);
			try {
				await this.loadHistory(sessionId, projectCwd);
			} catch (error) {
				// history 失败也要连上 SSE；运行中的 session 仍能继续显示增量。
				this.fail("读取历史失败", error);
			}
			// history 只还原 transcript；运行态与 turn 号以 current 为准。
			await this.syncSession(key);
			if (store.sessionKey === key) this.connect();
			store.setError("");
			if (reloadProjects) await this.loadProjects();
			await this.$nextTick();
			this.autoScroll(true);
		},

		async loadConfig() {
			try {
				this.$store.ap.setConfig(await api.config());
			} catch (error) {
				this.fail("读取配置失败", error);
			}
		},

		async loadProjects() {
			try {
				this.$store.ap.setProjects(await api.projects());
			} catch (error) {
				this.fail("读取工作目录失败", error);
			}
		},

		async loadCwd() {
			try {
				const data = await api.cwd();
				if (data?.cwd) this.$store.ap.setCwd(data.cwd);
			} catch {
				// 老服务端可能还没有这个端点；config.cwd 仍可作为回显。
			}
		},

		// 先渲染 history 再订阅 SSE；重叠的 transcript 事件由 seq 在 sse/store 里跳过。
		async loadHistory(sessionId, cwd) {
			const store = this.$store.ap;
			if (!sessionId) {
				store.reset(null);
				return;
			}
			const data = await api.history(sessionId, cwd);
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
			const cwd = store.projectCwd;
			if (!key || !sessionId || !cwd) return;
			try {
				const data = await api.history(sessionId, cwd);
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
				const cwd = store.projectCwd;
				if (sessionId && cwd) {
					const data = await api.history(sessionId, cwd);
					if (store.sessionKey !== key) return;
					store.mergeHistory(data?.events ?? []);
				}
				await this.loadProjects();
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
				await api.startTurn({
					prompt,
					session_key: key,
					cwd: store.projectCwd ?? "",
				});
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
			this.loadProjects();
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

		// 在指定工作目录新建 slot；不传时沿用当前 project，再退到默认目录。
		async newSession(cwd, { focus = true } = {}) {
			const store = this.$store.ap;
			// @click="newSession" 会把 MouseEvent 当参数传进来；只接受路径字符串。
			const requested = typeof cwd === "string" ? cwd.trim() : "";
			const target = requested || store.projectCwd || this.defaultCwd();
			store.setLoading(true);
			try {
				const created = await api.newSession(target);
				const key = created?.session_key;
				if (!key) throw new Error("服务端没有返回 session_key");
				// 先设 key/cwd 再 reset：reset 只清空 transcript。
				store.setProjectCwd(created?.cwd || target);
				store.setSessionKey(key);
				store.reset(null);
				store.setError("");
				this.connect();
				await this.loadProjects();
				await this.$nextTick();
				this.autoScroll(true);
				if (focus) this.$refs.input?.focus();
				return true;
			} catch (error) {
				this.fail("新建会话失败", error);
				return false;
			} finally {
				store.setLoading(false);
			}
		},

		newSessionIn(cwd) {
			return this.newSession(cwd);
		},

		async resumeSession(sessionId, cwd) {
			const store = this.$store.ap;
			if (!sessionId) return;
			if (
				sessionId === store.sessionId &&
				store.sessionKey &&
				cwd === store.projectCwd
			) {
				return;
			}
			if (store.loading) return;
			store.setLoading(true);
			try {
				await this.openSession(sessionId, cwd);
			} catch (error) {
				this.fail("恢复会话失败", error);
			} finally {
				store.setLoading(false);
			}
		},

		selectSession(project, session) {
			if (!project?.cwd || !session?.session_id) return;
			return this.resumeSession(session.session_id, project.cwd);
		},

		async pickDirectory() {
			const store = this.$store.ap;
			if (store.picking) return;

			store.setPicking(true);
			try {
				const result = await api.pickCwd();
				if (result?.cwd) {
					// 目录只是「打开一个 project」，不再替换全局 cwd、也不再清空
					// 其他 project 的 session；直接在该目录开一个新 slot。
					await this.newSession(result.cwd);
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

		projectName(project) {
			return projectDisplayName(project?.cwd);
		},

		isActiveProject(project) {
			return project?.cwd === this.$store.ap.projectCwd;
		},

		// 当前活动 session 还没出现在项目列表里（新 slot 尚未落盘）时，
		// 在所属 project 下显示一条占位会话。
		showsDraftSession(project) {
			if (!this.isActiveProject(project)) return false;
			const sessionId = this.$store.ap.sessionId;
			return !(project.sessions ?? []).some((item) => item.session_id === sessionId);
		},

		showsEmptyProject(project) {
			return !this.isActiveProject(project) && (project.sessions ?? []).length === 0;
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
