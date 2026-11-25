// 录入框：textarea 的唯一状态源是 store.draft，Enter 发送 / Shift+Enter 换行，
// 运行中显示停止按钮，另有交接入口与当前工作目录回显。
import { effect, effectScope } from "alien-signals";
import {
	afterRender,
	bindAttr,
	bindBool,
	bindText,
	bindVisible,
	ref,
} from "../dom.js";

export function mountComposer({ store, controller }) {
	const input = ref(document, "prompt");
	const sendButton = ref(document, "send");
	const stopButton = ref(document, "stop");
	const stopLabel = ref(document, "stop-label");
	const handoffButton = ref(document, "handoff");
	const cwd = ref(document, "composer-cwd");
	const abort = new AbortController();

	const stopScope = effectScope(() => {
		bindBool(input, "disabled", () => store.loading());
		// 由 store 回写 value 时才覆盖，避免用户输入过程中光标跳回末尾。
		effect(() => {
			const draft = store.draft();
			if (input.value !== draft) input.value = draft;
		});
		bindBool(
			sendButton,
			"disabled",
			() => store.running() || store.loading() || !store.draft().trim(),
		);
		bindVisible(stopButton, () => store.running());
		bindBool(stopButton, "disabled", () => store.cancelling());
		bindText(stopLabel, () => (store.cancelling() ? "取消中" : "停止"));
		bindBool(
			handoffButton,
			"disabled",
			() => store.running() || store.loading() || !store.sessionId(),
		);
		bindVisible(cwd, () => Boolean(store.projectCwd() || store.config()?.cwd));
		bindAttr(cwd, "title", () => store.projectCwd() || store.config()?.cwd || "");
		bindText(cwd, () => store.projectCwd() || store.config()?.cwd || "");
		// controller 只在 boot / 新建会话后请求聚焦，首次挂载不抢焦点。
		effect(() => {
			if (store.focusNonce() === 0) return;
			afterRender(() => input.focus());
		});
	});

	input.addEventListener(
		"input",
		() => store.setDraft(input.value),
		{ signal: abort.signal },
	);

	input.addEventListener(
		"keydown",
		(event) => {
			// isComposing / keyCode 229：输入法合成期间的 Enter 属于选词，不是发送。
			if (
				event.key === "Enter" &&
				!event.shiftKey &&
				!event.isComposing &&
				event.keyCode !== 229
			) {
				event.preventDefault();
				controller.send();
			}
		},
		{ signal: abort.signal },
	);

	sendButton.addEventListener("click", () => controller.send(), { signal: abort.signal });
	stopButton.addEventListener("click", () => controller.cancel(), { signal: abort.signal });
	handoffButton.addEventListener("click", () => controller.sendHandoff(), {
		signal: abort.signal,
	});

	return function dispose() {
		stopScope();
		abort.abort();
	};
}
