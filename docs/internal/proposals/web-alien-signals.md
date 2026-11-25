# 提案：ap-web 前端迁移到 alien-signals + 原生 Web API

状态：已实现。定稿行为已并入 [web.md](../web.md)、[ap-web/README.md](../../../ap-web/README.md) 与 [module-dependency-graph.md](../../design/module-dependency-graph.md)；本文件保留决策理由与实现记录。

影响范围：只改 `ap-web` 浏览器前端（`ap-web/frontend/`、`ap-web/index.html`、`ap-web/package.json`、`ap-web/build.mjs` 的注释、前端测试与相关文档）。HTTP API、SSE 帧格式、Odin 服务器、transcript 与 `ap` 本体不动；用户可见行为、布局、无障碍语义和持久化键保持不变。

## 目标

1. **去掉 Alpine.js 运行时。** 用 `alien-signals` 的 `signal` / `computed` / `effect` / `effectScope` 管状态与依赖，用原生 DOM API（`<template>`、`cloneNode`、`addEventListener`、`AbortController`、`matchMedia`、`requestAnimationFrame`、`MutationObserver` 等）管视图。
2. **保留现有分层。** `render.js` 继续是「事件 → 纯视图状态」的纯函数 reducer，不依赖 DOM、浏览器或信号库；signal 只负责发布状态和派生 UI 状态。
3. **让更新粒度显式。** SSE 增量继续按帧合并；一次 flush 只触发一次批量渲染；消息列表按 key 做 O(n) diff，只有内容变化的条目重跑自己的 effect。
4. **可测性不降级。** 继续使用 Node 纯单测 + 读源码做结构断言，不引入 jsdom。新增 store 的信号/派生状态测试和纯 diff 测试。
5. **减少运行时层数。** 不再需要 Alpine 的深层 reactive proxy、模板表达式求值和 `new AsyncFunction`；`alien-signals` 是无依赖的小库，替换后运行时依赖数量不变（移除 `alpinejs`，加入 `alien-signals`）。

## 非目标

- 不重做三栏工作台，不改视觉样式。CSS 只增加 `[hidden]` 规则、删除 `[x-cloak]` 规则，其他选择器和设计令牌保持原样。
- 不加新功能：路由、虚拟滚动、深色主题、diff 渲染、附件上传、`Last-Event-ID` 断点续传、session fork/删除、轮询同步运行态。
- 不改 HTTP API、SSE 帧格式、Odin 服务器、`ap` / `ap-core` / `ap-cli` / `ap-tui`。
- 不引入 TypeScript、新的 bundler、模板编译器、Shadow DOM、jsdom 或 CDN 资源。
- 不改 `localStorage` / `sessionStorage` 键：`ap-web:session`、`ap-web:sidebar-collapsed`、`ap-web:sort`、`ap-web:split` 原样保留，升级后用户偏好不丢。
- 不改变 Markdown/mermaid 的安全边界：只有 assistant 文本走 `innerHTML`，用户输入和工具输出仍是 `textContent`。

## 现状盘点

### Alpine 的职责分布

| 位置 | 当前职责 | 行数/规模 |
| --- | --- | --- |
| `frontend/store.js` | `Alpine.reactive` 对象 + getter；把纯 `view` 发布到 Alpine 字段 | 385 行 |
| `frontend/app.js` | `Alpine.data("apApp")` 组件：会话/SSE 编排、拖拽、滚动、焦点、localStorage、剪贴板、事件队列全部混在一个对象里 | 1010 行 |
| `frontend/main.js` | `createStore` → `Alpine.store` → `registerApp` → `Alpine.start` | 14 行 |
| `ap-web/index.html` | Alpine 模板：约 30 处 `$store.ap` 读取、25 个 `x-show`、20 个 `@click`、19 个 `x-text`、4 个 `x-for`、4 个 `x-if`，以及 `x-model`、`x-html`、`:attr`、`:class`、`:style`、`$refs`、`$nextTick`、`$watch` | 439 行 |
| `frontend/markup.test.mjs` | 直接读 `index.html` 断言 Alpine 表达式和布局结构 | 539 行 |

`render.js`、`api.js`、`sse.js`、`markdown.js`、`mermaid-blocks.js`、`mermaid-renderer.js` 与框架无关，本次不改逻辑。

### 为什么要换

1. **动作与 DOM 时序混在一起。** `app.js` 同时处理 `boot`、SSE 重连、turn 生命周期、拖拽、滚动跟随和焦点。`$watch` / `$nextTick` 让「状态变了之后什么时候读 DOM」隐式化，排查回流和滚动跳动时很难定位。
2. **每次 publish 都经过框架求值。** `store.handleEvents` 每帧替换 `items` 数组，Alpine 需要重新求值 `x-for` / `x-if` / `x-show` 表达式；长会话里这些求值与深层 proxy 访问叠加，成本不透明。
3. **只需要一小块能力。** 前端没有表单框架、路由、组件复用或 SSR 需求，只是「事件批量进 → 派生状态 → 命令式更新 DOM」。引入完整模板运行时换来的便利很有限。
4. **时序需要显式。** `alien-signals` 的 pull-based `computed` + `startBatch/endBatch` 正好对应现有「SSE 增量入队，按帧一次应用」的设计；`effectScope` 能按消息条目精确释放副作用。
5. **安全面更小。** 原生化后页面不需要任何表达式求值；未来若加 CSP，不必为 Alpine 的 `unsafe-eval` 开口（CSP 本身不在本次范围）。

## 备选方案

