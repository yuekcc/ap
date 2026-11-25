# ap-web：HTTP/SSE 前端

`ap-web` 把 `ap` 暴露给浏览器。它不实现 agent、provider、工具或 transcript 写入。每个用户 turn 启动一个新的 `ap` 子进程，通过 `stream-json` 读取事件，再经 HTTP API 和 SSE 转发给前端。通用的进程契约和 turn 生命周期见 [integration.md](integration.md)，事件 schema 见 [react-loop-and-session.md](react-loop-and-session.md)。

```text
浏览器 ──fetch──► ap-web ──spawn──► ap --print0 --output-format stream-json [-s <id>]
                     │                        │
                     │◄── HTTP API ───────────┤
                     │◄── SSE: 转发的事件 ────┤  stdout: 事件
                     │                        │  stderr: 日志（缓存）
                     ▼
               Web UI（alien-signals + 原生 DOM，内置于 exe）
```

一个 `ap-web/` 目录承载 Odin 服务器、前端源码和前端构建配置。产物是单个 `ap-web.exe`。Web 资源在编译期读入 exe，不需要随 exe 分发文件。

## 进程模型

`ap-web` 主进程有以下几类线程：

| 线程 | 职责 |
| --- | --- |
| accept 线程 | `core:net` 阻塞 accept，建立连接后交给连接线程 |
| 连接线程 | 每个连接一个，处理 HTTP 请求、静态资源、API 或 SSE；同时最多 256 个（`MAX_CONNECTIONS`），超限的连接直接关闭 |
| turn 线程 | 每轮 turn 一个，spawn `ap`、泵 stdout、广播事件、组装 `turn_done` |
| heartbeat 线程 | 每 15 秒向 hub 投递一次注释行和 `ping` 事件 |
| shutdown watcher | 轮询信号标志，执行收尾 |

- 连接线程使用自己的临时分配器，请求结束回收。
- 每个 session 在 runner 注册表里有一条运行态：`key`、`session_id`、`cwd`、`running`、`turn`、取消令牌和 turn 线程句柄。
- 同一 session 同一时刻只允许一个 turn。不同 session 可以并发。
- turn 线程独立于连接线程。浏览器断开 SSE 不会取消 turn。
- 进程收到 `SIGINT` 或 `SIGTERM` 时，信号处理器只置原子标志。watcher 线程停止心跳、取消所有运行中的 turn、最多等待 5 秒，再销毁 hub 并清理作业表。关停期间新 turn 返回 503。
- Windows 监听使用 `SO_EXCLUSIVEADDRUSE`。Unix 使用 `SO_REUSEADDR`，崩溃后可以立即重启。
- 每个连接设置 `TCP_NODELAY`，避免 SSE 事件被 Nagle 攒包。

## HTTP 层

服务器只用 `core:net` 手写 HTTP/1.1 的最小子集。

请求侧遵循下面的规则。

- 方法只支持 GET、POST 和 DELETE。其余方法返回 405。
- 解析 request line、headers 和 body。POST 必须带 `Content-Length`。空 body 的 POST 也要写 `Content-Length: 0`。
- 不支持 `Transfer-Encoding`，收到即返回 400。
- 不支持 100-continue、管线化、range、`If-Modified-Since`、gzip 和多 part。
- 请求体上限 2 MiB，超限返回 413，错误码 `payload_too_large`。
- 单行头部上限 32 KiB，头部总数上限 100。裸 LF 或裸 CR 返回 400。
- 路径做 percent-decode。query 只切分，不把 `+` 转成空格。

响应侧遵循下面的规则。

- 普通响应用 `Content-Length` 定长。304 不带 `Content-Length`。
- SSE 用 chunked，并设置 `Connection: close`。
- HTTP/1.1 默认 keep-alive。请求带 `Connection: close`、响应状态码大于等于 400、或 SSE 响应后关闭连接。
- 连接空闲等待上限 30 秒。开始读取某个请求后改为 10 秒，并且整个请求另有 15 秒总期限（`REQUEST_TOTAL_TIMEOUT`）：慢速客户端靠每次 recv 重置超时无法长期占住连接线程。超过总期限返回 408 后关闭连接；单次读超时仍直接关闭、不写响应。
- `/api/*` 的解析错误返回 `{"error":{"code","message"}}`。静态资源错误返回纯文本。
- API 的 JSON 编码失败固定返回 500 `internal_error`。

