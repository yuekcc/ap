// 布局约定是 docs/web.md 的硬性要求：目录选择入口收敛到顶部「+」，
// 输入区只回显当前工作空间路径。这里直接读 index.html 做结构断言，不引入 DOM 依赖。
import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const indexPath = fileURLToPath(new URL("../index.html", import.meta.url));
const stylesPath = fileURLToPath(new URL("./styles.css", import.meta.url));

test("输入区只回显工作空间路径，不再重复目录选择入口", async () => {
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
	assert.ok(!composer.includes("pickDirectory"), "composer must not host a directory picker");
	assert.ok(!composer.includes("选择目录"), "composer must not label a directory picker");
	const actionsIndex = composer.indexOf('class="composer__actions"');
	const inputIndex = composer.indexOf('class="composer__input"');
	assert.ok(inputIndex >= 0 && actionsIndex > inputIndex, "composer row is textarea + actions");
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
	assert.match(
		titlebar,
		/>ap<\/span>/,
		"logo mark itself spells ap",
	);
	assert.ok(!titlebar.includes("brand__name"), "logo has no adjacent wordmark label");
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
		sidebar.includes('x-for="group in $store.ap.sessionGroups"'),
		"sidebar groups conversations by natural day",
	);
	assert.ok(
		sidebar.includes('class="session-group__label"') &&
			sidebar.includes('x-text="group.label"'),
		"each day group renders its own label",
	);
	assert.ok(
		sidebar.includes('x-for="session in group.sessions"'),
		"day groups list their conversations",
	);
	assert.ok(
		sidebar.includes("selectSession(session)"),
		"sidebar sessions switch the active conversation",
	);
	assert.ok(sidebar.includes("sessionTitle(session)"), "sidebar shows formatted session titles");
	assert.ok(
		!sidebar.includes('class="sidebar__cwd"'),
		"sidebar no longer repeats the working directory in its footer",
	);
	assert.ok(
		!sidebar.includes(':disabled="$store.ap.running"'),
		"session actions must stay usable while another session is running",
	);
	assert.ok(!html.includes('id="session-select"'), "topbar select is replaced by the sidebar");
});

test("顶栏右侧是在工作目录打开文件管理器与终端的两个按钮", async () => {
	const html = await readFile(indexPath, "utf8");
	const css = await readFile(stylesPath, "utf8");
	const titlebarStart = html.indexOf('<header class="titlebar">');
	const titlebarEnd = html.indexOf("</header>");
	assert.ok(titlebarStart >= 0 && titlebarEnd > titlebarStart, "index.html must have a titlebar");
	const titlebar = html.slice(titlebarStart, titlebarEnd);

	assert.ok(!titlebar.includes("titlebar__env"), "环境标签被两个操作按钮取代");
	assert.ok(!/>本地</.test(titlebar), "titlebar must not keep the 本地 label");

	assert.ok(titlebar.includes('@click="openWorkdirFiles()"'), "打开文件管理器是一个独立按钮");
	assert.ok(titlebar.includes('@click="openWorkdirTerminal()"'), "打开终端是一个独立按钮");
	assert.ok(titlebar.includes('data-icon="folder2-open"'), "文件管理器按钮使用文件夹图标");
	assert.ok(titlebar.includes('data-icon="terminal"'), "终端按钮使用终端图标");
	assert.ok(
		titlebar.includes(':disabled="!$store.ap.projectCwd"'),
		"没有工作目录时按钮不可点",
	);

	assert.ok(css.includes(".titlebar__open-btn"), "titlebar buttons need their own style");
	assert.ok(
		!css.includes(".titlebar__env"),
		"旧的本地标签样式必须一起删掉",
	);
});

test("键位提示进 placeholder，交接入口在输入框下方", async () => {
	const html = await readFile(indexPath, "utf8");
	const css = await readFile(stylesPath, "utf8");

	assert.ok(html.includes("Enter 发送 · Shift+Enter 换行"), "键位提示写进 placeholder");
	assert.ok(
		html.includes('placeholder="给 ap 一个提示词…（Enter 发送 · Shift+Enter 换行）"'),
		"placeholder 同时保留用途提示",
	);
	assert.ok(!html.includes('class="composer__hint"'), "独立的键位提示行已移除");
	assert.ok(!css.includes(".composer__hint"), "旧提示行样式一并删除");

	const composerStart = html.indexOf('<footer class="composer">');
	assert.ok(composerStart > 0, "index.html must have a composer");
	const composer = html.slice(composerStart);
	assert.ok(composer.includes('@click="sendHandoff()"'), "交接入口放在输入区");
	assert.ok(
		composer.includes(
			':disabled="$store.ap.running || $store.ap.loading || !$store.ap.sessionId"',
		),
		"没有真实 session 时不能交接",
	);
	assert.ok(css.includes(".composer__handoff"), "交接按钮有自己的样式");
});

