// 对话正文栏：标题行、状态点、token 用量、当前文件、消息列表、思考动画、
// 回到底部与滚动跟随。
//
// 列表按 item.key 做 O(n) diff：一次 flush 只有内容变化的条目重跑它自己的
// effect；消息节点仍是 .messages 的直接子元素，content-visibility 规则不变。
import { effect, effectScope } from "alien-signals";
import {
	afterRender,
	bindAttr,
	bindBool,
	bindText,
	bindVisible,
	cloneTemplate,
	commentAnchor,
	keyedChildren,
	ref,
	setAttr,
	setClass,
	setMarkdown,
	setText,
	setVisible,
} from "../dom.js";
import { formatDuration } from "../render.js";
import { watchMermaid } from "../mermaid-blocks.js";

// 离底部多近算「贴底」：留一点余量，滚轮多走一格不至于立刻弹按钮。
const BOTTOM_GAP_PX = 32;
// 贴底跟随的余量；超过这个距离就不打断用户向上翻看。
const FOLLOW_GAP_PX = 120;

function prefersReducedMotion() {
	return (
		typeof globalThis.matchMedia === "function" &&
		globalThis.matchMedia("(prefers-reduced-motion: reduce)").matches
	);
}

// 按条目 kind 选模板；每种 kind 一个模板，不在一个节点里串条件。
function createItem(item, itemSignal, signal) {
	switch (item?.kind) {
		case "user": {
			const el = cloneTemplate("tpl-message-user");
			const text = ref(el, "text");
			return {
				el,
				update(next) {
					setText(text, next?.text ?? "");
				},
			};
		}
		case "assistant": {
			const el = cloneTemplate("tpl-message-assistant");
			const body = ref(el, "body");
			return {
				el,
				update(next) {
					const streaming = !next?.ended;
					setMarkdown(body, next?.text ?? "");
					setClass(body, "is-streaming", streaming);
					setAttr(body, "data-streaming", streaming ? "true" : null);
				},
			};
		}
		case "tool": {
			const el = cloneTemplate("tpl-tool-card");
			const card = ref(el, "tool");
			const head = ref(el, "head");
			const name = ref(el, "name");
			const args = ref(el, "args");
			const duration = ref(el, "duration");
			const exit = ref(el, "exit");
			const output = ref(el, "output");
			const error = ref(el, "error");
			const note = ref(el, "note");
			return {
				el,
				update(next) {
					setAttr(card, "data-status", next?.status ?? "running");
					setAttr(head, "title", next?.args || next?.name || "");
					setText(name, next?.name ?? "");
					setText(args, next?.args ?? "");
					setVisible(args, Boolean(next?.args));
					const durationMs = next?.durationMs;
					setText(duration, formatDuration(durationMs));
					setVisible(duration, durationMs !== null && durationMs !== undefined);
					const exitCode = next?.exitCode;
					const hasExit = exitCode !== null && exitCode !== undefined;
					setText(exit, hasExit ? `exit ${exitCode}` : "");
					setVisible(exit, hasExit);
					const body = next?.streamed || next?.result || "";
					setText(output, body);
					setVisible(output, Boolean(body));
					setText(error, next?.error ?? "");
					setVisible(error, Boolean(next?.error));
					setVisible(note, Boolean(next?.truncated));
				},
			};
		}
		case "notice": {
			const el = cloneTemplate("tpl-notice");
			const notice = ref(el, "notice");
			return {
				el,
				update(next) {
					const tone = next?.tone ?? "muted";
					setText(notice, next?.text ?? "");
					setAttr(notice, "data-tone", tone);
					// 错误提示立刻被读屏播报，普通提示不打断。
					setAttr(notice, "role", tone === "error" ? "alert" : null);
				},
			};
		}
		default: {
			const el = cloneTemplate("tpl-notice");
			return {
				el,
				update() {
					setVisible(el, false);
				},
			};
		}
	}
}