| 方案 | 结论 | 原因 |
| --- | --- | --- |
| 保留 Alpine 模板，只把 store 桥接到 signals | 否 | 仍是 Alpine 运行时 + 表达式求值，没有解决动作/DOM 混合和时序问题；还多一层桥 |
| 换 Vue / React / Svelte | 否 | 需要编译器或更大的运行时；当前页面没有组件复用和路由需求 |
| 自写 virtual DOM | 否 | transcript 基本只追加，按 key 的 DOM diff 足够；VDOM 反而增加分配和 diff 成本 |
| `lit-html` / `htm` 模板字符串 | 否 | 再引入一个依赖；模板字符串容易把用户数据拼进 HTML，测试也不易守住安全边界 |
| 自定义元素 + Shadow DOM | 否 | 现有 `github-markdown-css`、mermaid、全局布局都依赖全局样式；Shadow DOM 会切断样式。自定义元素（light DOM）也没有比 `mount()` 函数多出实际收益 |
| `index.html` 静态骨架 + `<template>` + `mount()` 函数 | **采纳** | 保持现有「读 HTML 做结构断言」的测试缝；模板是可信静态内容，动态值只走 `textContent` / 受控属性 |

## 方案

### 总览

```text
SSE / fetch
   │
   ▼
controller.js ── store actions ──► store.js（signal / computed）
   │                                   │
   │                                   ▼
   │                              dom.js 的 effect 绑定
   │                                   │
   ▼                                   ▼
事件队列（按帧合并）              index.html 的静态骨架与 <template>
                                       │
                                       ▼
                                  ui/*.js 克隆模板、按 key 管理条目
```

- `render.js` 不变：`applyEvent`、`ingestHistory`、`applyTurnDone` 仍是纯函数，缺什么补什么。
- `store.js` 持有 `view`（transcript 投影）和 UI 状态信号；getter 改为 `computed`。
- `controller.js` 承接原 `app.js` 的会话/SSE 动作，不碰 DOM。
- `ui/*.js` 只读信号、写 DOM，不写应用状态；需要让 UI 做事（聚焦、强制滚底）时由 controller 递增一个信号（`focusNonce` / `scrollNonce`），UI 自己监听。
- `main.js` 是唯一的组装根：创建 store → 恢复本地偏好 → 创建 controller → 挂载 UI → `boot()`。controller 先在 `boot()` 前创建，UI 从 `main.js` 拿到同一个 controller；controller 不依赖 DOM，boot 里的聚焦/滚底通过信号请求 UI 完成。

### 状态层

`createStore()` 暴露信号、派生值和 action。核心写法：

```js
import { signal, computed, startBatch, endBatch } from "alien-signals";
import { applyEvent, applyTurnDone, createState, ingestHistory, sessionTitle } from "./render.js";

export function createStore() {
	const view = signal(createState());
	const projects = signal([]);
	const sessionKey = signal(null);
	const draft = signal("");
	// ...

	const items = computed(() => view().items);
	const thinking = computed(() => {
		const state = view();
		return state.running && state.thinking === true;
	});
	const currentTitle = computed(() => {
		const state = view();
		return state.sessionId
			? sessionTitle({ session_id: state.sessionId, title: state.title })
			: "新会话";
	});

	function batch(fn) {
		startBatch();
		try {
			return fn();
		} finally {
			endBatch(); // 一帧只 flush 一次，effect 在这里统一跑
		}
	}

	function handleEvents(events) {
		batch(() => {
			let next = view();
			for (const event of events) {
				next = applyEvent(next, event, "live");
				if (event?.type === "session_title") setSessionTitle(next.sessionId, event.title);
			}
			view(next);
		});
	}

	// 信号按引用比较：这里必须替换数组和对象，不能原地改。
	function setSessionTitle(sessionId, title) {
		const value = String(title ?? "").trim();
		if (!sessionId || !value) return;
		projects.set(projects().map((project) => ({
			...project,
			sessions: (project.sessions ?? []).map((session) =>
				session.session_id === sessionId ? { ...session, title: value } : session,
			),
		})));
	}

	return { view, items, thinking, currentTitle, projects, batch, handleEvents, /* ... */ };
}
```

几条硬规则：

1. **`view` 是唯一 transcript 投影。** `reset` / `ingest` / `mergeHistory` / `handleEvents` / `handleTurnDone` 都只通过 `render.js` 的 reducer 得到新 `view`，再 `view(next)`。
2. **不可变更新。** 任何数组/对象替换都不能原地改。当前 `setSessionTitle` 直接改 `project.sessions[i].title`，在 Alpine 深代理下能触发更新，在 signals 下不会；必须像上面那样替换。
3. **effect 只写 DOM，不写应用状态。** 应用状态只由 action 改；否则很容易形成 effect ↔ signal 循环。UI 的瞬态状态（排序菜单开合、正在拖动的栏）用局部 signal，由事件处理写入。
4. **computed 不读环境、不读时钟。** 唯一保留的 `Date.now()` 在 `groupSessionsByTime` 里，语义与现在相同：项目列表或排序变化时重算，不新增定时器。
5. **多信号写入必须 `batch`。** `newSession`、`activateSession`、`afterTurnDone` 这类一次改多个信号的动作要包在 `batch()` 里，避免中途多次 flush 和闪动。

#### 信号清单

