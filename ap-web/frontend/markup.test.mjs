// 三栏工作台的布局约定是 docs/internal/web.md 的硬性要求：左栏工作空间、
// 中栏对话列表、右栏对话正文。这里直接读 index.html / ui/*.js 做结构断言，
// 不引入 DOM 依赖，也不跑模板运行时。
import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const indexPath = fileURLToPath(new URL("../index.html", import.meta.url));
const stylesPath = fileURLToPath(new URL("./styles.css", import.meta.url));
const renderPath = fileURLToPath(new URL("./render.js", import.meta.url));
const packagePath = fileURLToPath(new URL("../package.json", import.meta.url));

const UI_FILES = ["shell.js", "rail.js", "sessions.js", "thread.js", "composer.js", "splitter.js"];

async function loadSources() {
	const [html, css, render, pkg, ...ui] = await Promise.all([
		readFile(indexPath, "utf8"),
		readFile(stylesPath, "utf8"),
		readFile(renderPath, "utf8"),
		readFile(packagePath, "utf8"),
		...UI_FILES.map((name) => readFile(new URL(`./ui/${name}`, import.meta.url), "utf8")),
	]);
	return { html, css, render, pkg: JSON.parse(pkg), ui, uiSource: ui.join("\n") };
}

// <template> 的整段源码：模板本身不是 DOM，直接用字符串断言结构。
function templateBody(html, id) {
	const start = html.indexOf(`<template id="${id}">`);
	assert.ok(start >= 0, `index.html 必须有 <template id="${id}">`);
	const end = html.indexOf("</template>", start);
	assert.ok(end > start, `模板 ${id} 没有闭合`);
	return html.slice(start, end);
}