export function mountThread({ store, controller }) {
	const title = ref(document, "topbar-title");
	const refresh = ref(document, "topbar-title-btn");
	const status = ref(document, "status");
	const usage = ref(document, "usage");
	const sessionsToggle = ref(document, "topbar-sessions-btn");
	const filePill = ref(document, "thread-file");
	const fileButton = ref(document, "thread-file-btn");
	const fileName = ref(document, "thread-file-name");
	const messages = ref(document, "messages");
	const empty = ref(document, "messages-empty");
	const emptyLoading = ref(document, "messages-empty-loading");
	const emptyHint = ref(document, "messages-empty-hint");
	const thinking = ref(document, "thinking");
	const scrollButton = ref(document, "scroll-bottom");
	const anchor = commentAnchor(messages, "messages-anchor");
	const abort = new AbortController();

	let scrollHandle = 0;

	function autoScroll(force = false) {
		const distance = messages.scrollHeight - messages.scrollTop - messages.clientHeight;
		// 只在用户本来就贴底时跟随，避免打断向上翻看。
		if (!force && distance > FOLLOW_GAP_PX) return;
		messages.scrollTop = messages.scrollHeight;
	}

	// 同一个回调引用让 afterRender 去重：一帧里 items / thinking / sessionId 同时变，
	// 也只需要读一次 scrollHeight。
	const followScroll = () => autoScroll(false);

	function scrollToBottom() {
		if (prefersReducedMotion()) {
			messages.scrollTop = messages.scrollHeight;
			return;
		}
		messages.scrollTo({ top: messages.scrollHeight, behavior: "smooth" });
		// 滚动过程中翻上来的旧消息会从占位高度换成真实高度，平滑滚动的目标
		// 高度因此会变短；滚完再贴一次底，按钮才真的收起。
		const stick = () => {
			messages.scrollTop = messages.scrollHeight;
		};
		if ("onscrollend" in globalThis) {
			messages.addEventListener("scrollend", stick, { once: true });
		} else {
			setTimeout(stick, 400);
		}
	}

	const stopScope = effectScope(() => {
		bindText(title, () => store.currentTitle());
		bindBool(
			refresh,
			"disabled",
			() => store.running() || store.loading() || store.titlePending() || !store.sessionId(),
		);
		bindVisible(status, () => store.statusKind() !== "idle");
		bindAttr(status, "data-state", () => store.statusKind());
		bindAttr(status, "title", () => store.statusLabel());
		bindAttr(status, "aria-label", () => store.statusLabel());
		bindVisible(usage, () => store.usageLabel() !== "");
		bindAttr(usage, "title", () => store.usageTitle());
		bindText(usage, () => store.usageLabel());
		bindVisible(sessionsToggle, () => store.layoutMode() === "compact");
		bindAttr(sessionsToggle, "aria-expanded", () => String(store.sessionsVisible()));
		bindVisible(filePill, () => Boolean(store.currentFile()));
		bindAttr(fileButton, "title", () => `复制路径：${store.currentFile()}`);
		bindText(fileName, () => store.currentFileName());
		bindAttr(messages, "aria-busy", () => (store.running() ? "true" : null));
		bindVisible(empty, () => store.items().length === 0);
		bindVisible(emptyLoading, () => store.loading());
		bindVisible(emptyHint, () => !store.loading());
		bindVisible(thinking, () => store.thinking());
		bindVisible(scrollButton, () => !store.atBottom());

		// 内容变化会改变消息区高度；滚动跟随统一推到 DOM 写完后的下一帧。
		effect(() => {
			store.items();
			afterRender(followScroll);
		});
		// 思考动画出现/消失、切换 session 也会改变高度，贴底时才跟一次。
		effect(() => {
			store.thinking();
			store.sessionId();
			afterRender(followScroll);
		});
		// controller 的滚动请求：force 值决定要不要无条件贴底。
		effect(() => {
			const request = store.scrollRequest();
			if (request.nonce === 0) return;
			const force = request.force;
			afterRender(() => autoScroll(force));
		});
	});

	const stopItems = keyedChildren(messages, () => store.items(), {
		key: (item) => item?.key,
		anchor,
		create: createItem,
	});

	// mermaid 图表是异步换成 SVG 的；换完高度变了，用户本来贴底时继续跟上。
	const stopMermaid = watchMermaid(messages, {
		onRendered: () => {
			if (store.atBottom()) autoScroll(true);
		},
	});

	refresh.addEventListener("click", () => controller.refreshTitle(), { signal: abort.signal });
	sessionsToggle.addEventListener("click", () => controller.toggleSessions(), {
		signal: abort.signal,
	});
	fileButton.addEventListener("click", () => controller.copyCurrentPath(), { signal: abort.signal });
	scrollButton.addEventListener("click", scrollToBottom, { signal: abort.signal });

	// 滚动事件按帧节流，避免每个 scroll 都读一次 scrollHeight。
	messages.addEventListener(
		"scroll",
		() => {
			if (scrollHandle) return;
			scrollHandle = requestAnimationFrame(() => {
				scrollHandle = 0;
				const distance = messages.scrollHeight - messages.scrollTop - messages.clientHeight;
				store.setAtBottom(distance <= BOTTOM_GAP_PX);
			});
		},
		{ passive: true, signal: abort.signal },
	);

	return function dispose() {
		if (scrollHandle) cancelAnimationFrame(scrollHandle);
		stopMermaid();
		stopItems();
		stopScope();
		abort.abort();
	};
}