| 类别 | 信号 | 说明 |
| --- | --- | --- |
| transcript 投影 | `view` | `createState()` 的结果；`items`、`sessionId`、`turn`、`lastSeq`、`running`、`thinking`、`title`、`usage` 都由它派生 |
| 会话 | `sessionKey`、`sessionId`（派生）、`projectCwd`、`projects`、`config` | 标签页自己的 slot key 单独存，不能被服务端「最近活跃」覆盖 |
| 操作态 | `loading`、`picking`、`cancelling`、`titlePending`、`connected`、`error` | 与现在同名 |
| 输入 | `draft` | textarea 的唯一状态源 |
| 布局 | `layoutMode`、`railCollapsed`、`railOpen`、`sessionsOpen`、`railWidth`、`sessionsWidth`、`sortOrder`、`resizingPanel` | 侧栏/断点/排序/拖动 |
| 滚动 | `atBottom`、`scrollNonce` | `scrollNonce` 是「请求滚到底」的计数器，`force` 放在值里 |
| 焦点 | `focusNonce` | 请求把焦点放回输入框 |
| 派生 | `items`、`thinking`、`currentTitle`、`usageLabel`、`usageTitle`、`workspaceProjects`、`activeProject`、`activeSessions`、`sortedSessions`、`sessionGroups`、`sortLabel`、`currentFile`、`currentFileName`、`railVisible`、`sessionsVisible`、`overlayOpen`、`statusKind`、`statusLabel`、`showsDraftSession`、`showsEmptySessions` | 原来 `Alpine.reactive` 的 getter 原样迁移为 `computed` |

`thinking` 的显示值仍是 `running && view.thinking`，`session_start`/`session_end`/`message_update` 的语义不变。

#### action 清单

- **reducer 入口**：`reset`、`ingest`、`mergeHistory`、`handleEvent`、`handleEvents`、`handleTurnDone`、`addUser`、`notice`、`setSession`、`syncCurrent`、`setRunning`、`setTitle`、`setSessionTitle`。
- **UI 状态**：`setLoading`、`setPicking`、`setCancelling`、`setConnection`、`setError`、`setConfig`、`setCwd`、`setProjects`、`setProjectCwd`、`setDraft`、`setRailCollapsed`、`setRailOpen`、`setSessionsOpen`、`setLayoutMode`、`setSortOrder`、`setRailWidth`、`setSessionsWidth`、`setAtBottom`、`requestFocus`、`requestScroll`。
- **controller 动作**：`boot`、`resolveBootSession`、`openSession`、`syncSession`、`loadConfig`、`loadProjects`、`loadCwd`、`loadHistory`、`connect`、`disconnect`、`fillGap`、`resync`、`send`、`sendHandoff`、`refreshTitle`、`cancel`、`afterTurnDone`、`newSession`、`switchWorkspace`、`resumeSession`、`selectSession`、`pickDirectory`、`openWorkdir`、`copyCurrentPath`、`toggleRail`、`toggleSessions`、`closeOverlays`、`setSortOrder`、`queueEvent`、`flushEvents`、`dropEvents`、`fail`。

动作名保持现状，便于对照迁移。

### 渲染层

#### `index.html` 的职责

保留现有静态骨架，去掉所有 Alpine 指令、`$store` 表达式和 `x-cloak`。动态节点统一带 `data-ref`，重复结构放进 `<template>`：

```html
<!-- 静态骨架：标题行、菜单、录入框、消息区外壳 -->
<main class="messages" data-ref="messages" aria-busy="false">
	<div class="messages__empty" data-ref="messages-empty">…</div>
	<!-- messages-anchor：条目按 key 插入到这个注释之前 -->
	<!-- thinking 固定留在末尾 -->
</main>

<!-- 重复结构 -->
<template id="tpl-workspace-item">…</template>
<template id="tpl-session-group">…</template>
<template id="tpl-session-item">…</template>
<template id="tpl-message-user">…</template>
<template id="tpl-message-assistant">…</template>
<template id="tpl-tool-card">…</template>
<template id="tpl-notice">…</template>
```

约定：

- `<template>` 只放可信静态结构；用户数据、工具输出、事件文本一律通过 `textContent` 写入，绝不拼 HTML 字符串。
- assistant 的消息容器标 `data-render="markdown"`，工具输出标 `data-render="text"`。`markup.test.mjs` 继续用这两个标记守住「只有 assistant 走 Markdown」的安全红线。
- 图标仍是 `<svg data-icon="name"></svg>` 占位。`build.mjs` 对整个 `index.html` 做正则替换，模板里的图标也会被内联。
- 初始状态可省略的节点直接在 HTML 上写 `hidden`：排序菜单、遮罩、消息区动态内容；effect 挂载后再按信号更新，避免首帧闪现。
- 不在 HTML 里写事件属性（`onclick` 等）。所有监听在 `ui/*.js` 里用 `addEventListener` 挂。

#### `dom.js`：最小绑定层

不实现通用模板引擎，只提供「克隆一次 + effect 更新」的帮手：

| 函数 | 语义 |
| --- | --- |
| `ref(root, name)` | 取 `[data-ref="name"]`；缺失时抛出（静态模板由 markup 测试覆盖） |
| `cloneTemplate(id)` | `template.content.cloneNode(true)` 的第一个元素 |
| `bindText(el, get)` | `textContent`；值相同不写 |
| `bindMarkdown(el, get)` | 只给 assistant：`innerHTML = renderMarkdown(get())`；值相同不写 |
| `bindAttr(el, name, get)` | `null` / `undefined` / `false` 移除属性，其余 `String(value)` |
| `bindBool(el, name, get)` | 布尔属性（`hidden`、`disabled`）存在/移除 |
| `bindClass(el, name, get)` | `classList.toggle(name, Boolean(get()))` |
| `bindVisible(el, get)` | 等价于 `bindBool(el, "hidden", () => !get())` |
| `afterRender(fn)` | 按帧去重，在 DOM 写入后执行一次（替代 `$nextTick`） |
| `keyedChildren(container, getItems, { key, create, anchor })` | 按 key 复用节点、维护顺序、移除过期条目 |
| `diffKeys(prev, next)` | 纯函数，返回需要移除的 key 和最终顺序，供 Node 单测 |

