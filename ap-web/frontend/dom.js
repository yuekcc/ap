// 最小 DOM 绑定层：克隆 <template>、按信号写节点、按 key 复用列表节点。
// 这里不是模板引擎，也不做表达式求值：动态值一律由调用方以函数传入，用户数据
// 只经 textContent / 受控属性写入（Markdown 是唯一例外，见 bindMarkdown）。
//
// 写入函数（set*）可以脱离 response 环境单独调用；bind* 只是把 set* 包进
// effect。ui/*.js 的 mount() 把它们建在自己的 effectScope 里，退出时统一释放。
import { effect, effectScope, getActiveSub, setActiveSub, signal } from "alien-signals";
import { renderMarkdown } from "./markdown.js";

// 取静态骨架里的 [data-ref] 节点。缺失说明 index.html 与挂载代码不同步，
// 直接抛错比静默跳过好排查。
export function ref(root, name) {
	const element = root.querySelector(`[data-ref="${name}"]`);
	if (!element) throw new Error(`index.html 缺少 data-ref="${name}"`);
	return element;
}

// 注释锚点：列表条目按 key 插到锚点之前。注释不参与 :nth-last-child，
// .event 的 content-visibility 规则不会因为锚点错位。
export function commentAnchor(container, marker) {
	for (const node of container.childNodes) {
		if (node.nodeType === 8 && String(node.data).trim() === marker) return node;
	}
	throw new Error(`index.html 缺少注释锚点 <!-- ${marker} -->`);
}

// <template> 只放可信静态结构；克隆出来的一层元素就是条目根节点。
export function cloneTemplate(id) {
	const template = document.getElementById(id);
	if (!template) throw new Error(`index.html 缺少 <template id="${id}">`);
	const element = template.content.cloneNode(true).firstElementChild;
	if (!element) throw new Error(`<template id="${id}"> 里没有元素`);
	return element;
}

// ---------------------------------------------------------------------------
// 写入函数：值相同就不碰 DOM，避免流式渲染时整棵子树反复失效。
// ---------------------------------------------------------------------------

export function setText(element, value) {
	const next = value === null || value === undefined ? "" : String(value);
	if (element.textContent !== next) element.textContent = next;
}

// 每个节点记住自己上一次写入的 HTML：Markdown 渲染有缓存，比较字符串即可。
const renderedMarkdown = new WeakMap();

export function setMarkdown(element, value) {
	const html = renderMarkdown(value);
	if (renderedMarkdown.get(element) === html) return;
	renderedMarkdown.set(element, html);
	element.innerHTML = html;
}

export function setAttr(element, name, value) {
	if (value === null || value === undefined || value === false) {
		if (element.hasAttribute(name)) element.removeAttribute(name);
		return;
	}
	const next = String(value);
	if (element.getAttribute(name) !== next) element.setAttribute(name, next);
}

// 布尔属性（hidden / disabled）走 property，避免 getAttribute 返回 "" 的歧义。
export function setBool(element, name, value) {
	const next = Boolean(value);
	if (element[name] !== next) element[name] = next;
}

export function setClass(element, name, value) {
	element.classList.toggle(name, Boolean(value));
}

export function setVisible(element, value) {
	setBool(element, "hidden", !value);
}

// ---------------------------------------------------------------------------
// effect 包装：只在 mount() 的 effectScope 里调用，不要放进别的 effect 体内，
// 否则外层 effect 重跑时会把它们当成 nested effects 清掉。
// ---------------------------------------------------------------------------

export function bindText(element, get) {
	return effect(() => setText(element, get()));
}

export function bindMarkdown(element, get) {
	return effect(() => setMarkdown(element, get()));
}

export function bindAttr(element, name, get) {
	return effect(() => setAttr(element, name, get()));
}

export function bindBool(element, name, get) {
	return effect(() => setBool(element, name, get()));
}

export function bindClass(element, name, get) {
	return effect(() => setClass(element, name, get()));
}

export function bindVisible(element, get) {
	return effect(() => setVisible(element, get()));
}

// ---------------------------------------------------------------------------
// 一帧一次：effect 里写完 DOM 后如果还要读 scrollHeight / getBoundingClientRect，
// 用 afterRender 推到下一帧，替代 Alpine 的 $nextTick。
// ---------------------------------------------------------------------------

const pendingJobs = new Set();
let frameHandle = 0;

