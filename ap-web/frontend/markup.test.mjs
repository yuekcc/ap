// 布局约定是 docs/web.md 的硬性要求：目录选择入口在输入框旁（composer），
// 不在顶栏。这里直接读 index.html 做结构断言，不引入 DOM 依赖。
import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const indexPath = fileURLToPath(new URL("../index.html", import.meta.url));
const stylesPath = fileURLToPath(new URL("./styles.css", import.meta.url));

test("目录选择入口位于输入区，与发送/取消同一行", async () => {
	const html = await readFile(indexPath, "utf8");
	const headerEnd = html.indexOf("</header>");
	const footerStart = html.indexOf('<footer class="composer">');
	assert.ok(headerEnd > 0, "index.html must have a header");
	assert.ok(footerStart > headerEnd, "composer must follow the header");

	const header = html.slice(0, headerEnd);
	assert.ok(!header.includes("pickDirectory"), "pick action must not live in the topbar");
	assert.ok(!header.includes("选择目录"), "pick button must not live in the topbar");

	const composer = html.slice(footerStart);
	const pickIndex = composer.indexOf('@click="pickDirectory"');
	const actionsIndex = composer.indexOf('class="composer__actions"');
	const inputIndex = composer.indexOf('class="composer__input"');
	assert.ok(inputIndex >= 0 && actionsIndex > inputIndex, "composer row is textarea + actions");
	assert.ok(pickIndex > actionsIndex, "pick button must be inside composer__actions");
	assert.ok(
		composer.includes('x-show="$store.ap.isWindows"'),
		"pick button stays Windows-only",
	);
	assert.ok(
		composer.includes('class="composer__cwd"') &&
			composer.includes('x-text="$store.ap.config?.cwd ?? \'\'"'),
		"composer echoes the selected working directory next to the pick button",
	);
});

test("assistant 文本走 Markdown 渲染，工具输出仍走 textContent", async () => {
	const html = await readFile(indexPath, "utf8");
	assert.ok(
		html.includes('x-html="renderMarkdown(item.text)"'),
		"assistant text must render markdown",
	);
	assert.ok(html.includes("markdown-body"), "markdown output must use github-markdown-css scope");
	assert.ok(
		html.includes('class="tool__output"') && html.includes('x-text="item.streamed || item.result"'),
		"tool output must stay plain text",
	);
	assert.ok(!html.includes("x-html=\"item.streamed"), "tool output must not be rendered as html");
});

test("左侧会话栏承载新会话入口与历史会话", async () => {
	const html = await readFile(indexPath, "utf8");
	const asideStart = html.indexOf('<aside class="sidebar">');
	const asideEnd = html.indexOf("</aside>");
	assert.ok(asideStart >= 0 && asideEnd > asideStart, "index.html must have a sidebar");

	const sidebar = html.slice(asideStart, asideEnd);
	assert.ok(sidebar.includes('class="new-session"'), "new session lives in the sidebar");
	assert.ok(sidebar.includes("selectSession("), "sidebar sessions switch the active session");
	assert.ok(sidebar.includes("sessionTitle(session)"), "sidebar shows formatted session titles");
	assert.ok(
		!sidebar.includes("$store.ap.running"),
		"session actions must stay usable while another session is running",
	);
	assert.ok(!html.includes('id="session-select"'), "topbar select is replaced by the sidebar");
});

test("只提供浅色主题", async () => {
	const css = await readFile(stylesPath, "utf8");
	assert.ok(!css.includes("prefers-color-scheme: dark"), "no dark theme");
	assert.ok(css.includes("color-scheme: light"), "root pins light color scheme");
	assert.ok(css.includes("github-markdown-light.css"), "markdown css must not flip with the OS");
});


