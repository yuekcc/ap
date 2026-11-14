// mermaid 占位块的纯逻辑：源码读取、securityLevel 覆盖拦截、渲染器地址。
// DOM 渲染和 MutationObserver 不在 Node 里测，由浏览器里的人工验证覆盖。
import test from "node:test";
import assert from "node:assert/strict";

import {
	MERMAID_SCRIPT_PATH,
	mermaidSource,
	overridesSecurityLevel,
	watchMermaid,
} from "./mermaid-blocks.js";

test("图表源码从占位块的 code 里读", () => {
	const block = {
		querySelector: (selector) =>
			selector === "code" ? { textContent: "flowchart LR\n  A --> B" } : null,
	};
	assert.equal(mermaidSource(block), "flowchart LR\n  A --> B");
	assert.equal(mermaidSource(null), "");
	assert.equal(mermaidSource({ querySelector: () => null }), "");
});

test("拦截 %%{init}%% 与 frontmatter 对 securityLevel 的覆盖", () => {
	assert.equal(overridesSecurityLevel('%%{init: {"securityLevel": "loose"}}%%\nflowchart LR\nA-->B'), true);
	assert.equal(overridesSecurityLevel("---\nconfig:\n  securityLevel: loose\n---\nflowchart LR\nA-->B"), true);
	assert.equal(overridesSecurityLevel("---\nconfig:\n  theme: dark\n---\nflowchart LR\nA-->B"), false);
	assert.equal(overridesSecurityLevel('%%{init: {"theme": "dark"}}%%\nflowchart LR\nA-->B'), false);
});

test("只是标签里出现 securityLevel 不算覆盖配置", () => {
	assert.equal(overridesSecurityLevel("flowchart LR\n  A[securityLevel] --> B"), false);
});

test("渲染器由 /mermaid.js 按需加载", () => {
	assert.equal(MERMAID_SCRIPT_PATH, "/mermaid.js");
});

test("没有 DOM 时 watchMermaid 返回空操作", () => {
	const stop = watchMermaid(null);
	assert.equal(typeof stop, "function");
	assert.doesNotThrow(stop);
});