静态资源按下面的规则处理。

- `assets.odin` 用 `#load_directory("dist")` 在编译期把 `dist/` 读进 exe。
- `--web-root <dir>` 改为从磁盘读取。两条路径共用同一套查找、MIME、ETag 和兜底逻辑。
- 根路径和目录路径回落到 `index.html`。文件名精确匹配。
- 路径中出现 `..` 或 `.` 段返回 403。磁盘模式解析符号链接后必须仍落在 web-root 内。
- 单文件上限 8 MiB，超限返回 413。
- MIME 按扩展名查表：html、htm、js、mjs、css、json、svg、png、ico、wasm，其余为 `application/octet-stream`。
- `ETag` 是文件内容的 FNV-1a hash。命中 `If-None-Match` 返回 304。静态响应带 `Cache-Control: no-cache`。

### 请求级内存所有权

- `serve_connection` 每个请求建一个 `runtime.Arena`，在解析请求、调用 handler 和写响应的整个过程中把它作为 `context.temp_allocator`，响应写完立即销毁。请求字段、响应头和 JSON body 都从该 arena 分配。
- handler 内同步调用的库**不得** `free_all(context.temp_allocator)`：那会回收请求级内存，之后写响应头会踩到已释放的 `Http_Header`。库只能重置自己持有的 arena。
- `ap-core/client` 的 turn 泵每次调用 `turn_run` 都建自己的 arena，进出时替换并恢复 `context.temp_allocator`。
- 需要跨请求存活的数据用 `runtime.heap_allocator()` 克隆（例如 runner 里的 session 字段），不能留在请求 arena 里。

## HTTP API

请求和响应都是 JSON。错误统一为 `{"error": {"code": "...", "message": "..."}}`。

| 方法 | 路径 | 请求 | 响应 | 说明 |
| --- | --- | --- | --- | --- |
| GET | `/api/health` | – | `{ok, version}` | 探活 |
| GET | `/api/config` | – | `{model, agent, max_steps, max_tokens, cwd, platform}` | 启动参数快照。`cwd` 是默认目录。`platform` 取值 `windows`、`linux`、`darwin` 或 `unix` |
| GET | `/api/session/current` | `?session_key=<key>` 可选 | `{session_key, session_id, cwd, running, turn}` | 带 key 返回该 session 的运行态。不带 key 返回最近活跃 session，仅作新标签页兜底 |
| POST | `/api/session/new` | `{cwd?}` | `{session_id: null, session_key, cwd}` | 分配 slot，不落盘。`cwd` 决定 slot 所属 project |
| GET | `/api/sessions` | `?cwd=<dir>` 可选 | `[{session_id, ts, turns, running}]` | 该 project 的 session 列表，按文件 mtime 倒序。`turns` 数 `turn_start` |
| POST | `/api/session/resume` | `{session_id, cwd?}` | `{session_id, session_key, cwd}` | 注册或切换运行态，不校验 transcript |
| GET | `/api/projects` | – | `[{cwd, hash, latest_ts, sessions}]` | 枚举 `path.txt` 发现 project，按最近活动倒序。默认 project 有 session 时也会补进结果；session 摘要按 transcript 的 mtime/size 缓存 |
| GET | `/api/history` | `?session_id=<id>&cwd=<dir>&since_seq=<n>&limit=<n>` | `{events: [...], truncated}` | 重放 transcript，解析 blob 引用并截断工具结果；默认返回最新 1000 条，最多 5000 条或 8 MiB |
| GET | `/api/cwd` | – | `{cwd}` | 默认工作目录，不随 session 切换 |
| POST | `/api/cwd/pick` | – | `200 {cwd}`、`409 cancelled`、`409 picker_busy`、`501 not_implemented`、`500 cwd_failed` 或 `500 picker_failed` | 弹系统目录选择框。只返回路径，不修改默认目录 |
| POST | `/api/turn` | `{prompt, session_key?, cwd?, model?, agent?, max_steps?, max_tokens?}` | `202 {accepted: true, session_key}` | 启动一轮。同一 session 运行中返回 409 `turn_running` |
| DELETE | `/api/turn` | `?session_key=<key>` 可选 | `202 {cancelled: bool}` | 取消目标 session 的 turn。不带 key 时退化为当前 session 或唯一在跑的 session |
| GET | `/api/events` | `?session_key=<key>` 可选 | SSE 流 | 只订阅该 session。不带 key 时订阅全部，用于兼容和测试 |

