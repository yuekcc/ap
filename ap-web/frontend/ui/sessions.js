// 对话栏：按时间分组的当前工作空间对话记录、占位会话、空状态、
// 新建对话与在本机打开工作目录。
import { effectScope } from "alien-signals";
import {
	bindAttr,
	bindBool,
	bindText,
	bindVisible,
	cloneTemplate,
	commentAnchor,
	keyedChildren,
	ref,
	setAttr,
	setBool,
	setClass,
	setText,
	setVisible,
} from "../dom.js";
import { sessionTime, sessionTitle } from "../render.js";

export function mountSessions({ store, controller }) {
	const newSession = ref(document, "new-session");
	const railExpand = ref(document, "rail-expand");
	const openFiles = ref(document, "open-files");
	const openTerminal = ref(document, "open-terminal");
	const list = ref(document, "session-list");
	const draft = ref(document, "session-draft");
	const draftTitle = ref(document, "session-draft-title");
	const draftTime = ref(document, "session-draft-time");
	const draftDot = ref(document, "session-draft-dot");
	const empty = ref(document, "sessions-empty");
	const groupAnchor = commentAnchor(list, "session-groups-anchor");
	const abort = new AbortController();

	const stopScope = effectScope(() => {
		bindBool(newSession, "disabled", () => store.loading());
		// 窄屏时工作空间栏是浮层，展开入口落在对话栏标题行最左。
		bindVisible(railExpand, () => !store.railVisible());
		bindAttr(railExpand, "aria-expanded", () => String(store.railVisible()));
		bindBool(openFiles, "disabled", () => !store.projectCwd());
		bindBool(openTerminal, "disabled", () => !store.projectCwd());
		bindVisible(empty, () => store.showsEmptySessions());

		// 新 slot 还没落盘时，用一条占位会话指向当前活动 session。
		bindVisible(draft, () => store.showsDraftSession());
		bindBool(draft, "disabled", () => store.loading());
		bindText(draftTitle, () => {
			const id = store.sessionId();
			return id ? sessionTitle({ session_id: id }) : "新会话";
		});
		bindText(draftTime, () => (store.running() ? "运行中" : "尚未开始"));
		bindAttr(draftDot, "data-running", () => (store.running() ? "true" : null));
	});

	const stopGroups = keyedChildren(list, () => store.sessionGroups(), {
		key: (group) => group.key,
		anchor: groupAnchor,
		create(group, groupSignal, _signal) {
			const el = cloneTemplate("tpl-session-group");
			const label = ref(el, "label");
			// 组内嵌套一层 keyed list：分组重算时只替换变了的那一项。
			const stopItems = keyedChildren(el, () => groupSignal()?.sessions ?? [], {
				key: (session) => session?.session_id,
				create(session, itemSignal, itemAbort) {
					const item = cloneTemplate("tpl-session-item");
					const title = ref(item, "title");
					const time = ref(item, "time");
					const dot = ref(item, "dot");
					item.addEventListener(
						"click",
						() => controller.selectSession(itemSignal()),
						{ signal: itemAbort },
					);
					return {
						el: item,
						update(next) {
							const active = next?.session_id === store.sessionId();
							setText(title, sessionTitle(next));
							setText(time, sessionTime(next?.ts));
							setClass(item, "is-active", active);
							setAttr(item, "aria-current", active ? "true" : null);
							setAttr(item, "title", next?.session_id ?? "");
							setBool(item, "disabled", store.loading());
							setVisible(dot, Boolean(next?.running) || active);
							setAttr(dot, "data-running", next?.running ? "true" : null);
						},
					};
				},
			});
			return {
				el,
				update(next) {
					setText(label, next?.label ?? "");
				},
				dispose: stopItems,
			};
		},
	});

	newSession.addEventListener("click", () => controller.newSession(), { signal: abort.signal });
	draft.addEventListener("click", () => controller.newSession(), { signal: abort.signal });
	railExpand.addEventListener("click", () => controller.toggleRail(), { signal: abort.signal });
	openFiles.addEventListener("click", () => controller.openWorkdirFiles(), { signal: abort.signal });
	openTerminal.addEventListener(
		"click",
		() => controller.openWorkdirTerminal(),
		{ signal: abort.signal },
	);

	return function dispose() {
		stopGroups();
		stopScope();
		abort.abort();
	};
}
