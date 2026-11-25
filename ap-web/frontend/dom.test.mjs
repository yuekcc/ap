// dom.js 的纯逻辑与最小绑定层：不引入 jsdom，只实现用得到的节点接口。
// 重点守住两件事：值相同不写 DOM；按 key diff 后，未变化的条目仍能响应
// 自己的 item 信号（nested effect 隔离的回归用例）。
import test from "node:test";
import assert from "node:assert/strict";
import { signal } from "alien-signals";
import {
	afterRender,
	bindAttr,
	bindBool,
	bindClass,
	bindText,
	diffKeys,
	keyedChildren,
	setAttr,
	setBool,
	setClass,
	setMarkdown,
	setText,
	setVisible,
} from "./dom.js";

// 只实现 dom.js 会用到的接口：textContent、属性、classList、children 插入。
function fakeElement() {
	const attributes = new Map();
	const classes = new Set();
	const children = [];
	let text = "";
	let textWrites = 0;
	let html = "";
	let htmlWrites = 0;

	const element = {
		parentNode: null,
		children,
		textWrites: () => textWrites,
		htmlWrites: () => htmlWrites,
		hidden: false,
		disabled: false,
		classList: {
			toggle(name, on) {
				if (on) classes.add(name);
				else classes.delete(name);
			},
			contains(name) {
				return classes.has(name);
			},
		},
		setAttribute(name, value) {
			attributes.set(name, String(value));
		},
		getAttribute(name) {
			return attributes.has(name) ? attributes.get(name) : null;
		},
		hasAttribute(name) {
			return attributes.has(name);
		},
		removeAttribute(name) {
			attributes.delete(name);
		},
		appendChild(child) {
			return element.insertBefore(child, null);
		},
		insertBefore(child, reference) {
			if (child.parentNode) child.parentNode.removeChild(child);
			const index = reference === null ? children.length : children.indexOf(reference);
			assert.ok(index >= 0, "insertBefore 的参照节点必须在容器里");
			children.splice(index, 0, child);
			child.parentNode = element;
			return child;
		},
		removeChild(child) {
			const index = children.indexOf(child);
			if (index >= 0) children.splice(index, 1);
			child.parentNode = null;
			return child;
		},
		remove() {
			if (element.parentNode) element.parentNode.removeChild(element);
		},
		get nextSibling() {
			if (!element.parentNode) return null;
			const siblings = element.parentNode.children;
			const index = siblings.indexOf(element);
			return index >= 0 && index + 1 < siblings.length ? siblings[index + 1] : null;
		},
	};

	Object.defineProperty(element, "textContent", {
		get: () => text,
		set: (value) => {
			textWrites += 1;
			text = String(value);
		},
	});
	Object.defineProperty(element, "innerHTML", {
		get: () => html,
		set: (value) => {
			htmlWrites += 1;
			html = String(value);
		},
	});

	return element;
}

test("diffKeys 算出新增、移除与最终顺序", () => {
	assert.deepEqual(diffKeys([], []), { removed: [], added: [], order: [] });
	assert.deepEqual(diffKeys(["a"], ["a", "b"]), {
		removed: [],
		added: ["b"],
		order: ["a", "b"],
	});
	assert.deepEqual(diffKeys(["a", "b"], ["b"]), {
		removed: ["a"],
		added: [],
		order: ["b"],
	});
	assert.deepEqual(diffKeys(["a", "b", "c"], ["c", "a", "b"]), {
		removed: [],
		added: [],
		order: ["c", "a", "b"],
	});
	// 同一 key 换了内容（复用节点，只重跑该条目的 update）。
	assert.deepEqual(diffKeys(["a", "b"], ["a", "c"]), {
		removed: ["b"],
		added: ["c"],
		order: ["a", "c"],
	});
});

test("写入函数在值相同时不碰 DOM", () => {
	const element = fakeElement();

	setText(element, "同一行");
	setText(element, "同一行");
	assert.equal(element.textContent, "同一行");
	assert.equal(element.textWrites(), 1);

	setMarkdown(element, "**粗体**");
	setMarkdown(element, "**粗体**");
	assert.match(element.innerHTML, /<strong>/);
	assert.equal(element.htmlWrites(), 1);

	setAttr(element, "aria-current", "true");
	assert.equal(element.getAttribute("aria-current"), "true");
	setAttr(element, "aria-current", "true");
	setAttr(element, "aria-current", null);
	assert.equal(element.hasAttribute("aria-current"), false);
	setAttr(element, "aria-hidden", false);
	assert.equal(element.hasAttribute("aria-hidden"), false);

	setBool(element, "hidden", true);
	assert.equal(element.hidden, true);
	setVisible(element, true);
	assert.equal(element.hidden, false);

	setClass(element, "is-active", true);
	setClass(element, "is-active", true);
	assert.equal(element.classList.contains("is-active"), true);
	setClass(element, "is-active", false);
	assert.equal(element.classList.contains("is-active"), false);
});