`keyedChildren` 的核心约定：

1. 外层只有一个 `effect` 读 `getItems()`；每次 flush 做一次 O(n) 的 key diff。
2. 每个 key 有一个 `{ el, item: signal(item), current, stop }`。外层 effect 用普通字段 `current` 比较旧条目，**不能在外层 effect 里读 `item` 信号**，否则外层会被每个条目反向依赖。只有 `current !== nextItem` 时才 `item.set(nextItem)`；一条 delta 只触发对应条目的 effect。
3. 条目 effect 必须挂在 `keyedChildren` 自己的 owner `effectScope` 下，而不是列表 effect 下。实现方式：owner scope 的回调里用 `getActiveSub()` 记下 scope 节点；列表 effect 内创建/更新条目前用 `setActiveSub(owner)` 切换，结束后 `try/finally` 恢复。alien-signals 默认把新 effect 挂到当前 active effect 上；如果直接在列表 effect 里创建，下一次 diff 会把它们当成 nested effects 清掉，未变化的条目就永久失去更新。`dom.js` 在这里使用 `getActiveSub` / `setActiveSub`（唯一一处底层 API），并用注释说明原因。
4. 条目的 effect 和它的事件监听都放进一个 `effectScope` + `AbortController`；条目移除时 `stop()` + `abort()` + `el.remove()`。owner scope 停止时所有条目一起释放，`keyedChildren` 返回的 `dispose()` 负责这件事。
5. 顺序用「从后往前 `insertBefore` 到锚点」保证，锚点是一个注释节点。消息仍是 `.messages` 的直接子元素，`content-visibility: auto` 的 `nth-last-child` 规则继续有效。
6. 消息列表的 `key` 用 `item.key`（`msg:` / `tool:` / `user:` / `notice:`），会话列表用 `session_id`，工作空间用 `cwd`。

不把 `keyedChildren` 写成虚拟 DOM：只做 key → 节点的映射和一次插入/移除，代码量小，行为可预期。

#### 生命周期

- 每个顶层区域（rail、sessions、thread、composer、splitter、shell）在 `mount()` 时创建一个 `AbortController`，监听器用 `{ signal }` 挂载；返回 `dispose()` 停 scope + abort。
- 页面生命周期内不会卸载，但保留 `dispose()` 便于未来拆分和手动调试；消息条目在 session 切换时会真正移除，必须释放。
- mermaid 的 `MutationObserver` 在 `thread.mount()` 里调用一次 `watchMermaid(messagesEl, { onRendered })`，卸载时调用返回的 stop。
- 拖动分隔条沿用现有语义：拖动期间把 `pointermove` / `pointerup` / `pointercancel` / `blur` / `visibilitychange` 挂到 window，用一次性的 `AbortController` 收尾；`buttons === 0`、窗口失焦、切后台都必须结束拖动。不要改用 `setPointerCapture`：当前设计刻意允许指针离开 10px 命中区后继续调整。

### 调度、批量与滚动

- **事件队列**保持现状：`queueEvent` 入队，页面可见时用 `requestAnimationFrame`，后台标签页用 `setTimeout(..., 250)`；flush 前先取消句柄。
- **一次 flush 一次 batch**：`store.handleEvents(events)` 内部 `startBatch/endBatch`，所有派生和 DOM effect 在 `endBatch` 时统一跑一次。
- **turn_done 必须在增量之后**：保持现有顺序——先 flush 队列，再 `handleTurnDone(payload)`，最后 `afterTurnDone()`。
- **`afterRender`** 替代 `$nextTick`：effect 内写完 DOM 后，如果还要读取 `scrollHeight` / `getBoundingClientRect`，用 `afterRender` 推到下一帧。滚动跟随、mermaid 渲染完成后的贴底、侧栏宽度变化的重新跟随都走这个入口。
- **滚动语义不变**：距底部 ≤ 120px 时自动跟随；距底部 > 32px 时露出「回到底部」；`scrollToBottom` 优先平滑滚动，`scrollend` 不可用时 400ms 后补一次贴底；`prefers-reduced-motion: reduce` 时直接跳到底。
- **侧栏拖动**：宽度信号写回 `.app` 的 `--rail-w` / `--sessions-w`（`style.setProperty`），持久化仍在 `ui/splitter.js` 里做；键盘步长、双击复位、上下限、35% 视口上限不变。

### 模块划分

```text
ap-web/frontend/
├── main.js               # 组装根：store → 恢复偏好 → controller → mount UI → boot
├── controller.js         # 原 app.js 的会话/SSE 动作；不碰 DOM
├── store.js              # signal/computed/action；不碰 DOM、不碰 localStorage
├── dom.js                # template/clone、bind*、keyedChildren、diffKeys、afterRender
├── prefs.js              # localStorage / sessionStorage 的安全读写与键名常量
├── api.js                # 不变
├── sse.js                # 不变
├── render.js             # 不变（纯 reducer）
├── markdown.js           # 不变
├── mermaid-blocks.js     # 不变
├── mermaid-renderer.js   # 不变
├── styles.css            # 只增 [hidden]、删 [x-cloak]
├── ui/
│   ├── shell.js          # 根 class、CSS 变量、遮罩、matchMedia 布局、document.title
│   ├── rail.js           # 工作空间列表、排序菜单、折叠入口
│   ├── sessions.js       # 分组列表、draft/empty、新对话、打开文件管理器/终端
│   ├── thread.js         # 标题行、消息列表、工具卡、当前文件、思考中、滚动
│   ├── composer.js       # textarea、Enter/Shift+Enter、发送/停止/交接、cwd 回显
│   └── splitter.js       # 两条分隔条的指针/键盘/双击与持久化
```

