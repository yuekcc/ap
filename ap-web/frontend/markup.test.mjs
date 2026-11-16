// 三栏工作台的布局约定是 docs/internal/web.md 的硬性要求：左栏工作空间、
// 中栏对话列表、右栏对话正文。这里直接读 index.html 做结构断言，不引入 DOM 依赖。
import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const indexPath = fileURLToPath(new URL("../index.html", import.meta.url));
const stylesPath = fileURLToPath(new URL("./styles.css", import.meta.url));
const appPath = fileURLToPath(new URL("./app.js", import.meta.url));
const renderPath = fileURLToPath(new URL("./render.js", import.meta.url));

test("目录选择入口在工作空间栏，输入区只回显工作空间路径", async () => {
	const html = await readFile(indexPath, "utf8");

	const railStart = html.indexOf('<aside class="rail"');
	const railEnd = html.indexOf("</aside>", railStart);
	assert.ok(railStart >= 0 && railEnd > railStart, "index.html must have a workspace rail");
	const rail = html.slice(railStart, railEnd);
	assert.ok(!rail.includes("pickDirectory"), "工作空间栏列目录，不弹系统选择器");
	assert.ok(rail.includes("openWorkspace()"), "工作空间栏的 + 打开一个工作空间");

	const footerStart = html.indexOf('<footer class="composer">');
	assert.ok(footerStart > railEnd, "composer must follow the rails");

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
		html.includes(':data-streaming="item.ended ? null : \'true\'"'),
		"streaming messages are marked so mermaid waits for the final text",
	);
	assert.ok(
		html.includes('class="tool__output"') && html.includes('x-text="item.streamed || item.result"'),
		"tool output must stay plain text",
	);
	assert.ok(!html.includes("x-html=\"item.streamed"), "tool output must not be rendered as html");
});

test("左栏是工作空间列表，中栏是新对话与当前空间的对话记录", async () => {
	const html = await readFile(indexPath, "utf8");
	const css = await readFile(stylesPath, "utf8");

	const railStart = html.indexOf('<aside class="rail"');
	const railEnd = html.indexOf("</aside>", railStart);
	assert.ok(railStart >= 0 && railEnd > railStart, "index.html must have a workspace rail");
	const rail = html.slice(railStart, railEnd);
	assert.ok(rail.includes('class="brand__mark"'), "logo 在左栏标题行");
	assert.match(rail, />ap<\/span>/, "logo mark itself spells ap");
	assert.ok(!rail.includes("brand__name"), "logo has no adjacent wordmark label");
	assert.ok(
		rail.includes('x-for="project in $store.ap.workspaceProjects"'),
		"工作目录成为左栏列表项",
	);
	assert.ok(rail.includes("switchWorkspace(project)"), "点列表项切换工作空间");
	assert.ok(rail.includes('@click="openWorkspace()"'), "+ 打开新的工作空间");
	assert.ok(rail.includes('data-icon="arrow-down-up"'), "排序入口在左栏标题行");
	assert.ok(rail.includes('@click="toggleRail()"'), "折叠入口在左栏标题行");

	const sessionsStart = html.indexOf('<aside class="sessions-col"');
	const sessionsEnd = html.indexOf("</aside>", sessionsStart);
	assert.ok(sessionsStart >= 0 && sessionsEnd > sessionsStart, "index.html must have a session rail");
	const sessions = html.slice(sessionsStart, sessionsEnd);
	assert.ok(sessions.includes('class="new-session"'), "新对话在中栏");
	assert.ok(css.includes(".session-group__label"), "组标题有自己的样式");
	assert.ok(
		sessions.includes('@click="newSession()"'),
		"new session must not receive the click event as its cwd argument",
	);
	assert.ok(
		sessions.includes('x-for="group in $store.ap.sessionGroups"'),
		"对话记录按时间分组渲染",
	);
	assert.ok(
		sessions.includes('class="session-group__label"') && sessions.includes('x-text="group.label"'),
		"每组自带标题（今天 / 昨天 / 7天内 / 更早）",
	);
	assert.ok(
		sessions.includes('x-for="session in group.sessions"'),
		"组内渲染该时段的对话",
	);
	assert.ok(sessions.includes("selectSession(session)"), "点条目切换当前对话");
	assert.ok(sessions.includes("sessionTitle(session)"), "显示格式化后的会话标题");
	assert.ok(sessions.includes("sessionTime(session.ts)"), "第二行是本地时间");
	assert.ok(!sessions.includes('class="sidebar__cwd"'), "中栏不重复工作目录");
	assert.ok(
		!sessions.includes(':disabled="$store.ap.running"'),
		"session actions must stay usable while another session is running",
	);
	assert.ok(!html.includes('id="session-select"'), "topbar select is replaced by the rail");
});

