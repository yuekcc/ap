# 05: Web UI（Alpine.js + esbuild 前端）

**What to build:** 浏览器端完整 UI：`package.json`（仅 esbuild + alpinejs 两个依赖，scripts: build/watch）、`build.mjs`（frontend/main.js → dist/app.js + dist/styles.css，拷贝 index.html）、`index.html`、`frontend/` 全套（main.js 入口、styles.css 以 Josh's Custom CSS Reset 开头、api.js fetch 封装、sse.js EventSource 封装含重连与按 seq 去重、store.js Alpine.reactive store、render.js 事件→视图模型复刻 ap-tui 渲染规则、app.js 输入框/发送/取消/session 切换）。布局按 spec：页面骨架 grid（auto minmax(0,1fr) auto），其余块级布局 flex。状态机 idle/running；message_update 按 delta 累积、message_end 只补缺；工具卡片 start 建卡/update 增量追加/end 标 ✓✗ 耗时退出码、超限截断提示；所有模型/工具输出走 textContent 不 innerHTML。打开页面 GET /api/history 渲染存量再订阅 /api/events，seq 重叠跳过；platform 非 Windows 时隐藏目录选择入口。`dist/` 产物提交进仓库。UI 能真实完成一轮对话（对着本机 bin/ap）。npm 不可用的环境不受影响（dist 已提交）。

参考：docs/web.md「前端」「布局约定」「历史与实时的衔接」；笔记 events-notes.md（事件序列与渲染规则）。

**Blocked by:** 04（API 与 SSE 流成型后 UI 才能端到端联调）

**Status:** ready-for-agent