其他端点的常见错误：

- `POST /api/session/new`：无效 `cwd` 返回 400 `invalid_cwd`。
- `GET /api/sessions`：无效 `cwd` 返回 400 `invalid_cwd`。
- `POST /api/session/resume`：缺 `session_id` 返回 400 `invalid_request`。
- `GET /api/history`：缺 `session_id` 返回 400 `invalid_request`，transcript 不存在返回 404 `session_not_found`。
- `GET /api/events`：订阅失败返回 500 `internal_error`。

`POST /api/turn` 按下面的状态码返回错误。

| 状态 | code | 条件 |
| --- | --- | --- |
| 400 | `invalid_json` | 请求体不是 JSON 对象 |
| 400 | `prompt_empty` | `prompt` 为空 |
| 400 | `invalid_request` | `max_steps` 或 `max_tokens` 不是正数 |
| 400 | `invalid_cwd` | `cwd` 不存在或 project 无法定位 |
| 413 | `prompt_too_large` | `prompt` 超过 1 MiB |
| 409 | `turn_running` | 同一 session 已有 turn |
| 503 | `shutting_down` | 进程正在关停 |
| 500 | `internal_error` | 线程创建失败等内部错误 |

`cwd` 的取值顺序是请求中的 `cwd`、该 session 已登记的 `cwd`、`ap-web` 默认目录。`session_key` 只用于定位运行态，不传给 `ap`。请求中的 `model`、`agent`、`max_steps`、`max_tokens` 会覆盖 `ap-web` 启动参数中的默认值。

`GET /api/history` 的 `since_seq` 只返回 `seq` 更大事件，`limit` 取 1–5000，默认 1000。超出条数或 8 MiB 字节预算时返回**最新**的窗口并从头部丢弃旧事件，同时 `truncated` 为 `true`；事件顺序不变。逐行读 JSONL，并做以下增强：

- `session_start.content_ref` 解析成 `content`。blob 缺失时用 `content_preview`。
- `message_end` 文本块的 `text_ref` 解析成 `text`。
- `tool_use` 的 `input_ref` 解析成结构化 `input`。解析失败或 blob 缺失时用 `input_preview`。
- `tool_execution_start` 补一个 `args_preview`。
- `tool_execution_end` 超过 200 行或 20000 字节时换成 `content_preview`，并写 `content_truncated: true`。

这些 `*_preview` 回退只用于浏览器展示。`ap` 自己恢复上下文时，blob 缺失或损坏会让恢复失败并退出 2。

## SSE

SSE 帧格式固定为：

```text
event: ap
data: {"v":1,"seq":7,"ts":...,"type":"message_update","delta":{"text":"..."}}
id: 42

```

| 事件 | data | 说明 |
| --- | --- | --- |
| `ap` | `ap` 的 stream-json 原始行 | 不重新序列化，未知字段原样保留 |
| `turn_done` | `{exit_code, stop_reason, usage, stderr_preview}` | 一轮结束信封 |
| `ping` | `{ts}` | 心跳事件，同时发送 `: ping` 注释行 |

- `id` 由 hub 单调分配，不是 transcript 的 `seq`。
- 单 session 内的事件顺序与 `ap` 的 stdout 行序一致。服务端不做 `seq` 去重。
- `turn_done.stop_reason` 优先取 `turn_end.stop_reason`，没有时取 `session_end.reason`。主动取消但没有收尾事件时填 `cancelled`。其他缺失为 null。
- `GET /api/events?session_key=<key>` 只发送该 session 的 `ap` 和 `turn_done` 帧。订阅 slot key 或真实 session id 都能命中。不带参数时保持全量订阅。
- 心跳每 15 秒一次，发给所有订阅者。
- 当前不支持 `Last-Event-ID` 断点续传。重连后前端重新读 history，再按 transcript `seq` 去重。
- 订阅者 channel 缓冲 256 帧。满了说明连接线程不再消费，hub 丢弃该订阅者并关闭 channel，turn 不受影响。写失败同样只丢弃订阅者。

## 目录选择