test("工作空间栏可折叠，窄屏下两个侧栏都是浮层", async () => {
	const html = await readFile(indexPath, "utf8");
	const css = await readFile(stylesPath, "utf8");

	assert.ok(
		html.includes('<aside class="rail" id="workspace-rail"'),
		"左栏暴露折叠入口控制的 id",
	);
	assert.ok(html.includes('aria-controls="workspace-rail"'), "折叠入口指向左栏");
	assert.ok(html.includes('@click="toggleRail()"'), "折叠入口调用 toggleRail");
	assert.ok(
		html.includes("'app--rail-hidden': !$store.ap.railVisible"),
		"折叠状态由 store 驱动",
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
});

test("两个侧栏的分隔条可拖动可键盘调整，宽度写回 CSS 变量", async () => {
	const html = await readFile(indexPath, "utf8");
	const css = await readFile(stylesPath, "utf8");
	const app = await readFile(appPath, "utf8");
	const render = await readFile(renderPath, "utf8");

	const railEnd = html.indexOf("</aside>");
	const separators = [...html.matchAll(/class="resizer"[\s\S]*?><\/div>/g)].map((m) => m[0]);
	assert.equal(separators.length, 2, "两处分隔条：工作空间栏后、对话栏后");

	const [railSplit, sessionsSplit] = separators;
	for (const split of separators) {
		assert.ok(split.includes('role="separator"'), "分隔条是 window splitter");
		assert.ok(split.includes('aria-orientation="vertical"'), "竖向分隔");
		assert.ok(split.includes('tabindex="0"'), "键盘能聚焦");
		// 边界和 render.js 里的常量同源，改数字忘了改标记会在这里断。
		assert.ok(split.includes(`aria-valuemin="${Number(render.match(/PANEL_MIN_W = (\d+)/)[1])}"`), "取值下限与常量一致");
		assert.ok(split.includes(`aria-valuemax="${Number(render.match(/PANEL_MAX_W = (\d+)/)[1])}"`), "取值上限与常量一致");
		assert.ok(/@pointerdown="startResize\(\$event, '\w+'\)"/.test(split), "指针按下开始拖动");
		assert.ok(/@keydown="onResizeKey\(\$event, '\w+'\)"/.test(split), "方向键也能调");
		assert.ok(split.includes("resetPanelWidth("), "双击回到默认宽度");
	}
	assert.ok(railSplit.includes(":aria-valuenow=\"$store.ap.railWidth\""), "第一处分隔条管工作空间栏");
	assert.ok(railSplit.includes(":data-active=\"resizing === 'rail'"), "只有被拖的那条高亮");
	assert.ok(sessionsSplit.includes(":data-active=\"resizing === 'sessions'"), "两条各自标记自己在拖");
	assert.ok(sessionsSplit.includes(":aria-valuenow=\"$store.ap.sessionsWidth\""), "第二处分隔条管对话栏");
	assert.ok(
		railSplit.includes("layoutMode === 'wide' && $store.ap.railVisible"),
		"栏折叠或变成浮层时没有分隔条",
	);
	assert.ok(railEnd > 0 && html.indexOf(railSplit) > railEnd, "第一处分隔条排在左栏之后");

	assert.ok(
		html.includes("--rail-w: ${$store.ap.railWidth}px; --sessions-w: ${$store.ap.sessionsWidth}px"),
		"宽度以行内 CSS 变量喂给三栏布局",
	);
	assert.ok(
		html.includes("'app--resizing': resizing !== ''"),
		"拖动期间给页面加状态类",
	);

	// 拖动监听挂在 window 上：指针离开那 10px 命中区也要继续算宽度。
	assert.ok(
		app.includes('window.addEventListener("pointermove", onMove)') &&
			app.includes('window.addEventListener("pointerup", onEnd)') &&
			app.includes('window.removeEventListener("pointermove", onMove)'),
		"拖动期间由 window 接管指针事件，松手时摘掉监听",
	);
	assert.ok(!html.includes("setPointerCapture"), "不依赖 pointer capture：离开命中区后会丢事件");
	// 松手事件可能根本收不到（窗口外松手、切走应用）：没有按键的移动必须收尾。
	assert.ok(
		app.includes("if (event.buttons === 0)") && app.includes("this.endResize();"),
		"裸移指针时结束拖动，不让栏跟着光标走",
	);
	assert.ok(
		app.includes('window.addEventListener("blur", onEnd)') &&
			app.includes('document.addEventListener("visibilitychange", onVisibilityChange)'),
		"失焦和切后台也要收尾",
	);

	assert.ok(
		css.includes('.resizer[data-active="true"]::after'),
		"高亮只给正在拖的那一条",
	);
	assert.ok(
		!css.includes(".app--resizing .resizer"),
		"拖动状态类不再一把点亮所有分隔条",
	);
	// CSS 里的初始宽度是首帧回退值，必须和 render.js 的默认值同源。
	const defaultRem = Number(render.match(/PANEL_DEFAULT_W = (\d+)/)[1]) / 16;
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
	const html = await readFile(indexPath, "utf8");
	const css = await readFile(stylesPath, "utf8");

	const topbarStart = html.indexOf('<header class="topbar">');
	const topbarEnd = html.indexOf("</header>", topbarStart);
	assert.ok(topbarStart >= 0 && topbarEnd > topbarStart, "index.html must have a topbar");
	const topbar = html.slice(topbarStart, topbarEnd);

	const headingIndex = topbar.indexOf('class="topbar__heading"');
	const rightIndex = topbar.indexOf('class="topbar__right"');
	assert.ok(headingIndex >= 0 && rightIndex > headingIndex, "标题行只有标题组和右侧状态两块");
	assert.ok(
		topbar.slice(headingIndex, rightIndex).includes("$store.ap.currentTitle"),
		"标题在左",
	);
	assert.ok(topbar.slice(rightIndex).includes("$store.ap.statusLabel"), "状态在右");
	assert.ok(!topbar.includes("topbar__side"), "三列居中布局已删除");

	const topbarRule = css.slice(css.indexOf(".topbar {"), css.indexOf(".topbar__sessions-btn"));
	assert.ok(topbarRule.includes("display: flex"), "标题行是一条 flex 行");
	assert.ok(!topbarRule.includes("grid-template-columns"), "不再用等宽 1fr 把标题钉在正中");
});

test("对话栏标题行是在工作目录打开文件管理器与终端的两个按钮", async () => {
	const html = await readFile(indexPath, "utf8");
	const css = await readFile(stylesPath, "utf8");

	const headStart = html.indexOf('class="sessions__head"');
	const headEnd = html.indexOf('class="new-session"');
	assert.ok(headStart >= 0 && headEnd > headStart, "两个按钮在对话栏标题行");
	const head = html.slice(headStart, headEnd);

	assert.ok(head.includes('@click="openWorkdirFiles()"'), "打开文件管理器是一个独立按钮");
	assert.ok(head.includes('@click="openWorkdirTerminal()"'), "打开终端是一个独立按钮");
	assert.ok(head.includes('data-icon="folder2-open"'), "文件管理器按钮使用文件夹图标");
	assert.ok(head.includes('data-icon="terminal"'), "终端按钮使用终端图标");
	assert.ok(head.includes(':disabled="!$store.ap.projectCwd"'), "没有工作目录时按钮不可点");

	assert.ok(css.includes(".sessions__actions"), "两个按钮有自己的容器样式");
	assert.ok(!css.includes(".titlebar__open-btn"), "旧顶栏按钮样式必须一起删掉");
	assert.ok(!css.includes(".titlebar"), "旧顶栏样式必须一起删掉");
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

test("标题行右侧展示 token 用量", async () => {
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

	// 三栏工作台：两栏定宽，正文吃掉剩下的宽度。
	assert.match(css, /\.rail\s*\{[^}]*width:\s*var\(--rail-w\)/, "左栏宽度来自变量");
	assert.match(
		css,
		/\.sessions-col\s*\{[^}]*width:\s*var\(--sessions-w\)/,
		"中栏宽度来自变量",
	);
	assert.match(css, /\.workspace\s*\{[^}]*flex:\s*1 1 auto/, "正文吃掉剩余宽度");
	assert.ok(css.includes(".workspace-item.is-active"), "当前工作空间项需要自己的状态");
	assert.match(
		css,
		/body\s*\{[^}]*padding:\s*0/,
		"app must fill the viewport without outer margins",
	);
	assert.match(
		css,
		/\.session\.is-active\s*\{[^}]*background:\s*var\(--accent-tint\)/,
		"the current conversation is highlighted with the system blue tint",
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

test("对话项是标题 + 时间 + 状态点，工具卡片和当前文件各有状态指示", async () => {
	const html = await readFile(indexPath, "utf8");
	const css = await readFile(stylesPath, "utf8");

	const sessionsStart = html.indexOf('<aside class="sessions-col"');
	const sessions = html.slice(sessionsStart, html.indexOf("</aside>", sessionsStart));
	assert.ok(sessions.includes('class="session__title"'), "第一行是标题");
	assert.ok(sessions.includes("sessionTime(session.ts)"), "第二行左侧是本地时间");
	assert.ok(sessions.includes('class="session__dot"'), "第二行右侧是状态点");
	assert.ok(
		sessions.includes(":data-running=\"session.running ? 'true' : null\""),
		"状态点由 running 派生",
	);
	assert.ok(
		css.includes('.session__dot[data-running="true"]') && css.includes("animation: pulse"),
		"运行中的对话是脉冲点",
	);

	assert.ok(html.includes('class="tool__dot"'), "工具卡片头部有状态点");
	for (const state of ["running", "ok", "error"]) {
		assert.ok(
			css.includes(`.tool[data-status="${state}"] .tool__dot`),
			`工具状态 ${state} 有自己的点色`,
		);
	}

	// 「当前修改的文件」默认不显示，只有工具改写文件后才由 store 派生出路径。
	assert.ok(html.includes('class="thread-file"') && html.includes('x-show="$store.ap.currentFile"'), "当前文件指示默认隐藏");
	assert.ok(html.includes("copyCurrentPath()"), "点一下复制完整路径");
	assert.ok(css.includes(".thread-file__btn"), "指示本身是一个小胶囊");
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


test("顶栏标题旁有刷新按钮，运行中不可点", async () => {
	const html = await readFile(indexPath, "utf8");
	const css = await readFile(stylesPath, "utf8");

	assert.ok(html.includes('class="topbar__heading"'), "title and refresh share one heading row");
	const headingIndex = html.indexOf('class="topbar__heading"');
	const titleIndex = html.indexOf("$store.ap.currentTitle", headingIndex);
	assert.ok(titleIndex > headingIndex, "heading keeps the session title");

	const buttonIndex = html.indexOf('class="topbar__title-btn"', headingIndex);
	assert.ok(buttonIndex > titleIndex, "refresh button sits next to the title");
	const button = html.slice(buttonIndex, html.indexOf("</button>", buttonIndex));
	assert.ok(button.includes("refreshTitle()"), "refresh button calls refreshTitle");
	assert.ok(button.includes('data-icon="arrow-clockwise"'), "refresh button uses an inline icon");
	assert.ok(
		button.includes("titlePending") && button.includes("$store.ap.running"),
		"refresh button is disabled while a turn or another refresh is running",
	);
	assert.ok(css.includes(".topbar__title-btn"), "refresh button has its own style");
});

test("消息区翻上去时露出「回到底部」，旧消息延迟渲染", async () => {
	const html = await readFile(indexPath, "utf8");
	const css = await readFile(stylesPath, "utf8");

	const threadIndex = html.indexOf('<div class="thread">');
	const mainIndex = html.indexOf('class="messages"', threadIndex);
	const buttonIndex = html.indexOf('class="scroll-bottom"', threadIndex);
	const threadEnd = html.indexOf("</div>", buttonIndex);
	assert.ok(threadIndex >= 0 && mainIndex > threadIndex, "消息区包在 thread 容器里");
	assert.ok(buttonIndex > mainIndex, "回到底部按钮在消息区之后");
	assert.ok(threadEnd > buttonIndex, "回到底部按钮和消息区同一个容器");

	assert.ok(html.includes('@scroll.passive="onMessagesScroll()"'), "滚动位置按帧读取");
	assert.ok(html.includes(":aria-busy="), "运行中把消息区标成 busy");
	assert.ok(html.includes('data-icon="arrow-down"'), "回到底部按钮用向下的箭头");

	const button = html.slice(buttonIndex, html.indexOf("</button>", buttonIndex));
	assert.ok(button.includes("scrollToBottom()"), "按钮滚动到最新消息");
	assert.ok(button.includes("$store.ap.atBottom"), "贴底时按钮收起");
	assert.ok(button.includes('aria-label="回到底部"'), "按钮有可读的名字");

	assert.ok(css.includes(".scroll-bottom"), "回到底部按钮有自己的样式");
	assert.ok(
		css.includes(".event:nth-last-child(n + 8)") && css.includes("content-visibility: auto"),
		"离开底部的旧消息延迟渲染",
	);
	assert.ok(css.includes("contain-intrinsic-size"), "延迟渲染要带占位高度，否则滚动会跳");
	assert.ok(css.includes("scrollbar-gutter: stable"), "滚动条出现时内容不横跳");
});

test("当前工作空间与当前会话带 aria-current，动态错误用 alert 播报", async () => {
	const html = await readFile(indexPath, "utf8");
	assert.ok(
		html.includes(':aria-current="isActiveProject(project) ? \'true\' : null"'),
		"工作空间标签标出当前位置",
	);
	assert.ok(
		html.includes(':aria-current="session.session_id === $store.ap.sessionId ? \'true\' : null"'),
		"会话条目标出当前会话",
	);
	assert.ok(
		html.includes(':role="item.tone === \'error\' ? \'alert\' : null"'),
		"错误提示立刻被读屏播报，普通提示不打断",
	);
});

test("mermaid 图表有独立样式，减少动态规则不碰 SVG 元素", async () => {
	const css = await readFile(stylesPath, "utf8");
	assert.ok(css.includes(".mermaid-block svg"), "mermaid 图表需要自己的尺寸约束");
	assert.ok(css.includes(".mermaid-block__error"), "渲染失败要能显示错误提示");
	assert.ok(css.includes(".mermaid-block__source"), "占位块保留源码样式");

	const mediaStart = css.indexOf("@media (prefers-reduced-motion: reduce)");
	assert.ok(mediaStart > 0, "styles.css keeps the reduced-motion query");
	const mediaEnd = css.indexOf("\n}", mediaStart);
	const block = css.slice(mediaStart, mediaEnd);
	assert.ok(
		block.includes("*:not(svg):not(svg *)"),
		"给 SVG 元素加 transition-duration 会让 Chrome 的 getBBox 返回错误尺寸，mermaid 图表会被撑大",
	);
});
