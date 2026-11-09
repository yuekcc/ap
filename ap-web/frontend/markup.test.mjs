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

test("左侧会话栏按工作目录分组，并承载新会话入口", async () => {
	const html = await readFile(indexPath, "utf8");
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
		sidebar.includes('x-for="project in $store.ap.sidebarProjects"'),
		"sidebar groups sessions by working directory",
	);
	assert.ok(
		sidebar.includes("newSessionIn(project.cwd)"),
		"each project can start its own session",
	);
	assert.ok(
		sidebar.includes("selectSession(project, session)"),
		"sidebar sessions switch the active session within their project",
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

	// 控件保持胶囊/圆形，与 iOS 的默认形状一致。
	assert.match(
		css,
		/\.composer__send\s*\{[^}]*border-radius:\s*50%/,
		"send button stays circular",
	);

	// 动效必须能被减少动态偏好关掉。
	assert.ok(css.includes("prefers-reduced-motion: reduce"), "motion must respect reduced-motion");
});