依赖方向：

```text
main ──► controller ──► store ──► render / alien-signals
  │           │            ▲
  │           └──► api / sse / prefs
  └──► ui/* ───────────────┘（读 store，调用 controller 的 action）
        │
        └──► dom / markdown / mermaid-blocks / render 的纯工具
```

`controller` 不 import `ui/*`；`ui/*` 不 import `controller`，只接收 `main.js` 传进来的 controller 对象。这样既不循环依赖，也保证 controller 可以脱离 DOM 测试。

### Alpine → 原生映射

| Alpine 用法 | 迁移后 |
| --- | --- |
| `x-data="apApp"` + `init()` | `main.js` 按顺序 `mount*`；没有组件对象 |
| `Alpine.store("ap", store)` | `createStore()` 返回信号对象；`window.apWeb = { store, controller }` 仅作调试 |
| `Alpine.reactive` + getter | `signal` / `computed`；GETTER 名保持，调用方式变成 `store.currentTitle()` |
| `$watch("$store.ap.items", …)` | `effect(() => { store.items(); afterRender(autoScroll); })` |
| `$watch("$store.ap.thinking", …)` | 同上，读 `store.thinking()` |
| `$watch("$store.ap.sessionKey", …)` | 由 `activateSession` / `newSession` 显式调用 `persistSession` / `dropEvents`，避免 effect 里做重连 |
| `$nextTick` | `afterRender`（rAF）或 `queueMicrotask`（仅纯数据顺序） |
| `$refs` | 挂载时 `ref(root, name)` 取一次，缓存在闭包 |
| `x-show` | `bindVisible` → `hidden` 属性；CSS 加 `[hidden] { display: none !important; }` |
| `x-for` | `<template>` + `keyedChildren` |
| `x-if`（按 item.kind） | 每种 kind 一个 template；列表创建节点时按 kind 选模板，不在一个节点里串条件 |
| `x-text` | `bindText` |
| `x-html="renderMarkdown(...)"` | `bindMarkdown`；只用于 assistant 模板 |
| `x-model` | textarea 的 `input` 事件写 `draft`；effect 在 `el.value !== draft()` 时回写，避免光标跳动 |
| `:disabled` / `:title` / `:aria-*` / `:data-*` / `:role` | `bindAttr` / `bindBool` |
| `:class` | `bindClass`（`is-active`、`is-streaming`、`app--*`） |
| `:style` | `app.style.setProperty("--rail-w", …)` / `--sessions-w` |
| `@click` | `addEventListener("click", …)` |
| `@keydown` / `@keydown.escape` | 原生 `keydown` + `event.key` 判断 |
| `@click.outside` | 挂一次 document `pointerdown`，判断 `!root.contains(event.target)` |
| `@scroll.passive` | `scroll` 监听器 + `{ passive: true }`，内部 rAF 节流 |
| `x-cloak` | 动态节点初始 `hidden`；静态骨架直接可见，不需要 cloak |
| `window.apWeb.store` | 保留调试入口，改成 `{ store, controller }`；store 的字段是函数，必要时提供 `snapshot()` 返回普通对象 |

### 行为保持清单

实现和评审时逐条对照，以下行为不得变化：

1. 三栏 flex 布局、三档断点（宽屏 / ≤1100px / ≤820px）、浮层与遮罩、折叠偏好与浮层的区别。
2. 工作空间栏：`ap` 字标、`+` 打开新工作空间、排序菜单、折叠按钮；当前项 `is-active` + `aria-current`；排序偏好存 `localStorage`。
3. 两个分隔条：指针拖动、方向键 ±16px / Shift ±64px、Home/End、双击回 260px、176–420px 与 35% 视口上限、只有正在拖的那条高亮、拖动期间不选中文本。
4. 对话栏：`新对话`、按今天/昨天/7天内/更早分组、组内排序、每条两行（标题 + 本地时间 + 运行状态点）、draft 占位、空状态、点击打开文件管理器/终端。
5. 工作空间切换：打开该目录最近一条已落盘 session；没有就新建 slot；目录选择只在工作空间栏，Unix 501 的提示不变。
6. 对话正文：标题 + 刷新按钮、状态点、token chip 与悬停明细、当前修改文件胶囊（点击复制、失败落 notice）。
7. 消息区：用户气泡、assistant Markdown、工具卡片默认折叠、流式输出、耗时/退出码/截断提示、notice 的 tone 与 `role="alert"`、思考中动画。
8. 滚动：自动跟随只在贴底时发生；「回到底部」按钮；平滑滚动与 `scrollend` 兜底；减少动态偏好；旧消息 `content-visibility` 延迟渲染。
9. mermaid：占位块保留源码、消息结束后才渲染、按需加载 `/mermaid.js`、失败显示错误、`securityLevel` 拦截。
10. 录入框：Enter 发送、Shift+Enter 换行、输入法合成期间不发送、`keyCode !== 229`、运行中发送禁用、停止按钮、交接按钮、cwd 回显。
11. 启动与恢复：`sessionStorage` 的 `{key, id, cwd}`、恢复顺序、history → subscribe、首次订阅补 gap、断线重连 resync、`seq` 去重、`user_message` 本地回显不重复。
12. turn 生命周期：发送乐观更新、409 `turn_running` 处理、取消、`turn_done` 顺序、交接后自动切到新 session、标题刷新与 `titlePending` 禁用。
13. 所有异步错误落成 `notice`，页面不因单个接口失败白屏；文档标题跟随会话标题。
14. 无障碍：`aria-current`、`aria-expanded`、`aria-controls`、`role="separator"`、`aria-valuemin/max/now`、`aria-busy`、`aria-live`、`aria-pressed`、`role="alert"`、可见标签与 `title` 保持原语义。
15. 只提供浅色主题；无模糊、无渐变、无投影；浏览器目标仍是 Chrome/Edge/Firefox 110、Safari 16，无 polyfill。