test("bind* 在信号变化时更新，值相同不重复写", () => {
	const label = signal("第一行");
	const hidden = signal(false);
	const element = fakeElement();

	const stopText = bindText(element, () => label());
	const stopVisible = bindBool(element, "hidden", () => hidden());
	const stopClass = bindClass(element, "is-active", () => !hidden());
	const stopAttr = bindAttr(element, "title", () => `路径：${label()}`);

	assert.equal(element.textContent, "第一行");
	assert.equal(element.hidden, false);
	assert.equal(element.classList.contains("is-active"), true);
	assert.equal(element.getAttribute("title"), "路径：第一行");

	label("第二行");
	assert.equal(element.textContent, "第二行");
	assert.equal(element.getAttribute("title"), "路径：第二行");

	hidden(true);
	assert.equal(element.hidden, true);
	assert.equal(element.classList.contains("is-active"), false);

	for (const stop of [stopText, stopVisible, stopClass, stopAttr]) stop();
});

function tracker({ onAbort } = {}) {
	const byKey = new Map();
	const updates = [];
	const create = (item, itemSignal, abortSignal) => {
		const element = fakeElement();
		const entry = { key: item.key, element, signal: itemSignal, aborted: false };
		byKey.set(item.key, entry);
		abortSignal.addEventListener("abort", () => {
			entry.aborted = true;
			onAbort?.(item.key);
		});
		return {
			el: element,
			update(next) {
				updates.push(`${next.key}:${next.text}`);
				setText(element, next.text);
			},
		};
	};
	return { create, byKey, updates };
}

test("keyedChildren 按 key 复用节点、维护顺序并移除过期条目", () => {
	const a = { key: "a", text: "a1" };
	const b = { key: "b", text: "b1" };
	const c = { key: "c", text: "c1" };
	const items = signal([a, b]);
	const container = fakeElement();
	const seen = tracker();
	const dispose = keyedChildren(container, () => items(), {
		key: (item) => item.key,
		create: seen.create,
	});

	assert.deepEqual(
		container.children.map((element) => element.textContent),
		["a1", "b1"],
	);

	// 追加：只创建新条目，旧节点不重建。
	const elementA = container.children[0];
	items([a, b, c]);
	assert.equal(container.children.length, 3);
	assert.equal(container.children[0], elementA, "a 的节点被复用");
	assert.deepEqual(
		container.children.map((element) => element.textContent),
		["a1", "b1", "c1"],
	);

	// 只改 b：b 的 effect 重跑，a / c 的对象没换引用，不重跑。
	const b2 = { key: "b", text: "b2" };
	const updatesBefore = seen.updates.length;
	items([a, b2, c]);
	assert.equal(container.children[1].textContent, "b2");
	assert.deepEqual(seen.updates.slice(updatesBefore), ["b:b2"]);

	// 重排：顺序跟着 items 走，节点仍然复用。
	items([c, a, b2]);
	assert.deepEqual(
		container.children.map((element) => element.textContent),
		["c1", "a1", "b2"],
	);

	// 删除：弹出节点并中止条目级 listener。
	items([c, b2]);
	assert.equal(seen.byKey.get("a").element.parentNode, null);
	assert.equal(seen.byKey.get("a").aborted, true);
	assert.deepEqual(
		container.children.map((element) => element.textContent),
		["c1", "b2"],
	);

	dispose();
	assert.equal(container.children.length, 0);
	assert.equal(seen.byKey.get("c").aborted, true);
});

test("keyedChildren 的条目 effect 不受外层列表 effect 牵连", () => {
	const items = signal([{ key: "a", text: "a1" }]);
	const container = fakeElement();
	const seen = tracker();
	const dispose = keyedChildren(container, () => items(), {
		key: (item) => item.key,
		create: seen.create,
	});

	// 每次列表变化都会让外层 effect 重跑（新数组引用）。
	for (let round = 0; round < 5; round += 1) {
		items([{ key: "a", text: `a${round + 2}` }]);
	}
	assert.equal(container.children[0].textContent, "a6", "条目在多次 diff 后仍能收到更新");

	dispose();
});

test("keyedChildren 支持注释锚点，条目插到锚点之前", () => {
	const container = fakeElement();
	const tail = fakeElement();
	const anchor = fakeElement();
	container.appendChild(tail);
	container.appendChild(anchor);

	const items = signal([{ key: "a", text: "a1" }]);
	const seen = tracker();
	const dispose = keyedChildren(container, () => items(), {
		key: (item) => item.key,
		anchor,
		create: seen.create,
	});

	assert.equal(container.children.length, 3);
	assert.equal(container.children[0], tail);
	assert.equal(container.children[1].textContent, "a1");
	assert.equal(container.children[2], anchor);

	items([
		{ key: "a", text: "a1" },
		{ key: "b", text: "b1" },
	]);
	assert.deepEqual(
		container.children.map((element) => element.textContent),
		["", "a1", "b1", ""],
		"条目排在 tail 之后、锚点之前",
	);

	dispose();
});

test("afterRender 一帧只跑一次，重复登记同一回调不重复执行", async () => {
	let runs = 0;
	const job = () => {
		runs += 1;
	};
	afterRender(job);
	afterRender(job);
	afterRender(job);
	await new Promise((resolve) => setTimeout(resolve, 10));
	assert.equal(runs, 1);

	afterRender(job);
	await new Promise((resolve) => setTimeout(resolve, 10));
	assert.equal(runs, 2);
});