export function afterRender(job) {
	pendingJobs.add(job);
	if (frameHandle) return;
	const schedule =
		typeof globalThis.requestAnimationFrame === "function"
			? globalThis.requestAnimationFrame
			: (callback) => setTimeout(callback, 0);
	frameHandle = schedule(() => {
		frameHandle = 0;
		const jobs = Array.from(pendingJobs);
		pendingJobs.clear();
		for (const run of jobs) run();
	});
}

// ---------------------------------------------------------------------------
// 按 key 的列表：一次 O(n) diff，只让内容变化的条目重跑自己的 effect。
// ---------------------------------------------------------------------------

// 纯函数：给定前后两组 key，算出去掉了哪些、新加了哪些、最终顺序。
export function diffKeys(previous, next) {
	const previousKeys = Array.isArray(previous) ? previous : [];
	const nextKeys = Array.isArray(next) ? next : [];
	const previousSet = new Set(previousKeys);
	const nextSet = new Set(nextKeys);
	return {
		removed: previousKeys.filter((key) => !nextSet.has(key)),
		added: nextKeys.filter((key) => !previousSet.has(key)),
		order: nextKeys.slice(),
	};
}

// keyedChildren(container, getItems, { key, create, anchor })
//
// create(item, itemSignal, abortSignal) 返回 { el, update }；update 在这个条目
// 自己的 effect 里跑。列表本身只负责 key → 节点映射、增删和顺序，不做虚拟 DOM。
//
// 条目 effect 必须挂在 keyedChildren 自己的 owner scope 下，而不是外层列表
// effect 下：alien-signals 默认把新 effect 挂到当前 active effect 上，外层
// effect 下次 diff 时会清掉这些 nested effects，未变化的条目就再也收不到更新。
export function keyedChildren(container, getItems, { key = (item) => item.key, create, anchor = null } = {}) {
	if (!container) throw new Error("keyedChildren 需要一个容器");
	if (typeof getItems !== "function" || typeof key !== "function" || typeof create !== "function") {
		throw new Error("keyedChildren 需要 getItems / key / create");
	}

	const entries = new Map();
	let owner = null;
	const stopOwner = effectScope(() => {
		owner = getActiveSub();
	});

	function disposeEntry(entry) {
		entry.dispose?.();
		entry.stop();
		entry.abort.abort();
		entry.el.remove();
	}

	function createEntry(item, itemKey) {
		const itemSignal = signal(item);
		const abort = new AbortController();
		const prevSub = setActiveSub(owner);
		let entry = null;
		try {
			const stopScope = effectScope(() => {
				const mounted = create(item, itemSignal, abort.signal);
				const stopUpdate = effect(() => mounted.update(itemSignal()));
				entry = {
					key: itemKey,
					el: mounted.el,
					item: itemSignal,
					current: item,
					abort,
					dispose: mounted.dispose,
					stop() {
						stopUpdate();
						stopScope();
					},
				};
			});
		} finally {
			setActiveSub(prevSub);
		}
		return entry;
	}

	const stopList = effect(() => {
		const value = getItems();
		const items = Array.isArray(value) ? value : [];

		const byKey = new Map();
		for (const item of items) {
			const itemKey = key(item);
			if (!byKey.has(itemKey)) byKey.set(itemKey, item);
		}

		for (const [itemKey, entry] of entries) {
			if (byKey.has(itemKey)) continue;
			disposeEntry(entry);
			entries.delete(itemKey);
		}

		for (const [itemKey, item] of byKey) {
			const entry = entries.get(itemKey);
			if (!entry) {
				entries.set(itemKey, createEntry(item, itemKey));
			} else if (entry.current !== item) {
				entry.current = item;
				// 这里只 set 不读：读 item 信号会把外层列表 effect 变成条目的订阅者。
				entry.item(item);
			}
		}

		// 从后往前插到锚点前；已经就位的节点 nextSibling 就是游标，跳过写入。
		const order = Array.from(byKey.keys());
		let cursor = anchor;
		for (let index = order.length - 1; index >= 0; index -= 1) {
			const entry = entries.get(order[index]);
			// 还没进容器的节点 parentNode 为空，nextSibling 也是 null，必须单独判断。
			if (entry.el.parentNode !== container || entry.el.nextSibling !== cursor) {
				container.insertBefore(entry.el, cursor);
			}
			cursor = entry.el;
		}
	});

	return function dispose() {
		stopList();
		for (const entry of entries.values()) disposeEntry(entry);
		entries.clear();
		stopOwner();
	};
}