浏览器拿不到真实的 Windows 绝对路径。`<input type="file">` 只暴露 `C:\fakepath\`，`showDirectoryPicker()` 只给句柄。`<input>` 也没有赋值 API。所以目录选择由 `ap-web` 侧完成。

Windows 上的实现如下。

- 使用 `IFileDialog`，选项是 `FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM`。
- COM 在专用 STA 线程上初始化。`Show(NULL)` 阻塞到用户关闭对话框。
- 请求本身占用它的连接线程等待结果，accept 循环和其他连接不受影响。
- 进程启动时设置 per-monitor DPI awareness V2，旧系统退回 system-aware。

Unix 上的实现如下。

- phase 1 没有统一的原生目录对话框 API，返回 501 `not_implemented`。前端入口只有顶部「+」，点击后提示当前平台不支持。

目录选择遵循下面的语义。

- 用户关闭对话框返回 409 `cancelled`。前端静默忽略。
- 同一时刻只允许一个 pick 请求。重复调用返回 409 `picker_busy`。
- 成功只返回规范化后的绝对路径。服务器不修改进程级 `cwd`，也不清空其他 session。
- 前端随后调用 `POST /api/session/new {cwd}`，在该目录开新 slot。
- `cwd` 属于每个 `Session_Runtime`。不同 project 的 turn 可以同时运行。
- `ap-web` 重启后默认 project 回到启动目录。左栏的工作空间列表仍可通过 `/api/projects` 打开其他目录的历史 session。
- 前端把本标签页的 `{key, id, cwd}` 存到 `sessionStorage`。刷新时优先按真实 id 加 cwd 恢复。

## 前端

前端依赖下面这些包。

- `alien-signals`、`markdown-exit`、`github-markdown-css`、`mermaid`。
- 构建期依赖 `esbuild`；`bootstrap-icons` 只在构建期内联图标，不进 bundle。
- `EventSource` 和 `fetch` 使用浏览器原生实现。视图用原生 DOM API（`<template>`、`cloneNode`、`addEventListener`、`AbortController`、`matchMedia`、`requestAnimationFrame`），没有模板运行时，也不做表达式求值。
- `build.mjs` 的目标是 Chrome 110、Edge 110、Firefox 110、Safari 16。不写 polyfill 和厂商前缀。
- `dist/` 的产物是 `index.html`、`app.js`、`styles.css`、`mermaid.js`。`mermaid.js` 单独打包、按需加载，`index.html` 不直接引用它。

前端结构遵循下面的分层。

```text
main.js ──► controller.js ──► store.js ──► render.js / alien-signals
   │             │                ▲
   │             └──► api / sse / prefs
   └──► ui/* ─────────────────────┘（只读 store、调用 controller 的 action）
         └──► dom.js / markdown.js / mermaid-blocks.js
```

- `main.js` 是唯一组装根：创建 store → 恢复本地偏好 → 创建 controller → 挂载 `ui/*` → `boot()`。页面生命周期内不卸载，仍保留一个全局 `dispose()`。
- `controller.js` 承接会话与 SSE 编排（boot、恢复指针、history、订阅、发送、交接、标题、取消、目录选择、事件队列），不碰 DOM。需要滚动或聚焦时只递增 `store.scrollRequest` / `store.focusNonce`，由 `ui/*` 在下一帧处理。
- `store.js` 用 `signal` / `computed` 保存 transcript 投影、会话与 UI 状态，并提供只改信号的 action。一次改多个信号的 action 走 `startBatch` / `endBatch`，一帧只 flush 一次。信号按引用比较，嵌套数组和对象一律替换，不原地改。
- `render.js` 仍是「事件 → 纯视图状态」的 reducer，不依赖 DOM 或信号库。同一 transcript 与事件序列产出逐字节相同的结果。
- `dom.js` 是最小绑定层：`ref` / `cloneTemplate` / `set*` / `bind*` / `afterRender` / `keyedChildren` / `diffKeys`。它不是模板引擎；`bind*` 只把写入函数包进 effect。
- `prefs.js` 统一 `localStorage` / `sessionStorage` 的安全读写与键名常量。键名 `ap-web:session`、`ap-web:sidebar-collapsed`、`ap-web:sort`、`ap-web:split` 保持不变。
- `ui/*` 按区域拆成 shell、rail、sessions、thread、composer、splitter，只读 store、调用 controller 的 action、写 DOM。每个区域在 `mount()` 里建一个 `effectScope` 和一个 `AbortController`，监听器用 `{ signal }` 挂载，返回 `dispose()` 一起释放。

视图与调度遵循下面的规则。

- `index.html` 只放静态骨架与 `<template>`。动态节点带 `data-ref`，重复结构按 kind 一个模板。模板是可信静态内容，用户数据、工具输出和事件文本一律走 `textContent`，只有 assistant 文本经 `dom.setMarkdown` 写 `innerHTML`。
- 初始应收起的节点直接写 `hidden`；CSS 用 `[hidden] { display: none !important; }`，不再有 `x-cloak`。
- 消息列表用 `dom.keyedChildren` 做 O(n) 的 key diff：外层只有一个 effect 读 `items`，只有内容变化的条目重跑自己的 effect。条目 effect 挂在 `keyedChildren` 自己的 owner scope 下，条目移除时 `stop()` + `abort()` + `el.remove()`。注释锚点保证条目仍是 `.messages` 的直接子元素。
- SSE 增量继续先入队：页面可见时用 `requestAnimationFrame`，后台标签页用 `setTimeout(..., 250)`，一次 flush 只调用一次 `store.handleEvents`。`turn_done` 必须排在本轮增量之后应用。
- effect 只写 DOM，不写应用状态。需要读 `scrollHeight` / `getBoundingClientRect` 的后续动作统一走 `afterRender`（按帧去重，替代 `$nextTick`）。
- 滚动语义不变：距底部 ≤ 120px 时自动跟随；距底部 > 32px 时露出「回到底部」；平滑滚动优先，`scrollend` 不可用时 400ms 后补一次贴底；`prefers-reduced-motion: reduce` 时直接跳到底。
- 分隔条拖动期间只给正在拖的那条高亮；`pointermove` / `pointerup` / `pointercancel` / `blur` / `visibilitychange` 挂在 window / document 上，用一次性的 `AbortController` 收尾，不使用 `setPointerCapture`。
- 调试入口是 `window.apWeb = { store, controller, dispose }`。store 的字段是函数；`dispose()` 释放所有区域。

样式与安全边界不变：只有 assistant 文本走 Markdown，用户输入与工具输出仍是 `textContent`；mermaid 占位块保留源码，消息结束后才渲染，`securityLevel` 固定为 `strict`。

样式遵循下面的基线。

- 先引入 `github-markdown-css`，再用 Josh's Custom CSS Reset，应用样式接在后面。
- 只提供浅色主题。`color-scheme: light`，不写暗色分支。
- 视觉风格是 iOS 18 的扁平分组界面：应用直接铺满视口，不留外框和外边距；系统分组底色 `--bg-grouped` 用于侧栏，消息区用白色 `--bg`；不用背景模糊、投影和渐变。
- 页面是三栏工作台：左侧工作空间栏（`--rail-w`）、中间对话栏（`--sessions-w`）、右侧对话正文（吃剩下的宽度），栏间用 1px `--separator-soft` 分隔。外层用 flex 而不是 grid：折叠一栏只是 `display: none`，不需要重算列宽。
- 两个侧栏的宽度可拖动：分隔条是 `role="separator"`、`tabindex="0"` 的 0 宽元素，靠伪元素向两侧扩出 10px 命中区。指针拖动改宽，方向键 ±16px（Shift ±64px），`Home`/`End` 到边界，双击回默认 260px。宽度以行内 `--rail-w` / `--sessions-w` 写在 `.app` 上，偏好存 `localStorage`，取值范围 176–420px 且不超过视口宽度的 35%。拖动监听挂在 window 上，松手事件丢失（窗口外松手、切走应用）时靠「没有按键的 pointermove」和窗口失焦收尾，只有正在拖的那条分隔条高亮。
- 工作空间栏底色 `--bg-grouped`，标题行依次是 `ap` 字标、「打开新工作空间」、「排序」、「折叠」。工作空间是竖列表，当前项用 `--accent-tint` 浅底，`title` 放完整路径。
- 对话栏底色 `--bg`，标题行是「对话」标签加「打开文件管理器」「打开终端」两个图标按钮，下面依次是「新对话」按钮（outline：1px `--accent-line` 描边、透明底、图标与文字居中）和按时间分组的对话列表。
- 对话正文栏是 `grid-template-rows: auto minmax(0, 1fr) auto`：标题行（标题 + 刷新 + 累计 token）、消息区（唯一滚动容器）、录入框。
- token 用量的悬停提示带上模型、agent 和输入/输出/缓存/推理分项，模型名不再单独占一个 chip。
- 消息区上方单独一行、右对齐的小胶囊显示本会话最近一次 `write_file` / `edit_file` 的 `file_path`，只显示文件名，点击复制完整路径；没有改写文件时整行不占高度。
- 系统色与形状收敛成 `--bg-grouped`、`--fill`、`--separator`、`--accent`、`--radius-*` 等自定义属性。改主题只改这些变量，不在选择器里散写颜色。
- 强调色用 systemBlue `#007aff`；用户消息是纯色填充的 iMessage 气泡（18px 圆角，右下角 4px），助手文本保持正文色。
- 交互只保留 120ms 的背景色淡入和聚焦色淡入；运行中脉冲与减少动态偏好下的禁用沿用原语义。
- 页面骨架是单行三栏 flex；对话正文栏内部用 grid（标题行 / 消息区 / 录入框），消息区自己滚动。
- 块级组件用 flex。宽度降到 1100px 时工作空间栏变成左侧浮层，展开入口落在对话栏标题行最左；降到 820px 时对话栏也变成浮层，由标题行的「对话记录」按钮打开，点遮罩或选项后关闭；紧凑屏输入框字号不小于 16px，避免 iOS 聚焦时自动放大。

前端行为与 `ap-tui` 对齐。

- store 状态机与 `ap-tui` 对齐。`message_update` 按 delta 累积。`message_end` 只在没有 delta 时补全文。
- `tool_execution_start` 建卡片。`tool_execution_update` 增量追加。`tool_execution_end` 标记状态、耗时和退出码。非流式结果超过 200 行或 20000 字节时截断。
- 用户输入和工具输出用 `textContent` 写入。只有 assistant 文本走 Markdown。
- Markdown 用 `markdown-exit`，设置 `html: false`、`linkify: true`、`breaks: true`。原始 HTML 被转义，`javascript:` 和 `data:` 链接不会变成可点链接。外链带 `target="_blank"` 和 `rel="noopener noreferrer"`。图片设置 `loading="lazy"` 和 `referrerpolicy="no-referrer"`。
- 语言标记为 `mermaid` 的围栏先渲染成保留源码的占位块，消息结束后由 `mermaid-blocks.js` 用 MutationObserver + 防抖把占位块换成 SVG。mermaid 本体在 `dist/mermaid.js`，第一次出现图表时才加载；渲染失败时保留源码并显示一行错误。`securityLevel` 固定为 `strict`，图表里的 `%%{init}%%` 或 frontmatter 不允许覆盖它。
- 减少动态偏好下的全局过渡规则排除 `svg` 及其后代：给 SVG 元素加 `transition-duration` 会让 Chrome 的 `getBBox` 返回错误尺寸，mermaid 会把图表撑到几千像素。
- 工作空间列表按 `/api/projects` 的 `cwd` 分组。当前 project 即使还没有落盘 session，也在列表里本地合成一个空组。
- 对话栏只展示当前工作空间的对话记录，按浏览器本地自然日分成「今天 / 昨天 / 7天内（2–7 天前）/ 更早」，空组不渲染；取不到时间戳的会话落进「更早」。每项两行，第一行标题，第二行是本地时间（`MM-DD HH:mm`）和状态点，`running` 为真时是脉冲点。列表排序（最近活动 / 名称）只决定组内先后：分组顺序固定为今天到更早，排序和工作空间排序共用一个 `localStorage` 偏好，都只在浏览器本地完成，不改服务端返回顺序。切换工作空间时打开该目录最近一条 session，没有记录就在该目录新建 slot。
- 每个标签页持有自己的 `session_key`，SSE 按该 key 过滤。
- 打开已有 session 的顺序是 `POST /api/session/resume`、`GET /api/history`、`GET /api/events`。history 到达前保留旧 transcript，新内容一次性替换；history 读取失败才清空旧内容并落 notice，避免切换对话时闪过空状态。
- 首次订阅成功后补一次 history，填上 history 与 subscribe 之间的空档。
- 断线重连后先读 `GET /api/session/current` 修正 `running` 和 `turn`，再读 history 补齐，按 `seq` 去重。
- 单页应用，没有路由库。客户端按 `running` 阻止重复发送，服务端再用 409 兜底。

## 构建与运行

前端构建使用下面的命令。

```sh
npm --prefix ap-web install
npm --prefix ap-web run build
npm --prefix ap-web run watch
```

`dist/` 不提交进仓库，编译 `ap-web` 前必须先构建它。只改 Odin 代码时不需要重装前端依赖。

全量构建执行下面的命令。

```sh
./build.sh
```

构建脚本按下面的顺序执行。

1. 找到 `npx` 时先执行 `npm --prefix ap-web run build` 刷新 `dist/`。找不到时使用本地已有的 `dist/`，两者都没有则报错退出。
2. 依次构建 `cmd/ap`、`cmd/ap-tui`、`cmd/ap-web`、`cmd/magi-cli`，产物在 `build/`。
3. Windows 的产物带 `.exe`。

包边界检查不在构建脚本里，由 `./test.sh` 在测试之后统一跑一次，避免同一套 `odin build` 执行两遍。

`#load_directory("dist")` 在编译期读取 `ap-web/dist/`。目录不存在时编译失败。这就是前端构建必须先于 Odin 构建、且新克隆的仓库要先跑一次前端构建的原因。

启动服务使用下面的命令。

```sh
./build/ap-web
./build/ap-web --web-root ap-web/dist
./build/ap-web -c
./build/ap-web -s ses_20261022_120000_abcdef123456
```

默认地址是 `http://127.0.0.1:8417`。

## CLI

```text
ap-web [--port 8417] [--host 127.0.0.1] [--web-root <dir>]
       [--agent-bin <path>] [-s <id>] [-c] [--model ...] [--agent ...]
       [--max-steps ...] [--max-tokens ...] [--config-dir <dir>] [--cwd <dir>]
```

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--port <n>` | `8417` | 监听端口，范围 1 到 65535 |
| `--host <addr>` | `127.0.0.1` | 监听地址。显式非回环地址会打印安全警告 |
| `--web-root <dir>` | 空 | 非空时静态资源从磁盘读取 |
| `--agent-bin <path>` | 空 | `ap` 可执行文件。查找顺序见 [integration.md](integration.md) |
| `--config-dir <dir>` | `~/.ap` 或 `AP_CONFIG` | 传给 `ap` 的配置目录 |
| `--model <id>` | 空 | 传给 `ap --model` |
| `--agent <name>` | 空 | 传给 `ap --agent` |
| `--max-steps <n>` | 空 | 传给 `ap --max-steps`，必须是正整数 |
| `--max-tokens <n>` | 空 | 传给 `ap --max-tokens`，必须是正整数 |
| `--cwd <dir>` | 启动目录 | 初始工作目录。传了就 `chdir`，并作为默认 project |
| `-c`, `--continue` | 关 | 启动时恢复当前 project 最近的根 session |
| `-s`, `--session <id>` | 空 | 恢复指定 session。transcript 不存在时返回 2 |
| `-h`, `--help` | – | 显示帮助 |
| `--version` | – | 显示版本 |

`-s` 和 `-c` 互斥。`ap-web` 不暴露 `--no-agents-md` 和 `--no-skills`。它拉起的 `ap` 使用默认上下文，`$AP_CONFIG/SYSTEM.md` 仍会生效。

## 依赖方向

```text
ap-web ──► ap-core/client ──► ap-core/platform、ap-core/protocol ──► core、vendor
       └─► ap-core/protocol
```

`ap-web` 不 import `apcore`、`ap-core/engine`、`ap-core/platform`、`ap-cli` 或 `ap-tui`。完整白名单见 [dependencies.md](dependencies.md)。

`tools/check-deps.sh` 在构建期阻止前端直接 import 底层包。事件解析、spawn、pipe、project hash 和 blob 读取都在 `ap-core/client` 和 `ap-core/protocol` 中共用一份。

## 安全

1. 默认只监听 `127.0.0.1`。显式监听非回环地址时，启动日志打印警告。agent 可以执行任意 `bash` 命令。
2. 没有鉴权。能访问端口的人就能使用 shell。默认回环是主要边界。
3. 不做 CORS 放开。同源部署，`Origin` 校验留给 phase 2。
4. 静态资源来自编译期内置表或 `--web-root` 目录。磁盘模式解析路径和符号链接后必须仍在 root 内。
5. 请求体上限 2 MiB。`POST /api/turn` 的 prompt 上限 1 MiB。
6. 转发给 `ap` 的参数全部来自服务端白名单映射，不拼接 shell。
7. 不提供 HTTPS。需要外网或多用户时由外部反向代理承担 TLS 和访问控制。

## 额外语义

- `POST /api/cwd/pick` 会一直占用自己的连接线程，直到对话框关闭。这是同步取回结果所必需的。
- `POST /api/session/resume` 不检查 transcript 是否存在。错误交给 `/api/history` 或下一轮 `ap`。
- `GET /api/session/current` 不带 key 时返回 runner 的当前指针，仅作兜底。多标签页下不存在全局唯一的当前 session。
- `DELETE /api/turn` 用 `cancelled` 布尔值区分“确实取消”和“本来没在跑”。
- `POST /api/turn` 在参数边界就拒绝非正的 `max_steps` 和 `max_tokens`。
- 关停中收到新 turn 返回 503 `shutting_down`。
- 运行中的 session 不能改 `cwd`。下一轮开始前才允许更新运行态的目录。
- Windows 上取消是整树强制终止，transcript 可能停在 `tool_execution_start`。没有 `turn_end` 或 `session_end` 时，前端合成 `cancelled`，刷新后仍能重放已经落盘的部分。
- Unix 上取消走 `SIGTERM`，`ap` 有机会写完收尾事件。

## 测试

```sh
odin test ap-web -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
npm --prefix ap-web test
```

测试覆盖下面几类行为。

- HTTP 解析：request line、headers、body 上限、keep-alive、413 错误体。
- SSE：帧编码、hub 广播、topic 过滤、缓冲满时丢弃订阅者、心跳。
- 路由、内置资源和磁盘资源查找、ETag、路径穿越。
- 目录选择：成功、取消、并发 busy、Unix 501、Windows vtable。
- runner：完整 turn、单飞、跨 session 并发、取消、stderr、线程回收、关停。
- 前端纯函数：delta 累积、工具卡片、history 重放、`seq` 去重、`turn_done` 状态机、请求构造、Markdown 转义。
- store 信号层：批量发布只触发一次 effect、派生值（标题、用量、状态、侧栏可见性、分组与排序）、`syncCurrent` / 交接的视图重置、`setSessionTitle` 的不可变更新、焦点与滚动请求计数器。
- controller 层：注入假 api / stream 后验证会话切换——history 到达前保留旧 transcript，读取失败才清空并落 notice。
- dom 层：`diffKeys` 纯逻辑、写入函数「值相同不写」、`keyedChildren` 复用与重排、条目 effect 不受外层列表 effect 牵连（owner scope + `setActiveSub` 回归用例）、`afterRender` 按帧去重。
- 结构断言：`index.html` 不含 Alpine 指令、模板 id 与 `ui/*.js` 的 `data-ref` / `cloneTemplate` 对齐、`[hidden]` 规则、图标占位与 dist 内联。
- 集成测试使用本地 fake agent，不访问外网。

手动矩阵：Chrome、Edge、Firefox 的 `EventSource` 行为，两个标签页各跑一个 session，Windows 和 Linux 的进程树终止。

## phase 2 待做

1. `Last-Event-ID` 断点续传，用 transcript 的 `seq` 补差。
2. diff 渲染、reasoning 展示开关、usage 状态条。
3. session fork、session 删除、文件附件上传。
4. Unix 目录选择（探测 `zenity` 或 `kdialog`）。
5. 远程访问模式：`--host` 放开加 token 鉴权，HTTPS 交给外部代理。

## 相关文档

- [integration.md](integration.md)：通用进程契约、三个流、turn 生命周期、取消
- [react-loop-and-session.md](react-loop-and-session.md)：事件 schema、恢复与 fork
- [cli-and-config.md](cli-and-config.md)：`ap` 的参数、配置和退出码
- [tui.md](tui.md)：终端前端的同类实现
- [dependencies.md](dependencies.md)：包边界与 import 白名单
- [architecture.md](architecture.md)：模块职责、进程模型和关键接口