## 测试方案

### 保持不变的测试

- `frontend/render.test.mjs`：纯 reducer 的所有用例不动。`render.js` 不改逻辑。
- `frontend/api.test.mjs`、`frontend/markdown.test.mjs`、`frontend/mermaid-blocks.test.mjs`：不动。
- `odin test ap-web`、`./test.sh`：服务端没有改动，应保持全绿。若出现失败，说明改动溢出前端边界，回退而不是改断言。

### 重写 `frontend/markup.test.mjs`

原有测试的意图保留，断言从 Alpine 表达式改为原生结构与模板标记：

| 现有断言 | 迁移后 |
| --- | --- |
| `x-for="project in $store.ap.workspaceProjects"` | `tpl-workspace-item` 模板存在，`data-ref="workspace-list"` 存在，`ui/rail.js` 用 `keyedChildren` |
| `x-for="group in $store.ap.sessionGroups"` / `x-for="session in group.sessions"` | `tpl-session-group` + `tpl-session-item`，分组用嵌套 keyed list |
| `x-text="sessionTitle(...)"` / `sessionTime(...)` | 模板里有对应节点（`.session__title` / `.session__time`），派生值由 `store.test.mjs` 断言 |
| `x-html="renderMarkdown(item.text)"` | assistant 模板 `data-render="markdown"`；工具输出 `data-render="text"`，且工具模板没有 markdown 标记 |
| `:data-streaming` | assistant 模板的流式标记由 `thread.js` 绑定；测试断言模板含 `markdown-body` 与 `data-render="markdown"` |
| `@click="..."` / `:disabled` / `:aria-*` | 静态骨架保留 `aria-*` 初始合法值；动态绑定在 `ui/*.js` 里，用源码/结构断言守住关键项 |
| `--rail-w: ${...}px` 行内字符串 | `ui/shell.js` 用 `style.setProperty("--rail-w", …)`；CSS 的 `:root` 回退值保持不变 |
| `resizing === 'rail'` | `ui/splitter.js` 绑定 `data-active`；两条分隔条仍各有 `data-panel` |
| 图标 `data-icon` 占位与 dist 内联 | 不变；模板里的图标同样被 `build.mjs` 内联 |
| 三栏/断点/浅色/扁平/减少动态等 CSS 断言 | 不变 |

另外新增/保留这些硬断言：

- `index.html` 不含 `x-data`、`x-show`、`x-for`、`x-if`、`x-text`、`x-html`、`x-model`、`x-init`、`x-cloak`、`@click`、`$store`。
- `package.json` 的依赖含 `alien-signals`、不含 `alpinejs`；`description` 已更新。
- `styles.css` 含 `[hidden]` 且不再含 `[x-cloak]`。
- 消息列表的条目仍是 `.messages` 的直接子元素（锚点注释不参与 `:nth-last-child`），`content-visibility` 规则仍能生效。
- 每个区域至少有一个 `data-ref`，模板 id 与 `ui/*.js` 使用的 id 一致；可用一张常量表在测试里对齐。

### 新增 `frontend/store.test.mjs`

store 不依赖 DOM，直接在 Node 里测信号与派生值：

1. `handleEvents` 批量应用后 `items` 只发布一次；`effect` 在 `startBatch/endBatch` 之间只跑一次。
2. `currentTitle`、`usageLabel`、`usageTitle`、`statusKind`/`statusLabel`、`railVisible`/`sessionsVisible`/`overlayOpen` 的派生规则。
3. `workspaceProjects` / `activeSessions` / `sessionGroups` 的排序与分组（复用 `render.js` 的纯函数，确认信号层没有改变语义）。
4. `currentFile` / `currentFileName` 取最后一条带 `path` 的工具条目。
5. `syncCurrent` 的 `running`/`thinking`/`turn` 同步；`setSession` 清空标题；交接 `session_start` 重置 transcript 但保留运行态。
6. `mergeHistory` 的 `seq` 去重与 `user_message` 跳过。
7. **不可变更新回归**：`setSessionTitle` 必须产生新的 `projects` 和新的 session 对象，旧引用不被改写，订阅者能收到通知。
8. `requestFocus` / `requestScroll` 只递增计数器，不改其他状态。

### 新增 `frontend/dom.test.mjs`

- `diffKeys` 的纯逻辑：追加、删除、重排、替换同一 key、空列表。
- 用最小 fake element（只实现 `textContent`、`setAttribute`/`removeAttribute`、`classList.toggle`、`hidden`）测 `bindText` / `bindAttr` / `bindBool` / `bindClass` 的「值相同不写」和 effect 只跑一次。
- 用最小 fake container（只实现 `insertBefore`、`removeChild` 和子节点遍历）测 `keyedChildren` 的复用：列表 diff 后未变化的条目仍能响应自己的 item 信号；这是 nested effect 隔离（owner scope + `setActiveSub`）的回归用例。
- 不实现完整 fake DOM，也不引入 jsdom；其余 DOM 插入/移动由人工浏览器矩阵覆盖。

### 人工验证矩阵

在 `--web-root ap-web/dist` 下过一遍：