test("index.html 不再包含 Alpine 指令，视图挂在 data-ref / template 上", async () => {
	const { html, uiSource, pkg } = await loadSources();

	for (const directive of [
		"x-data",
		"x-init",
		"x-show",
		"x-for",
		"x-if",
		"x-text",
		"x-html",
		"x-model",
		"x-cloak",
		"$store",
		"$refs",
		"$nextTick",
		"$watch",
		"@click",
		"@keydown",
		"@scroll",
		"@pointerdown",
		":class=",
		":style=",
	]) {
		assert.ok(!html.includes(directive), `index.html 不能残留 ${directive}`);
	}
	assert.ok(!/\son[a-z]+="/.test(html), "不写内联事件属性，监听在 ui/*.js 里挂");
	assert.ok(!html.includes("Alpine"), "页面不引用 Alpine");
	assert.ok(!uiSource.includes("Alpine"), "ui/*.js 不引用 Alpine");
	assert.ok(uiSource.includes("addEventListener("), "监听一律走 addEventListener");
	assert.equal(pkg.dependencies.alpinejs, undefined, "运行时不再依赖 alpinejs");
});

test("目录选择入口在工作空间栏，输入区只回显工作空间路径", async () => {
	const { html, uiSource } = await loadSources();

	const railStart = html.indexOf('<aside class="rail"');
	const railEnd = html.indexOf("</aside>", railStart);
	assert.ok(railStart >= 0 && railEnd > railStart, "index.html must have a workspace rail");
	const rail = html.slice(railStart, railEnd);
	assert.ok(!rail.includes("pickDirectory"), "工作空间栏列目录，不弹系统选择器");
	assert.ok(
		rail.includes('data-ref="rail-open-workspace"'),
		"工作空间栏的 + 打开一个工作空间",
	);
	assert.ok(uiSource.includes("controller.openWorkspace()"), "+ 调用 openWorkspace");

	const footerStart = html.indexOf('<footer class="composer">');
	assert.ok(footerStart > railEnd, "composer must follow the rails");
	const composer = html.slice(footerStart);
	assert.ok(!composer.includes("pickDirectory"), "composer must not host a directory picker");
	assert.ok(!composer.includes("选择目录"), "composer must not label a directory picker");
	const inputIndex = composer.indexOf('class="composer__input"');
	const cwdIndex = composer.indexOf('class="composer__cwd"');
	assert.ok(inputIndex >= 0 && cwdIndex > inputIndex, "composer row is textarea + cwd + actions");
	assert.ok(
		composer.includes('data-ref="composer-cwd"'),
		"composer echoes the active project working directory",
	);
	assert.ok(
		uiSource.includes('bindVisible(cwd, () => Boolean(store.projectCwd() || store.config()?.cwd))'),
		"cwd 回显由 projectCwd / config.cwd 派生",
	);
});

test("assistant 文本走 Markdown 渲染，工具输出仍走 textContent", async () => {
	const { html, ui, uiSource } = await loadSources();
	const assistant = templateBody(html, "tpl-message-assistant");
	const tool = templateBody(html, "tpl-tool-card");

	assert.ok(
		assistant.includes('data-render="markdown"'),
		"assistant 模板标出 Markdown 安全边界",
	);
	assert.ok(assistant.includes("markdown-body"), "markdown 输出使用 github-markdown-css 作用域");
	assert.ok(
		assistant.includes('data-ref="body"') && assistant.includes("is-streaming") === false,
		"流式标记由 ui/thread.js 绑定，模板只放结构",
	);
	assert.ok(
		tool.includes('data-ref="output"') && tool.includes('data-render="text"'),
		"工具输出是纯文本，不能标成 markdown",
	);
	assert.ok(!tool.includes("markdown-body"), "工具卡片不套 Markdown 样式");
	assert.ok(!html.includes("x-html"), "页面不再有 x-html 求值");

	const thread = ui[UI_FILES.indexOf("thread.js")];
	assert.ok(thread.includes("setMarkdown(body"), "只有 assistant 条目走 Markdown");
	assert.ok(thread.includes("setText(output"), "工具输出走 textContent");
	assert.ok(!thread.includes("innerHTML"), "ui/*.js 不直接写 HTML，Markdown 只经 dom.setMarkdown");
	assert.ok(
		uiSource.includes("data-streaming"),
		"流式标记仍然写回 data-streaming，mermaid 等结束再渲染",
	);
});

test("左栏是工作空间列表，中栏是新对话与当前空间的对话记录", async () => {
	const { html, css, uiSource } = await loadSources();

	const railStart = html.indexOf('<aside class="rail"');
	const railEnd = html.indexOf("</aside>", railStart);
	const rail = html.slice(railStart, railEnd);
	assert.ok(rail.includes('class="brand__mark"'), "logo 在左栏标题行");
	assert.match(rail, />ap<\/span>/, "logo mark itself spells ap");
	assert.ok(!rail.includes("brand__name"), "logo has no adjacent wordmark label");
	assert.ok(
		rail.includes('data-ref="workspace-list"'),
		"工作目录成为左栏列表容器",
	);
	assert.ok(
		uiSource.includes("keyedChildren(list, () => store.workspaceProjects()"),
		"工作空间列表按 key 复用节点",
	);
	assert.ok(uiSource.includes("controller.switchWorkspace(itemSignal())"), "点列表项切换工作空间");
	assert.ok(rail.includes('data-icon="arrow-down-up"'), "排序入口在左栏标题行");
	assert.ok(rail.includes('data-ref="rail-toggle"'), "折叠入口在左栏标题行");
	assert.ok(rail.includes('data-sort="recent"') && rail.includes('data-sort="name"'), "排序菜单两个选项");

	const sessionsStart = html.indexOf('<aside class="sessions-col"');
	const sessionsEnd = html.indexOf("</aside>", sessionsStart);
	assert.ok(sessionsStart >= 0 && sessionsEnd > sessionsStart, "index.html must have a session rail");
	const sessions = html.slice(sessionsStart, sessionsEnd);
	assert.ok(sessions.includes('class="new-session"'), "新对话在中栏");
	assert.ok(css.includes(".session-group__label"), "组标题有自己的样式");
	// 「新对话」是 outline 按钮：描边 + 透明底，内容居中而不是左对齐。
	const newSessionRule = css.slice(css.indexOf(".new-session {"), css.indexOf(".new-session:hover"));
	assert.ok(newSessionRule.includes("justify-content: center"), "图标和文字居中");
	assert.ok(newSessionRule.includes("border: 1px solid var(--accent-line)"), "outline 用描边而不是填充");
	assert.ok(newSessionRule.includes("background: transparent"), "未悬停时是透明底");
	assert.ok(!newSessionRule.includes("background: var(--accent-tint)"), "底色只在悬停时出现");
	assert.ok(sessions.includes('data-ref="new-session"'), "新对话按钮有挂载点");
	assert.ok(!sessions.includes("pickDirectory"), "目录选择只在工作空间栏");
	assert.ok(
		uiSource.includes("keyedChildren(list, () => store.sessionGroups()"),
		"对话记录按时间分组渲染",
	);
	assert.ok(
		templateBody(html, "tpl-session-group").includes('class="session-group__label"'),
		"每组自带标题（今天 / 昨天 / 7天内 / 更早）",
	);
	assert.ok(
		uiSource.includes("groupSignal()?.sessions"),
		"组内再嵌套一层 keyed list",
	);
	assert.ok(uiSource.includes("controller.selectSession(itemSignal())"), "点条目切换当前对话");
	assert.ok(uiSource.includes("setText(title, sessionTitle(next))"), "显示格式化后的会话标题");
	assert.ok(uiSource.includes("setText(time, sessionTime(next?.ts))"), "第二行是本地时间");
	assert.ok(!sessions.includes('class="sidebar__cwd"'), "中栏不重复工作目录");
	assert.ok(
		!uiSource.includes("store.running()\")\n\t\t\t\t: undefined"),
		"session actions must stay usable while another session is running",
	);
	assert.ok(!html.includes('id="session-select"'), "topbar select is replaced by the rail");
});

test("工作空间栏可折叠，窄屏下两个侧栏都是浮层", async () => {
	const { html, css, uiSource } = await loadSources();

	assert.ok(html.includes('<aside class="rail" id="workspace-rail"'), "左栏暴露折叠入口控制的 id");
	assert.ok(html.includes('aria-controls="workspace-rail"'), "折叠入口指向左栏");
	assert.ok(uiSource.includes("controller.toggleRail()"), "折叠入口调用 toggleRail");
	assert.ok(
		uiSource.includes('app.classList.toggle("app--rail-hidden", !store.railVisible())'),
		"折叠状态由 store 派生",
	);

	assert.ok(css.includes(".app--rail-hidden .rail"), "折叠后左栏不参与布局");
	assert.match(css, /\.rail\s*\{[^}]*width:\s*var\(--rail-w\)/, "左栏宽度来自变量");

	const narrowStart = css.indexOf("@media (max-width: 1100px)");
	assert.ok(narrowStart > 0, "styles.css 有窄屏断点");
	const narrow = css.slice(narrowStart, css.indexOf("@media (max-width: 820px)"));
	assert.ok(narrow.includes("position: fixed"), "窄屏左栏浮在正文之上");

	const compact = css.slice(css.indexOf("@media (max-width: 820px)"));
	assert.ok(compact.includes(".sessions-col"), "紧凑屏对话栏也是浮层");
	assert.ok(compact.includes(".topbar__sessions-btn"), "紧凑屏从标题行打开对话栏");
	assert.ok(
		uiSource.includes('bindVisible(sessionsToggle, () => store.layoutMode() === "compact")'),
		"紧凑屏按钮只在紧凑档位出现",
	);
});

test("两个侧栏的分隔条可拖动可键盘调整，宽度写回 CSS 变量", async () => {
	const { html, css, render, ui } = await loadSources();
	const splitter = ui[UI_FILES.indexOf("splitter.js")];

	const railEnd = html.indexOf("</aside>");
	const separators = [...html.matchAll(/class="resizer"[\s\S]*?><\/div>/g)].map((m) => m[0]);
	assert.equal(separators.length, 2, "两处分隔条：工作空间栏后、对话栏后");

	const min = Number(render.match(/PANEL_MIN_W = (\d+)/)[1]);
	const max = Number(render.match(/PANEL_MAX_W = (\d+)/)[1]);
	const fallback = Number(render.match(/PANEL_DEFAULT_W = (\d+)/)[1]);

	const [railSplit, sessionsSplit] = separators;
	for (const split of separators) {
		assert.ok(split.includes('role="separator"'), "分隔条是 window splitter");
		assert.ok(split.includes('aria-orientation="vertical"'), "竖向分隔");
		assert.ok(split.includes('tabindex="0"'), "键盘能聚焦");
		// 边界和 render.js 里的常量同源，改数字忘了改标记会在这里断。
		assert.ok(split.includes(`aria-valuemin="${min}"`), "取值下限与常量一致");
		assert.ok(split.includes(`aria-valuemax="${max}"`), "取值上限与常量一致");
		assert.ok(split.includes(`aria-valuenow="${fallback}"`), "初始宽度与默认值一致");
		assert.ok(/data-panel="\w+"/.test(split), "两条分隔条各自声明管哪一栏");
		assert.ok(split.includes('data-ref="rail-resizer"') || split.includes('data-ref="sessions-resizer"'), "分隔条有挂载点");
	}
	assert.ok(railSplit.includes("工作空间栏宽度"), "第一处分隔条管工作空间栏");
	assert.ok(sessionsSplit.includes("对话栏宽度"), "第二处分隔条管对话栏");
	assert.ok(railEnd > 0 && html.indexOf(railSplit) > railEnd, "第一处分隔条排在左栏之后");

	// 拖动监听挂在 window 上：指针离开那 10px 命中区也要继续算宽度。
	assert.ok(
		splitter.includes('window.addEventListener("pointermove", onMove') &&
			splitter.includes('window.addEventListener("pointerup", onEnd') &&
			splitter.includes("const drag = new AbortController()"),
		"拖动期间由 window 接管指针事件，松手时中止监听",
	);
	assert.ok(!html.includes("setPointerCapture"), "不依赖 pointer capture：离开命中区后会丢事件");
	// 松手事件可能根本收不到（窗口外松手、切走应用）：没有按键的移动必须收尾。
	assert.ok(
		splitter.includes("if (moveEvent.buttons === 0)") && splitter.includes("onEnd()"),
		"裸移指针时结束拖动，不让栏跟着光标走",
	);
	assert.ok(
		splitter.includes('window.addEventListener("blur", onEnd') &&
			splitter.includes('document.addEventListener("visibilitychange", onVisibilityChange'),
		"失焦和切后台也要收尾",
	);
	assert.ok(splitter.includes("event.button !== 0"), "只响应主键拖动");
	assert.ok(
		splitter.includes('event.key === "ArrowLeft"') && splitter.includes('event.key === "Home"'),
		"方向键与 Home/End 调整宽度",
	);
	assert.ok(splitter.includes("RESIZE_STEP_LARGE_PX"), "Shift 走大步长");
	assert.ok(
		splitter.includes('app.style.setProperty("--rail-w"') &&
			splitter.includes('app.style.setProperty("--sessions-w"'),
		"宽度以行内 CSS 变量喂给三栏布局",
	);
	assert.ok(splitter.includes('setClass(app, "app--resizing"'), "拖动期间给页面加状态类");
	assert.ok(splitter.includes("persistSplit"), "拖动结束后持久化");

	assert.ok(css.includes('.resizer[data-active="true"]::after'), "高亮只给正在拖的那一条");
	assert.ok(!css.includes(".app--resizing .resizer"), "拖动状态类不再一把点亮所有分隔条");
	// CSS 里的初始宽度是首帧回退值，必须和 render.js 的默认值同源。
	const defaultRem = fallback / 16;
	assert.ok(css.includes(`--rail-w: ${defaultRem}rem`), "初始栏宽与默认值一致");
	assert.ok(css.includes(`--sessions-w: ${defaultRem}rem`), "两栏默认等宽");
	assert.match(css, /\.resizer\s*\{[^}]*cursor:\s*col-resize/, "分隔条是拖动光标");
	assert.match(css, /\.resizer\s*\{[^}]*touch-action:\s*none/, "拖动时不触发滚动");
	assert.match(css, /\.app--resizing\s*\{[^}]*user-select:\s*none/, "拖动期间不选中文本");
	const narrowStart = css.indexOf("@media (max-width: 1100px)");
	const narrowBlock = css.slice(narrowStart, css.indexOf("@media (max-width: 820px)"));
	assert.ok(
		narrowBlock.includes(".resizer") && narrowBlock.includes("display: none"),
		"窄屏侧栏是浮层，分隔条一并收起",
	);
});

test("标题行左侧是标题与刷新，右侧是状态与用量", async () => {
	const { html, css, ui } = await loadSources();
	const thread = ui[UI_FILES.indexOf("thread.js")];

	const topbarStart = html.indexOf('<header class="topbar">');
	const topbarEnd = html.indexOf("</header>", topbarStart);
	assert.ok(topbarStart >= 0 && topbarEnd > topbarStart, "index.html must have a topbar");
	const topbar = html.slice(topbarStart, topbarEnd);

	const headingIndex = topbar.indexOf('class="topbar__heading"');
	const rightIndex = topbar.indexOf('class="topbar__right"');
	assert.ok(headingIndex >= 0 && rightIndex > headingIndex, "标题行只有标题组和右侧状态两块");
	assert.ok(topbar.slice(headingIndex, rightIndex).includes('data-ref="topbar-title"'), "标题在左");
	assert.ok(topbar.slice(rightIndex).includes('data-ref="status"'), "状态在右");
	assert.ok(!topbar.includes("topbar__side"), "三列居中布局已删除");
	assert.ok(thread.includes("bindText(title, () => store.currentTitle())"), "标题来自派生值");
	assert.ok(
		thread.includes('bindAttr(status, "data-state", () => store.statusKind())'),
		"状态点由 statusKind 驱动",
	);

	const topbarRule = css.slice(css.indexOf(".topbar {"), css.indexOf(".topbar__sessions-btn"));
	assert.ok(topbarRule.includes("display: flex"), "标题行是一条 flex 行");
	assert.ok(!topbarRule.includes("grid-template-columns"), "不再用等宽 1fr 把标题钉在正中");
});

test("对话栏标题行是在工作目录打开文件管理器与终端的两个按钮", async () => {
	const { html, css, ui } = await loadSources();
	const sessions = ui[UI_FILES.indexOf("sessions.js")];

	const headStart = html.indexOf('class="sessions__head"');
	const headEnd = html.indexOf('class="new-session"');
	assert.ok(headStart >= 0 && headEnd > headStart, "两个按钮在对话栏标题行");
	const head = html.slice(headStart, headEnd);

	assert.ok(head.includes('data-ref="open-files"'), "打开文件管理器是一个独立按钮");
	assert.ok(head.includes('data-ref="open-terminal"'), "打开终端是一个独立按钮");
	assert.ok(head.includes('data-icon="folder2-open"'), "文件管理器按钮使用文件夹图标");
	assert.ok(head.includes('data-icon="terminal"'), "终端按钮使用终端图标");
	assert.ok(
		sessions.includes('bindBool(openFiles, "disabled", () => !store.projectCwd())') &&
			sessions.includes('bindBool(openTerminal, "disabled", () => !store.projectCwd())'),
		"没有工作目录时按钮不可点",
	);

	assert.ok(css.includes(".sessions__actions"), "两个按钮有自己的容器样式");
	assert.ok(!css.includes(".titlebar__open-btn"), "旧顶栏按钮样式必须一起删掉");
	assert.ok(!css.includes(".titlebar"), "旧顶栏样式必须一起删掉");
});

test("键位提示进 placeholder，交接入口在输入框下方", async () => {
	const { html, css, ui } = await loadSources();
	const composer = ui[UI_FILES.indexOf("composer.js")];

	assert.ok(html.includes("Enter 发送 · Shift+Enter 换行"), "键位提示写进 placeholder");
	assert.ok(
		html.includes('placeholder="给 ap 一个提示词…（Enter 发送 · Shift+Enter 换行）"'),
		"placeholder 同时保留用途提示",
	);
	assert.ok(!html.includes('class="composer__hint"'), "独立的键位提示行已移除");
	assert.ok(!css.includes(".composer__hint"), "旧提示行样式一并删除");

	const composerStart = html.indexOf('<footer class="composer">');
	assert.ok(composerStart > 0, "index.html must have a composer");
	const composerHtml = html.slice(composerStart);
	assert.ok(composerHtml.includes('data-ref="handoff"'), "交接入口放在输入区");
	assert.ok(
		composer.includes('bindBool(\n\t\t\thandoffButton,\n\t\t\t"disabled",\n\t\t\t() => store.running() || store.loading() || !store.sessionId(),\n\t\t)'),
		"没有真实 session 时不能交接",
	);
	assert.ok(css.includes(".composer__handoff"), "交接按钮有自己的样式");
	assert.ok(
		composer.includes("event.key === \"Enter\"") &&
			composer.includes("event.isComposing") &&
			composer.includes("event.keyCode !== 229"),
		"输入法合成期间的 Enter 不发送",
	);
});

test("标题行右侧展示 token 用量", async () => {
	const { html, ui } = await loadSources();
	const thread = ui[UI_FILES.indexOf("thread.js")];
	const topbarStart = html.indexOf('<header class="topbar">');
	const topbarEnd = html.indexOf("</header>", topbarStart);
	const topbar = html.slice(topbarStart, topbarEnd);
	assert.ok(topbar.includes('class="chip chip--usage"'), "用量和模型/agent 一样是 chip");
	assert.ok(topbar.includes('data-ref="usage"'), "顶栏用量 chip 有挂载点");
	assert.ok(thread.includes("bindText(usage, () => store.usageLabel())"), "顶栏展示累计 token");
	assert.ok(thread.includes('bindAttr(usage, "title", () => store.usageTitle())'), "悬停能看到输入/输出明细");
});

test("只提供浅色主题", async () => {
	const { css } = await loadSources();
	assert.ok(!css.includes("prefers-color-scheme: dark"), "no dark theme");
	assert.ok(css.includes("color-scheme: light"), "root pins light color scheme");
	assert.ok(css.includes("github-markdown-light.css"), "markdown css must not flip with the OS");
});

test("iOS 18 扁平风格：系统色分组底 + 白卡片，不用模糊与渐变", async () => {
	const { css } = await loadSources();

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
	assert.match(css, /\.tool\s*\{[^}]*background:\s*var\(--bg\)/, "cards must sit on white");

	// 三栏工作台：两栏定宽，正文吃掉剩下的宽度。
	assert.match(css, /\.rail\s*\{[^}]*width:\s*var\(--rail-w\)/, "左栏宽度来自变量");
	assert.match(css, /\.sessions-col\s*\{[^}]*width:\s*var\(--sessions-w\)/, "中栏宽度来自变量");
	assert.match(css, /\.workspace\s*\{[^}]*flex:\s*1 1 auto/, "正文吃掉剩余宽度");
	assert.ok(css.includes(".workspace-item.is-active"), "当前工作空间项需要自己的状态");
	assert.match(css, /body\s*\{[^}]*padding:\s*0/, "app must fill the viewport without outer margins");
	assert.match(
		css,
		/\.session\.is-active\s*\{[^}]*background:\s*var\(--accent-tint\)/,
		"the current conversation is highlighted with the system blue tint",
	);

	// 控件保持胶囊/圆形，与 iOS 的默认形状一致。
	assert.match(css, /\.composer__send\s*\{[^}]*border-radius:\s*50%/, "send button stays circular");

	// 动效必须能被减少动态偏好关掉。
	assert.ok(css.includes("prefers-reduced-motion: reduce"), "motion must respect reduced-motion");
});

test("隐藏节点用 hidden 属性，x-cloak 规则已删除", async () => {
	const { css, html } = await loadSources();
	assert.ok(css.includes("[hidden] {"), "[hidden] 必须能压过组件的 display");
	assert.ok(!css.includes("[x-cloak]"), "x-cloak 规则随 Alpine 一起删除");
	// 初始应该收起的节点直接在 HTML 上写 hidden，避免首帧闪现。
	for (const ref of ["sort-menu", "scrim", "thread-file", "thinking", "scroll-bottom"]) {
		assert.match(
			html,
			new RegExp(`data-ref="${ref}"[^>]*\\bhidden\\b`),
			`${ref} 初始应隐藏`,
		);
	}
});

test("图标来自 bootstrap-icons：源码只留 data-icon 占位，dist 已内联", async () => {
	const { html } = await loadSources();
	const names = [...html.matchAll(/data-icon="([^"]+)"/g)].map((match) => match[1]);
	assert.ok(names.length >= 10, "index.html 与模板都引用 bootstrap 图标");
	assert.ok(!/<svg[^>]*>\s*<path/.test(html), "icon paths must not be hand-written in index.html anymore");
	for (const match of html.matchAll(/<svg[^>]*data-icon="[^"]+"[^>]*>/g)) {
		assert.ok(match[0].includes('fill="currentColor"'), "icons must inherit the surrounding color");
	}

	// 图标名必须是 bootstrap-icons 的真实文件名；没装依赖时跳过这半段。
	if (existsSync(new URL("../node_modules/bootstrap-icons/icons/", import.meta.url))) {
		for (const name of new Set(names)) {
			const file = new URL(`../node_modules/bootstrap-icons/icons/${name}.svg`, import.meta.url);
			assert.ok(existsSync(file), `bootstrap-icons/icons/${name}.svg must exist`);
		}
	}

	// build.mjs 对整个 index.html 做替换，模板里的图标也会被内联。
	const distHtml = await readFile(new URL("../dist/index.html", import.meta.url), "utf8");
	assert.equal(
		distHtml.match(/<svg[^>]*data-icon="[^"]+"[^>]*><\/svg>/g),
		null,
		"dist/index.html 的图标还没内联，先跑 npm --prefix ap-web run build",
	);
	// dist 不提交进仓库，但本地构建必须包含模板与 data-ref。
	assert.ok(distHtml.includes('id="tpl-message-assistant"'), "dist 里包含模板");
	assert.ok(distHtml.includes('data-ref="messages"'), "dist 里包含挂载点");
});

test("对话项是标题 + 时间 + 状态点，工具卡片和当前文件各有状态指示", async () => {
	const { html, css, ui } = await loadSources();
	const sessions = ui[UI_FILES.indexOf("sessions.js")];
	const sessionItem = templateBody(html, "tpl-session-item");

	assert.ok(sessionItem.includes('class="session__title"'), "第一行是标题");
	assert.ok(sessionItem.includes('data-ref="time"'), "第二行左侧是本地时间");
	assert.ok(sessionItem.includes('data-ref="dot"'), "第二行右侧是状态点");
	assert.ok(
		sessions.includes('setAttr(dot, "data-running", next?.running ? "true" : null)'),
		"状态点由 running 派生",
	);
	assert.ok(
		css.includes('.session__dot[data-running="true"]') && css.includes("animation: pulse"),
		"运行中的对话是脉冲点",
	);

	assert.ok(templateBody(html, "tpl-tool-card").includes('class="tool__dot"'), "工具卡片头部有状态点");
	for (const state of ["running", "ok", "error"]) {
		assert.ok(
			css.includes(`.tool[data-status="${state}"] .tool__dot`),
			`工具状态 ${state} 有自己的点色`,
		);
	}

	// 「当前修改的文件」默认不显示，只有工具改写文件后才由 store 派生出路径。
	assert.ok(html.includes('data-ref="thread-file" hidden'), "当前文件指示默认隐藏");
	assert.ok(ui[UI_FILES.indexOf("thread.js")].includes("controller.copyCurrentPath()"), "点一下复制完整路径");
	assert.ok(css.includes(".thread-file__btn"), "指示本身是一个小胶囊");
});

test("工具卡片默认折叠，头部只留关键行与耗时；思考中在主区域居中显示动画", async () => {
	const { html, css, ui } = await loadSources();
	const tool = templateBody(html, "tpl-tool-card");

	assert.ok(tool.includes("<details"), "tool card must be a collapsible details");
	assert.ok(!tool.includes("<details open"), "tool card stays collapsed by default");
	assert.ok(tool.includes('data-ref="duration"'), "collapsed head shows the formatted duration");
	assert.ok(tool.includes('class="tool__chevron"'), "collapsed head hints at the expand affordance");
	assert.ok(tool.includes('data-ref="note"'), "截断提示留在折叠卡片里");
	assert.ok(
		html.includes('class="thinking" data-ref="thinking"') &&
			ui[UI_FILES.indexOf("thread.js")].includes("bindVisible(thinking, () => store.thinking())"),
		"thinking animation hinges on the thinking flag",
	);

	const thinking = html.indexOf('class="thinking"');
	const mainEnd = html.indexOf("</main>");
	assert.ok(thinking > 0 && thinking < mainEnd, "thinking animation lives inside the message area");
	assert.ok(css.includes(".thinking__dots"), "thinking animation has its own dots");
	assert.ok(css.includes("@keyframes thinking-dot"), "thinking dots animate");
	assert.ok(css.includes(".tool[open] .tool__chevron"), "the chevron flips when the card opens");
});

test("顶栏标题旁有刷新按钮，运行中不可点", async () => {
	const { html, css, ui } = await loadSources();
	const thread = ui[UI_FILES.indexOf("thread.js")];

	assert.ok(html.includes('class="topbar__heading"'), "title and refresh share one heading row");
	const headingIndex = html.indexOf('class="topbar__heading"');
	const titleIndex = html.indexOf('data-ref="topbar-title"', headingIndex);
	assert.ok(titleIndex > headingIndex, "heading keeps the session title");

	const buttonIndex = html.indexOf('class="topbar__title-btn"', headingIndex);
	assert.ok(buttonIndex > titleIndex, "refresh button sits next to the title");
	const button = html.slice(buttonIndex, html.indexOf("</button>", buttonIndex));
	assert.ok(button.includes('data-ref="topbar-title-btn"'), "refresh button has a mount point");
	assert.ok(button.includes('data-icon="arrow-clockwise"'), "refresh button uses an inline icon");
	assert.ok(
		thread.includes('() => store.running() || store.loading() || store.titlePending() || !store.sessionId()'),
		"refresh button is disabled while a turn or another refresh is running",
	);
	assert.ok(css.includes(".topbar__title-btn"), "refresh button has its own style");
});

test("消息区翻上去时露出「回到底部」，旧消息延迟渲染", async () => {
	const { html, css, ui } = await loadSources();
	const thread = ui[UI_FILES.indexOf("thread.js")];

	const threadIndex = html.indexOf('<div class="thread">');
	const mainIndex = html.indexOf('class="messages"', threadIndex);
	const buttonIndex = html.indexOf('class="scroll-bottom"', threadIndex);
	const threadEnd = html.indexOf("</div>", buttonIndex);
	assert.ok(threadIndex >= 0 && mainIndex > threadIndex, "消息区包在 thread 容器里");
	assert.ok(buttonIndex > mainIndex, "回到底部按钮在消息区之后");
	assert.ok(threadEnd > buttonIndex, "回到底部按钮和消息区同一个容器");

	assert.ok(thread.includes('messages.addEventListener(\n\t\t"scroll",'), "滚动位置按帧读取");
	assert.ok(thread.includes('{ passive: true, signal: abort.signal }'), "滚动监听是 passive");
	assert.ok(thread.includes('bindAttr(messages, "aria-busy"'), "运行中把消息区标成 busy");
	assert.ok(html.includes('data-icon="arrow-down"'), "回到底部按钮用向下的箭头");

	const button = html.slice(buttonIndex, html.indexOf("</button>", buttonIndex));
	assert.ok(button.includes("scroll-bottom"), "按钮有自己的类");
	assert.ok(thread.includes("bindVisible(scrollButton, () => !store.atBottom())"), "贴底时按钮收起");
	assert.ok(button.includes('aria-label="回到底部"'), "按钮有可读的名字");
	assert.ok(thread.includes("scrollToBottom"), "按钮滚动到最新消息");
	assert.ok(thread.includes("prefersReducedMotion()"), "减少动态偏好下直接跳到底");

	assert.ok(css.includes(".scroll-bottom"), "回到底部按钮有自己的样式");
	assert.ok(
		css.includes(".event:nth-last-child(n + 8)") && css.includes("content-visibility: auto"),
		"离开底部的旧消息延迟渲染",
	);
	assert.ok(css.includes("contain-intrinsic-size"), "延迟渲染要带占位高度，否则滚动会跳");
	assert.ok(css.includes("scrollbar-gutter: stable"), "滚动条出现时内容不横跳");
});

test("消息条目是 .messages 的直接子元素，按 kind 选模板", async () => {
	const { html, ui } = await loadSources();
	assert.ok(html.includes("<!-- messages-anchor -->"), "消息列表有注释锚点");
	const thread = ui[UI_FILES.indexOf("thread.js")];
	assert.ok(thread.includes('commentAnchor(messages, "messages-anchor")'), "锚点由 thread.js 查找");
	for (const id of ["tpl-message-user", "tpl-message-assistant", "tpl-tool-card", "tpl-notice"]) {
		assert.match(
			templateBody(html, id),
			/^<template id="[^"]+">\s*<div class="event">/,
			`${id} 的根节点是 .event，保持 content-visibility 的选择器成立`,
		);
		assert.ok(thread.includes(`"${id}"`), `thread.js 使用 ${id}`);
	}
	assert.ok(
		thread.includes('case "assistant"') && thread.includes('case "tool"'),
		"每种 kind 一个模板，不在一个节点里串条件",
	);
});

test("当前工作空间与当前会话带 aria-current，动态错误用 alert 播报", async () => {
	const { ui } = await loadSources();
	const rail = ui[UI_FILES.indexOf("rail.js")];
	const sessions = ui[UI_FILES.indexOf("sessions.js")];
	const thread = ui[UI_FILES.indexOf("thread.js")];

	assert.ok(
		rail.includes('setAttr(el, "aria-current", active ? "true" : null)'),
		"工作空间标签标出当前位置",
	);
	assert.ok(
		sessions.includes('setAttr(item, "aria-current", active ? "true" : null)'),
		"会话条目标出当前会话",
	);
	assert.ok(
		thread.includes('setAttr(notice, "role", tone === "error" ? "alert" : null)'),
		"错误提示立刻被读屏播报，普通提示不打断",
	);
});

test("data-ref、模板 id 与 ui/*.js 对齐", async () => {
	const { html, uiSource } = await loadSources();

	const refs = new Set([...html.matchAll(/data-ref="([^"]+)"/g)].map((match) => match[1]));
	assert.ok(refs.size >= 20, "静态骨架与模板都通过 data-ref 暴露挂载点");

	// 每个 ref(root, "name") 都能在 HTML 里找到同名节点。
	for (const match of uiSource.matchAll(/\bref\([^,]+,\s*"([^"]+)"\)/g)) {
		assert.ok(refs.has(match[1]), `ui/*.js 引用了不存在的 data-ref="${match[1]}"`);
	}

	// 每个 cloneTemplate 的模板都存在，每个模板都被至少一处引用。
	const templateIds = new Set([...html.matchAll(/<template id="([^"]+)"/g)].map((match) => match[1]));
	for (const match of uiSource.matchAll(/cloneTemplate\("([^"]+)"\)/g)) {
		assert.ok(templateIds.has(match[1]), `ui/*.js 引用了不存在的模板 ${match[1]}`);
	}
	for (const id of templateIds) {
		assert.ok(uiSource.includes(`"${id}"`), `模板 ${id} 没有被 ui/*.js 使用`);
	}

	// 每个区域至少有一个挂载点。
	for (const name of ["app", "rail", "sessions-col", "messages", "prompt", "rail-resizer", "sessions-resizer", "scrim"]) {
		assert.ok(refs.has(name), `区域缺少 data-ref="${name}"`);
	}
});

test("package.json 换成 alien-signals，测试脚本覆盖 store/dom", async () => {
	const { pkg } = await loadSources();
	assert.ok(pkg.dependencies["alien-signals"], "运行时依赖 alien-signals");
	assert.equal(pkg.dependencies.alpinejs, undefined, "运行时不再依赖 alpinejs");
	assert.match(pkg.description, /alien-signals/, "description 说明当前技术栈");
	for (const file of ["store.test.mjs", "dom.test.mjs", "markup.test.mjs"]) {
		assert.ok(pkg.scripts.test.includes(file), `test 脚本包含 ${file}`);
	}
});
