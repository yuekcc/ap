// 布局约定是 docs/web.md 的硬性要求：目录选择入口在输入框旁（composer），
// 顶部「+」只负责打开新的工作空间。这里直接读 index.html 做结构断言，不引入 DOM 依赖。
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
	assert.ok(headerEnd > 0, "index.html must have a titlebar");
	assert.ok(footerStart > headerEnd, "composer must follow the titlebar");

	const header = html.slice(0, headerEnd);
	assert.ok(!header.includes("pickDirectory"), "pick action must not live in the titlebar");
	assert.ok(!header.includes("选择目录"), "pick button must not live in the titlebar");
	assert.ok(header.includes("openWorkspace()"), "titlebar + opens a workspace, not the picker");

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
			composer.includes("$store.ap.projectCwd"),
		"composer echoes the active project working directory",
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

test("顶部是工作空间标签，侧栏承载新对话与当前空间的对话记录", async () => {
	const html = await readFile(indexPath, "utf8");

	const titlebarStart = html.indexOf('<header class="titlebar">');
	const titlebarEnd = html.indexOf("</header>");
	assert.ok(titlebarStart >= 0 && titlebarEnd > titlebarStart, "index.html must have a titlebar");
	const titlebar = html.slice(titlebarStart, titlebarEnd);
	assert.ok(titlebar.includes('class="brand__mark"'), "logo lives in the titlebar");
	assert.ok(
		titlebar.includes('x-for="project in $store.ap.workspaceProjects"'),
		"working directories become workspace tabs",
	);
	assert.ok(
		titlebar.includes("switchWorkspace(project)"),
		"clicking a tab switches the active workspace",
	);
	assert.ok(
		titlebar.includes('@click="openWorkspace()"'),
		"the + button opens a new workspace",
	);

	const asideStart = html.indexOf('<aside class="sidebar">');
	const asideEnd = html.indexOf("</aside>");
	assert.ok(asideStart >= 0 && asideEnd > asideStart, "index.html must have a sidebar");

	const sidebar = html.slice(asideStart, asideEnd);
	assert.ok(sidebar.includes('class="new-session"'), "new session lives in the sidebar");
	assert.ok(
		sidebar.includes('@click="newSession()"'),
		"new session must not receive the click event as its cwd argument",
	);
	assert.ok(
		sidebar.includes('x-for="session in $store.ap.activeSessions"'),
		"sidebar lists conversations of the active workspace only",
	);
	assert.ok(
		sidebar.includes("selectSession(session)"),
		"sidebar sessions switch the active conversation",
	);
	assert.ok(sidebar.includes("sessionTitle(session)"), "sidebar shows formatted session titles");
	assert.ok(
		!sidebar.includes(':disabled="$store.ap.running"'),
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

test("iOS 18 扁平风格：系统色分组底 + 白卡片，不用模糊与渐变", async () => {
	const css = await readFile(stylesPath, "utf8");

	// 系统色与形状收敛到 :root 变量，改主题只改一处。
	for (const token of ["--bg-grouped:", "--fill:", "--separator:", "--accent:", "--radius-card:", "--radius-field:"]) {
		assert.ok(css.includes(token), `root must define ${token}`);
	}

	// 扁平化：不允许玻璃材质、背景模糊、渐变画布或投影。
	assert.ok(!css.includes("backdrop-filter"), "flat design must not blur the backdrop");
	assert.ok(!css.includes("radial-gradient"), "canvas must be a flat system background");
	assert.ok(!css.includes("linear-gradient"), "flat design must not use gradients");
	assert.ok(!css.includes("--glass"), "glass tokens belong to the previous theme");

	// 页面底色是 iOS 的分组背景，卡片是白色。
	assert.match(
		css,
		/body\s*\{[^}]*background:\s*var\(--bg-grouped\)/,
		"body must use the grouped system background",
	);
	assert.match(
		css,
		/\.tool\s*\{[^}]*background:\s*var\(--bg\)/,
		"cards must sit on white",
	);

	// 新布局：顶部工作空间标签 + 左栏对话记录 + 右栏工作区。
	assert.match(
		css,
		/\.app__body\s*\{[^}]*grid-template-columns:\s*var\(--sidebar-w\)/,
		"body splits into a conversation sidebar and a workspace",
	);
	assert.ok(css.includes(".workspace-tab.is-active"), "active workspace tab needs its own state");

	// 控件保持胶囊/圆形，与 iOS 的默认形状一致。
	assert.match(
		css,
		/\.composer__send\s*\{[^}]*border-radius:\s*50%/,
		"send button stays circular",
	);

	// 动效必须能被减少动态偏好关掉。
	assert.ok(css.includes("prefers-reduced-motion: reduce"), "motion must respect reduced-motion");
});