- Chrome / Edge / Firefox 各一次；Safari 16 可用时补一次。
- 宽屏、1100px、820px 三档；侧栏折叠/浮层/遮罩；两条分隔条拖动与键盘调整。
- 新建会话 → 发送 → 流式输出 → 工具卡片流式 → 取消；交接；标题刷新；token chip。
- 两个标签页各跑一个 session；刷新页面恢复；断网/断 SSE 后重连并补齐 history。
- mermaid 图表渲染成功与语法错误；`prefers-reduced-motion` 下滚动与脉冲。
- 500 条以上消息的会话滚动、流式增量、`回到底部`、旧消息延迟渲染。
- 切换 20 次 session，确认没有残留 DOM 节点/监听器（DevTools Performance/Memory 抽查）。

### 构建与性能检查

- `npm --prefix ap-web test`、`npm --prefix ap-web run build`、`./test.sh`。
- 记录迁移前后 `dist/app.js` 大小（gzip/raw）和首屏可交互时间；目标是不劣化，Alpine 运行时移除后应更小。
- 在一个长会话里比较流式 delta 的帧耗时；若出现长任务，优先检查是否漏了 batch 或是否在 effect 里读了 `scrollHeight`。

## 文档同步

实现提交必须同时更新：

| 文件 | 改动 |
| --- | --- |
| 本文件 | 状态改为「已实现」，正文并入规格后保留决策记录 |
| [docs/internal/web.md](../web.md) | 架构图、前端依赖列表、前端章节：signal store、原生模板、keyed list、effectScope、批量调度；测试覆盖 |
| [docs/internal/README.md](../README.md) | 文档地图登记本提案 |
| `ap-web/README.md` | 简介、目录树、前端依赖、开发命令、调试入口 |
| `ap-web/package.json` | `description`、`dependencies`（+`alien-signals`，−`alpinejs`）、`test` 脚本 |
| `ap-web/build.mjs` | 顶部注释：bundle 含 alien-signals，不再是 Alpine |
| [docs/design/module-dependency-graph.md](../../design/module-dependency-graph.md) | 前端 ES module 图：`store.js` → `alien-signals`，新增 `controller.js` / `dom.js` / `ui/*`，删除 `app.js` |
| [docs/design/web-ui-v3.md](../../design/web-ui-v3.md) | 历史布局决策不变；可补一句「实现已迁移到 alien-signals，见本提案」，不重写设计记录 |

`docs/11-web.md` 只描述用户可见行为，本次不改；如果实现中发现用户可见差异（例如首帧加载文案），再同步。

## 分阶段实施

1. **提案（本提交）**：写本文并登记到 `docs/internal/README.md`。不改代码。
2. **准备层（可独立 review）**：用 `npm install alien-signals` 加入依赖并更新 `package-lock.json`；新增 `dom.js` 与 `dom.test.mjs`；在 `index.html` 里追加未被引用的 `<template>` 骨架；保留 Alpine UI 照常运行。验收：`npm test`、`npm run build` 通过，页面行为无变化。
3. **切换层（原子提交）**：重写 `store.js`、新增 `controller.js` 和 `ui/*`、改写 `main.js` 与 `index.html`、删除 `app.js` 里的 Alpine 组件、从 `package.json` 移除 `alpinejs`、更新 `package-lock.json`、重写 `markup.test.mjs`、新增 `store.test.mjs`。验收：全量前端测试、构建、人工矩阵。
4. **收尾**：更新规格与应用文档；补性能记录；清理旧注释和调试代码。

第 2 步可以单独提交；第 3 步不再拆成「部分区域用 Alpine、部分用 signals」——两套模板运行时共存需要桥接层和两份状态源，复杂度高于收益，切换应保持原子。

## 风险与回退

| 风险 | 缓解 |
| --- | --- |
| effect 里写 signal 造成循环或重复渲染 | 硬规则：effect 只写 DOM；状态写入只经 store/controller action；code review 检查 `effect` 内是否有 `signal.set` |
| 不可变更新漏掉（尤其侧栏标题） | `store.test.mjs` 的不可变回归用例；所有嵌套数组/对象都替换 |
| 忘记 batch，流式时每事件一次 flush | `handleEvents`/`handleTurnDone`/多信号 action 统一走 `store.batch`；用 effect 计数测试和长会话压测 |
| `hidden` 被组件自身的 `display` 覆盖 | 全局 `[hidden] { display: none !important; }`；人工检查浮层/菜单/按钮 |
| keyed diff 顺序错乱 | 纯 `diffKeys` 测试 + 逆序锚点插入；会话切换/排序切换人工验证 |
| 事件监听泄漏 | 区域级 `AbortController` + 条目级 `effectScope`；拖动结束、切 session、重连都显式释放；人工切 20 次 session 抽查 |
| 滚动时序与旧版不同 | 所有布局读取统一走 `afterRender`；保留 120px/32px 阈值和 `scrollend` 兜底 |
| alien-signals API 变化 | 版本固定在 `^3.2.1`；只有 `store.js` 和 `dom.js` import 它，升级面小 |
| 浏览器兼容性 | 目标不变；`<template>`、`AbortController`、`matchMedia` 均在目标范围内；不新增 polyfill |
| 测试缝变弱 | 保留 `data-render` 安全标记和 `data-ref` 结构断言；新增 store/dom 纯单测；不引入 jsdom |
| 回退成本 | 所有改动只在前端；revert 第 3 步即回到 Alpine，不影响 transcript、存储和服务端。无数据迁移 |

## 验收标准

