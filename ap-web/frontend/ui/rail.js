// 工作空间栏：项目列表、排序菜单、折叠入口。
// 排序菜单是瞬态 UI，用局部 signal 保存；持久化仍由 controller 负责。
import { effect, effectScope, signal } from "alien-signals";
import {
	bindAttr,
	bindBool,
	bindVisible,
	cloneTemplate,
	keyedChildren,
	ref,
	setAttr,
	setBool,
	setClass,
	setText,
} from "../dom.js";
import { projectName } from "../render.js";

export function mountRail({ store, controller }) {
	const list = ref(document, "workspace-list");
	const openButton = ref(document, "rail-open-workspace");
	const toggle = ref(document, "rail-toggle");
	const sortRoot = ref(document, "sort-root");
	const sortTrigger = ref(document, "sort-trigger");
	const sortMenu = ref(document, "sort-menu");
	const sortOpen = signal(false);
	const abort = new AbortController();

	const stopScope = effectScope(() => {
		bindBool(openButton, "disabled", () => store.loading() || store.picking());
		bindAttr(toggle, "aria-expanded", () => String(store.railVisible()));
		// 排序按钮的提示与菜单的展开状态都只反映 UI 偏好。
		effect(() => {
			const label = `排序：${store.sortLabel()}`;
			setAttr(sortTrigger, "title", label);
			setAttr(sortTrigger, "aria-label", label);
		});
		bindAttr(sortTrigger, "aria-expanded", () => String(sortOpen()));
		bindVisible(sortMenu, () => sortOpen());
		for (const item of sortMenu.querySelectorAll("[data-sort]")) {
			const order = item.dataset.sort;
			bindAttr(item, "aria-pressed", () => String(store.sortOrder() === order));
		}
	});

	const stopList = keyedChildren(list, () => store.workspaceProjects(), {
		key: (project) => project?.cwd,
		create(project, itemSignal, signal) {
			const el = cloneTemplate("tpl-workspace-item");
			const name = ref(el, "name");
			el.addEventListener("click", () => controller.switchWorkspace(itemSignal()), { signal });
			return {
				el,
				update(next) {
					const active = next?.cwd === store.projectCwd();
					setText(name, projectName(next?.cwd));
					setClass(el, "is-active", active);
					setAttr(el, "aria-current", active ? "true" : null);
					setAttr(el, "title", next?.cwd ?? "");
					setBool(el, "disabled", store.loading());
				},
			};
		},
	});

	openButton.addEventListener("click", () => controller.openWorkspace(), { signal: abort.signal });
	toggle.addEventListener("click", () => controller.toggleRail(), { signal: abort.signal });
	sortTrigger.addEventListener("click", () => sortOpen(!sortOpen()), { signal: abort.signal });

	for (const item of sortMenu.querySelectorAll("[data-sort]")) {
		item.addEventListener(
			"click",
			() => {
				controller.setSortOrder(item.dataset.sort);
				sortOpen(false);
			},
			{ signal: abort.signal },
		);
	}

	// 点菜单外面收起；按 Esc 收起（焦点在触发按钮或菜单项上时事件会冒泡到这里）。
	document.addEventListener(
		"pointerdown",
		(event) => {
			if (sortOpen() && !sortRoot.contains(event.target)) sortOpen(false);
		},
		{ signal: abort.signal },
	);
	sortRoot.addEventListener(
		"keydown",
		(event) => {
			if (event.key === "Escape") sortOpen(false);
		},
		{ signal: abort.signal },
	);

	return function dispose() {
		stopList();
		stopScope();
		abort.abort();
	};
}
