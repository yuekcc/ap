// 两条分隔条：指针拖动、方向键、双击复位与宽度持久化。
//
// 拖动监听挂在 window 上而不是分隔条自己：指针一旦离开那条 10px 命中区，
// 事件就不再回到这个元素。松手事件也可能根本收不到（窗口外松手、切走应用），
// 靠「没有按键的 pointermove」、窗口失焦和切后台收尾。
import { effect, effectScope, signal } from "alien-signals";
import { bindAttr, bindBool, ref, setClass } from "../dom.js";
import {
	PANEL_DEFAULT_W,
	PANEL_MAX_W,
	PANEL_MIN_W,
	clampPanelWidth,
} from "../render.js";
import { SPLIT_STORAGE_KEY, writeLocal } from "../prefs.js";

// 键盘一次调 16px，Shift+方向键走 64px。
const RESIZE_STEP_PX = 16;
const RESIZE_STEP_LARGE_PX = 64;

export function mountSplitter({ store }) {
	const app = ref(document, "app");
	const rail = ref(document, "rail-resizer");
	const sessions = ref(document, "sessions-resizer");
	const railPanel = ref(document, "rail");
	const sessionsPanel = ref(document, "sessions-col");
	// 正在拖动的侧栏（"rail" / "sessions" / 空），只影响拖动期间的光标与高亮。
	const resizing = signal("");
	const abort = new AbortController();

	// 屏幕变窄时上限跟着收，否则两个侧栏会把正文挤没。
	function panelMaxWidth() {
		return Math.max(PANEL_MIN_W, Math.min(PANEL_MAX_W, Math.round(globalThis.innerWidth * 0.35)));
	}

	function applyPanelWidth(panel, width) {
		const value = clampPanelWidth(width, PANEL_MIN_W, panelMaxWidth());
		if (panel === "rail") store.setRailWidth(value);
		else store.setSessionsWidth(value);
	}

	function persistSplit() {
		writeLocal(
			SPLIT_STORAGE_KEY,
			JSON.stringify({ rail: store.railWidth(), sessions: store.sessionsWidth() }),
		);
	}

	function endResize() {
		if (!resizing()) return;
		resizing("");
		persistSplit();
	}

	function startResize(event, panel) {
		if (event.button !== 0 || store.layoutMode() !== "wide") return;
		const target = panel === "rail" ? railPanel : sessionsPanel;
		// 拖宽度时不要顺带选中文本。
		event.preventDefault();
		resizing(panel);
		const originX = target.getBoundingClientRect().left;
		// 一次拖动一个 AbortController：结束、失焦、切后台都走同一条收尾路径。
		const drag = new AbortController();
		const onMove = (moveEvent) => {
			// 还在拖动的话指针必然按着；没有按键说明松手事件丢了，就地收尾。
			if (moveEvent.buttons === 0) {
				onEnd();
				return;
			}
			applyPanelWidth(panel, moveEvent.clientX - originX);
			store.requestScroll();
		};
		const onEnd = () => {
			if (!drag.signal.aborted) drag.abort();
			endResize();
		};
		const onVisibilityChange = () => {
			if (document.hidden) onEnd();
		};
		window.addEventListener("pointermove", onMove, { signal: drag.signal });
		window.addEventListener("pointerup", onEnd, { signal: drag.signal });
		window.addEventListener("pointercancel", onEnd, { signal: drag.signal });
		window.addEventListener("blur", onEnd, { signal: drag.signal });
		document.addEventListener("visibilitychange", onVisibilityChange, { signal: drag.signal });
	}

	function onResizeKey(event, panel) {
		const current = panel === "rail" ? store.railWidth() : store.sessionsWidth();
		const step = event.shiftKey ? RESIZE_STEP_LARGE_PX : RESIZE_STEP_PX;
		let next = null;
		if (event.key === "ArrowLeft") next = current - step;
		else if (event.key === "ArrowRight") next = current + step;
		else if (event.key === "Home") next = PANEL_MIN_W;
		else if (event.key === "End") next = panelMaxWidth();
		if (next === null) return;
		event.preventDefault();
		applyPanelWidth(panel, next);
		persistSplit();
	}

	// 双击分隔条回到默认宽度，省得用户把栏拖坏了没法复位。
	function resetPanelWidth(panel) {
		applyPanelWidth(panel, PANEL_DEFAULT_W);
		persistSplit();
	}

	const stopScope = effectScope(() => {
		// 栏折叠或变成浮层时没有分隔条；紧凑屏两栏都不可拖。
		bindBool(rail, "hidden", () => !(store.layoutMode() === "wide" && store.railVisible()));
		bindBool(sessions, "hidden", () => store.layoutMode() !== "wide");
		bindAttr(rail, "aria-valuenow", () => store.railWidth());
		bindAttr(sessions, "aria-valuenow", () => store.sessionsWidth());
		// 只有正在拖的那条高亮，两条一起亮会让人以为两栏都在变。
		bindAttr(rail, "data-active", () => (resizing() === "rail" ? "true" : null));
		bindAttr(sessions, "data-active", () => (resizing() === "sessions" ? "true" : null));
		effect(() => setClass(app, "app--resizing", resizing() !== ""));
		// 栏宽以行内 CSS 变量喂给三栏 flex 布局。
		effect(() => app.style.setProperty("--rail-w", `${store.railWidth()}px`));
		effect(() => app.style.setProperty("--sessions-w", `${store.sessionsWidth()}px`));
	});

	for (const [element, panel] of [
		[rail, "rail"],
		[sessions, "sessions"],
	]) {
		element.addEventListener("pointerdown", (event) => startResize(event, panel), {
			signal: abort.signal,
		});
		element.addEventListener("keydown", (event) => onResizeKey(event, panel), {
			signal: abort.signal,
		});
		element.addEventListener("dblclick", () => resetPanelWidth(panel), {
			signal: abort.signal,
		});
	}

	return function dispose() {
		stopScope();
		abort.abort();
	};
}
