// 页面外壳：三栏的显示/隐藏类、浮层遮罩、断点判断、document.title。
// 断点阈值必须和 styles.css 的 @media 保持一致：这里只记录当前档位，
// 具体布局交给 CSS。
import { effect, effectScope } from "alien-signals";
import { bindVisible, ref } from "../dom.js";

const NARROW_QUERY = "(max-width: 1100px)";
const COMPACT_QUERY = "(max-width: 820px)";

export function mountShell({ store, controller }) {
	const app = ref(document, "app");
	const scrim = ref(document, "scrim");
	const abort = new AbortController();

	const stopScope = effectScope(() => {
		// 折叠的栏整块不参与布局；紧凑屏下同一个类负责关掉浮层。
		effect(() => {
			app.classList.toggle("app--rail-hidden", !store.railVisible());
			app.classList.toggle("app--sessions-hidden", !store.sessionsVisible());
		});
		// 多开几个标签页时，标题跟着当前会话走。
		effect(() => {
			const title = store.currentTitle();
			document.title = title && title !== "新会话" ? `${title} · ap` : "ap";
		});
		bindVisible(scrim, () => store.overlayOpen());
	});

	scrim.addEventListener("click", () => controller.closeOverlays(), { signal: abort.signal });

	// 布局分档交给 CSS 断点，JS 只记录当前档位决定哪侧栏是浮层。
	const narrow = globalThis.matchMedia(NARROW_QUERY);
	const compact = globalThis.matchMedia(COMPACT_QUERY);
	const sync = () => {
		const mode = compact.matches ? "compact" : narrow.matches ? "narrow" : "wide";
		store.setLayoutMode(mode);
		// 变宽后浮层自动收起，避免残留一块盖在正文上的面板。
		if (mode === "wide") controller.closeOverlays();
	};
	sync();
	for (const query of [narrow, compact]) {
		query.addEventListener("change", sync, { signal: abort.signal });
	}

	return function dispose() {
		stopScope();
		abort.abort();
	};
}