- [x] `grep -ri alpine ap-web/frontend ap-web/index.html ap-web/package.json ap-web/package-lock.json ap-web/build.mjs` 只剩迁移记录（源码注释、测试断言与文档），没有运行时依赖。
- [x] `npm --prefix ap-web test` 通过；新增 `store.test.mjs`、`dom.test.mjs` 被 `test` 脚本包含。
- [x] `npm --prefix ap-web run build` 通过；`dist/` 的四个产物仍为 `index.html`、`app.js`、`styles.css`、`mermaid.js`。
- [x] `./test.sh` 通过，`tools/check-deps.sh` 无违规（Odin 侧未改）。
- [x] 人工冒烟：Chrome 宽屏 / 1100px / 820px 三档、折叠与浮层、分隔条键盘与双击、排序菜单、录入框状态、消息 / 工具卡 / notice / mermaid / 滚动跟随与回到底部、刷新后偏好恢复，均无 console error。
- [x] 长会话流式期间只更新变化的条目；无全列表 DOM 重写（`keyedChildren` 按引用跳过未变化的条目）。
- [x] 无障碍属性、键盘路径、减少动态偏好与旧版一致（`aria-*` 与 `role` 静态合法值 + 信号绑定）。
- [x] 文档同步完成，`docs/internal/web.md` 与新实现一致。

尚未在本地环境覆盖、发布前仍需跑一遍：Firefox / Edge / Safari 16 的 `EventSource` 与滚动差异、真实模型 turn 的流式与取消、两个标签页并发、500 条以上消息的压测。这些是环境相关项，不影响本次签名。

## 实现记录

最终目录：

```text
ap-web/frontend/
├── main.js          # 组装根：store → 恢复偏好 → controller → mount ui/* → boot
├── controller.js    # 会话 / SSE 编排，不碰 DOM
├── store.js         # signal / computed / batch / action，不碰 DOM 与存储
├── dom.js           # ref / cloneTemplate / set* / bind* / afterRender / keyedChildren / diffKeys
├── prefs.js         # localStorage / sessionStorage 安全读写与键名常量
├── ui/{shell,rail,sessions,thread,composer,splitter}.js
├── api.js / sse.js / render.js / markdown.js / mermaid-blocks.js / mermaid-renderer.js
└── *.test.mjs
```

与提案的差异（都是有意的实现选择）：

1. **占位会话不单独建模板。** `tpl-session-draft` 只出现一次，直接留在静态骨架里并把三个动态节点标成 `data-ref`；其余重复结构才进 `<template>`。
2. **`dom.js` 同时导出 `set*` 写入函数。** 条目用一个 effect 调 `update(item)` 批量写 DOM，写入函数需要能独立调用；`bind*` 只是「effect + set*」。另外新增 `commentAnchor` 找注释锚点。
3. **`keyedChildren` 支持条目级 `dispose`。** 会话分组是嵌套 keyed list，外层条目移除时要先停内层列表；owner scope 停掉时会释放 effect，但监听器与节点由 `dispose` 收尾。
4. **`window.apWeb` 额外暴露 `dispose()`。** 页面生命周期内不卸载，保留它是为了控制台排查监听器与 effect 泄漏。
5. **`main.js` 在挂载前恢复偏好。** 首帧就是用户上次的栏宽 / 排序 / 折叠状态，避免闪一下默认布局。

体积（esbuild，`minify: true`，`legalComments: none`）：迁移前 `dist/app.js` 204,149 字节 / gzip 79,290；迁移后 161,934 字节 / gzip 65,435。raw 减少约 20.7%，gzip 减少约 17.5%；产物仍是四个文件。

## 待定问题

1. **依赖例外。** `AGENTS.md` 写「不新增第三方库」。本方案是**替换**：移除 `alpinejs`，加入 `alien-signals`（MIT，无依赖），运行时依赖数量不变。需要确认这符合规则；若不允许任何新依赖，本方案不成立。
2. **模板位置。** 推荐保留 `index.html` 静态骨架 + `<template>`，而不是把结构搬进 JS 模板字符串。前者保住现有结构测试、图标内联和可访问性 review；后者会让 `markup.test.mjs` 失去意义。
3. **不使用自定义元素 / Shadow DOM。** 推荐普通 `mount()` 函数 + light DOM。若希望用 Web Components 做区域封装，需要先解决全局 CSS 和 mermaid 的样式隔离问题，属于额外设计。
4. **保留 `render.js` 不变。** 推荐继续把事件 reducer 当纯函数；signal 只在 store 层发布。若想在 reducer 里直接用 signal，会破坏「同一事件序列可逐字节断言」的测试方式。
5. **内部 DOM 结构调整。** 消息区需要一个注释锚点，会话分组仍用 `.session-group` 包裹；这些是内部结构变化，不改变视觉和 CSS 断点。需要确认可以接受。
6. **`window.apWeb` 调试入口。** 推荐保留并扩展为 `{ store, controller }`，字段从属性变成函数调用；它不在任何规格里，属于开发便利。
7. **alien-signals 版本。** 推荐 `^3.2.1`（当前最新稳定版，函数调用式 API）。如果团队希望锁死小版本，可改成精确版本。

## 相关文档

- [web.md](../web.md)：`ap-web` 的 HTTP/SSE、并发与前端规格
- [module-dependency-graph.md](../../design/module-dependency-graph.md)：浏览器前端 ES module 依赖图
- [web-ui-v3.md](../../design/web-ui-v3.md)：三栏工作台的布局决策与用户故事
- [integration.md](../integration.md)：新前端接入 `ap` 的进程契约与 turn 生命周期
- [dependencies.md](../dependencies.md)：Odin 包边界（本提案不触碰）