test("工作区顶栏展示 token 用量", async () => {
	const html = await readFile(indexPath, "utf8");
	const topbarStart = html.indexOf('<header class="topbar">');
	const topbarEnd = html.indexOf("</header>", topbarStart);
	assert.ok(topbarStart >= 0 && topbarEnd > topbarStart, "index.html must have a topbar");
	const topbar = html.slice(topbarStart, topbarEnd);
	assert.ok(topbar.includes('class="chip chip--usage"'), "用量和模型/agent 一样是 chip");
	assert.ok(topbar.includes("$store.ap.usageLabel"), "顶栏展示累计 token");
	assert.ok(topbar.includes("$store.ap.usageTitle"), "悬停能看到输入/输出明细");
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
	assert.match(
		css,
		/body\s*\{[^}]*padding:\s*0/,
		"app must fill the viewport without outer margins",
	);
	assert.match(
		css,
		/\.session\.is-active\s*\{[^}]*background:\s*var\(--accent\)/,
		"the current conversation is highlighted in system blue",
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

test("图标来自 bootstrap-icons：源码只留 data-icon 占位，dist 已内联", async () => {
	const html = await readFile(indexPath, "utf8");
	const names = [...html.matchAll(/data-icon="([^"]+)"/g)].map((match) => match[1]);
	assert.ok(names.length >= 5, "index.html must reference bootstrap icons");
	assert.ok(
		!/<svg[^>]*>\s*<path/.test(html),
		"icon paths must not be hand-written in index.html anymore",
	);
	for (const match of html.matchAll(/<svg[^>]*data-icon="[^"]+"[^>]*>/g)) {
		assert.ok(match[0].includes('fill="currentColor"'), "icons must inherit the surrounding color");
	}

	// 图标名必须是 bootstrap-icons 的真实文件名；没装依赖时跳过这半段。
	if (existsSync(new URL("../node_modules/bootstrap-icons/icons/", import.meta.url))) {
		for (const name of new Set(names)) {
			const file = new URL(`../node_modules/bootstrap-icons/icons/${name}.svg`, import.meta.url);
			assert.ok(existsSync(file), `bootstrap-icons/icons/${name}.svg must exist`);
		}
	}

	// dist 是提交进仓库的产物：占位没被内联说明忘了构建。
	const distHtml = await readFile(new URL("../dist/index.html", import.meta.url), "utf8");
	assert.equal(
		distHtml.match(/<svg[^>]*data-icon="[^"]+"[^>]*><\/svg>/g),
		null,
		"dist/index.html 的图标还没内联，先跑 npm --prefix ap-web run build",
	);
});

test("工具卡片默认折叠，头部只留关键行与耗时；思考中在主区域居中显示动画", async () => {
	const html = await readFile(indexPath, "utf8");
	const css = await readFile(stylesPath, "utf8");

	assert.ok(html.includes('<details class="tool"'), "tool card must be a collapsible details");
	assert.ok(!html.includes('<details class="tool" open'), "tool card stays collapsed by default");
	assert.ok(
		html.includes("formatDuration(item.durationMs)"),
		"collapsed head shows the formatted duration",
	);
	assert.ok(html.includes('class="tool__chevron"'), "collapsed head hints at the expand affordance");
	assert.ok(
		html.includes('class="thinking"') && html.includes("$store.ap.thinking"),
		"thinking animation hinges on the thinking flag",
	);

	const thinking = html.indexOf('<div class="thinking"');
	const mainEnd = html.indexOf("</main>");
	assert.ok(thinking > 0 && thinking < mainEnd, "thinking animation lives inside the message area");
	assert.ok(css.includes(".thinking__dots"), "thinking animation has its own dots");
	assert.ok(css.includes("@keyframes thinking-dot"), "thinking dots animate");
	assert.ok(css.includes(".tool[open] .tool__chevron"), "the chevron flips when the card opens");
});


