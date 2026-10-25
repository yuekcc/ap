# ap-web：HTTP/SSE 服务器与 Web UI

`ap-web` 是 ap 的第三个外部消费者（CLI 脚本、ap-tui 之外），把 agent 能力以 HTTP + SSE 的形式暴露给浏览器。它**不是** ap 的一部分：不实现 agent、provider、工具或 transcript 写入，每个用户 turn 都启动一个新的 `ap` 子进程，通过 `stream-json` 读取事件并转发给浏览器——进程模型与 [tui.md](tui.md) 的 ap-tui 完全同构，只是「渲染器」从终端换成了 HTTP 连接上的浏览器。

```
浏览器 ──fetch──► ap-web ──spawn──► ap --print0 --output-format stream-json [-s <id>]
                    │                        │
                    │◄── HTTP API ───────────┤
                    │◄── SSE: 转发的事件 ────┤  stdout: 事件
                    │                        │  stderr: 日志（缓存）
                    ▼
              Web UI（Alpine.js SPA，内置于 exe）
```

一个 `ap-web/` 目录承载全部内容：Odin 服务器源码、前端源码、前端构建配置；最终产物是单个 `ap-web.exe`（Web 资源编译期内置，不需要随 exe 分发任何文件）。

## 目标

1. 用 `core:net` 手写 HTTP/1.1 + SSE 服务器，零第三方依赖（不引入 laytan/odin-http）
2. 复用 ap-tui 已验证的子进程模型与事件解析；协议层复用 `internal/` 与 ap-tui 的既有结构
3. Web UI 用 Alpine.js + 原生 `fetch`/`EventSource`，esbuild 打包；npm 依赖为 `esbuild`（dev）+ `alpinejs`、`markdown-exit`、`github-markdown-css`（runtime）
4. 跨平台行为与 ap-tui 一致（Windows/Linux/macOS）；产物形态与 ap 一致：单 exe，无运行时文件依赖

## 非目标

1. 不做多用户/鉴权/CORS 开放：默认只监听 `127.0.0.1`，是单用户本地工具
2. 不做 HTTPS/TLS 终止：本地回环明文；需要外网时由反向代理承担
3. ap 本体不感知 HTTP；不修改 ap 的 CLI 契约与事件 schema
4. 不做 HTTP/2、WebSocket、gzip
5. 不内嵌 Node 运行时；esbuild 只是构建期依赖，运行时不需要 Node

## 目录结构

```
ap-web/
├── main.odin            # 入口：参数解析、监听、accept 循环（package main）
├── server.odin          # HTTP 层：请求解析、响应写出、keep-alive 状态机
├── http_util.odin       # MIME、percent-decode、状态行/头部写出
├── api.odin             # 路由表 → handler；JSON 编解码
├── sse.odin             # SSE 帧编码、hub（订阅表 + 互斥锁 + 广播）、心跳
├── agent.odin           # 复刻 ap-tui/agent.odin：spawn ap、pipe、事件泵、退出码
├── runner.odin          # session registry：按 session 分飞、取消、stderr 缓存、turn_done 组装
├── events.odin          # 与 ap-tui/events.odin 同构的 Event 解析（先复制，后下沉）
├── pickdir.odin         # 工作目录选择对话框：Windows IFileDialog（COM STA）；Unix 返回 501
├── assets.odin          # 内置资源表：#load_directory("dist") + 查找/兜底
├── platform_windows.odin / platform_unix.odin
├── process_platform_windows.odin / process_platform_unix.odin  # Job/进程树终止（与 ap 同构）
├── package.json         # deps: esbuild + alpinejs + markdown-exit + github-markdown-css；scripts: build / watch / test
├── build.mjs            # esbuild 脚本：frontend/main.js → dist/（app.js + styles.css），拷贝 index.html
├── index.html           # Alpine 模板宿主（构建时拷入 dist/）
├── frontend/            # 前端源码（无 .odin 文件，不影响 Odin 包）
│   ├── main.js          # 入口：import Alpine 与 styles.css，注册 store 后启动
│   ├── styles.css       # Josh's Custom CSS Reset 开头 + 应用样式
│   ├── api.js           # fetch 封装
│   ├── sse.js           # EventSource 封装：重连、事件分派
│   ├── store.js         # Alpine.reactive store：session 状态、消息列表、工具卡片
│   ├── render.js        # 事件 → 视图模型（复刻 ap-tui 渲染规则）
│   ├── markdown.js      # assistant 文本 → HTML（markdown-exit，html:false）
│   └── app.js           # 输入框、发送/取消、session 切换、目录选择
└── dist/                # esbuild 产物（提交进仓库）：index.html + app.js + styles.css
```

说明：

- Odin 的包规则是「目录内所有 `.odin` 文件同属一个包」；`frontend/`、`dist/`、`node_modules/` 里没有 `.odin` 文件，与包不冲突
- `dist/` **必须提交进仓库**：`#load_directory` 在编译期读取它，仓库里始终要有一份可编译的产物；同时这让 Odin 构建不依赖 Node
- 前端源码放 `frontend/` 子目录，避免 `dist/` 生成物与源码混在一起难以辨认

## 进程模型

```
ap-web（主进程）
├── accept 线程：core:net 阻塞 accept 循环（SO_REUSEADDR）
├── 每连接一个线程（core:thread.spawn，连接关闭即回收）
│     ├── 静态资源请求 → 内置资源表查找 → 返回
│     ├── API 请求 → 解析 → 路由 → JSON 响应
│     └── SSE 请求 → 注册到 hub → 阻塞读 hub channel → 写 chunk
└── turn runner：每个 session 一个运行态（slot key / 真实 id），不同 session 可并发
```

### 为什么每连接一线程而不是事件循环

- 目标规模是同一用户的几个浏览器标签页（每个标签页一个 session）；线程数仍是个位数，`core:thread` 足够
- 阻塞 IO 的代码与 ap-tui 的子进程读取逻辑同构，可以直接照搬 `ap-tui/agent.odin` 的 spawn/pipe 模式（含 Windows 继承标志清理）
- Odin 没有 async/await；写一个 select/epoll 抽象层的复杂度远超收益

### Turn 生命周期

与 ap-tui 一轮完全一致：

1. `POST /api/turn` 校验参数，用 `session_key` 定位该 session 的运行态；同一 session 已有 turn 返回 409，不同 session 可以并发启动
2. spawn `ap --print0 --output-format stream-json [-s <id>] <透传>`，提示词写 stdin 后关写端（Windows 上清理管道句柄继承标志，见 [tui.md](tui.md) 的坑）
3. 逐行读 stdout：`parse_event_line`（复用 ap-tui 的事件结构）→ 逐事件推给 hub → 按该 session 的 key 广播 SSE
4. stderr 缓存；turn 异常退出时随 `turn_done` 的 `stderr_preview` 带给前端
5. 进程退出：把 slot key 别名到 `session_start` 里的真实 session id（新会话第一轮），广播 `turn_done`（含退出码与 stop_reason）
6. 运行中收到 `DELETE /api/turn?session_key=<key>`：只终止该 session 的 ap 进程树（复用 ap 内部的进程树终止语义：Unix 先 SIGTERM、2s 后 SIGKILL；Windows 用 Job Object 整树终止）。Unix 上 ap 收到 SIGTERM 后会自己写 `cancel` / `turn_end(cancelled)` / `session_end(reason=signal)`；Windows 的 Job 终止会连同 ap 一起结束，ap 来不及写收尾事件。两种情况 ap-web 都广播 `turn_done`，主动取消时 `stop_reason` 至少为 `cancelled`

### 取消与并发约束

- **单 session 单飞**：同一 session 同一时刻只允许一个 turn；用同一个 `session_key` 再 `POST /api/turn` 返回 409 `turn_running`
- **按 session 并发**：不同 `session_key` 可以同时跑 turn（多标签页各跑各的）。resume 其他 session 不再因为某个 session 在跑而 409
- **session key**：新会话先由 `POST /api/session/new` 分配 slot key（形如 `web_new_1`），`session_start` 后 registry 把它别名到真实 id；订阅 slot key 或真实 id 都能收到该 session 的事件。恢复已有 session 时 key 通常等于 session id
- **取消只作用于一个 session**：`DELETE /api/turn?session_key=<key>`；不带 key 时退化为当前 session，若当前没跑且只有一个在跑则取消那一个（兼容旧客户端）
- **cwd 是进程级状态**：任意 session 在跑时 `POST /api/cwd/pick` 都返回 409；切换成功后 `runner_reset_sessions` 清空所有 session 运行态
- turn runner 在独立线程执行，SSE 连接挂掉**不**取消 turn（浏览器刷新后通过 `GET /api/history` + 重新订阅恢复画面）
- Windows 上取消是整树强制终止，transcript 可能停在 `tool_execution_start` 等中间事件，没有 `turn_end` / `session_end`；刷新页面仍能重放已经落盘的部分。Unix 上走 SIGTERM 优雅中断，收尾事件齐全
- ap-web 进程退出时终止所有运行中的 ap，并等待至多 5s

## HTTP 层（手写）

只实现 HTTP/1.1 的最小子集，够本 UI 用即可：

- 请求：request line + headers + body（`Content-Length` 必填；空 body 的 POST 也要写 `Content-Length: 0`。**不支持** `Transfer-Encoding: chunked` 请求体；不支持 100-continue）
- 响应：`Content-Length` 定长；SSE 用 chunked（只写不读，实现简单）
- 方法：GET / POST / DELETE；其余返回 405
- 头解析：逐行直到 CRLF CRLF；单行上限 32KB，头部总数上限 100
- keep-alive：默认开启；读下一请求前等完整头部；SSE/出错响应后关闭连接
- URL：只做 percent-decode 与 `?` query 切分；路由匹配纯前缀 + 精确表，不写通配框架

明确不做：管线化、range、If-Modified-Since、gzip、多 part。

### 内置静态资源

- `assets.odin` 用 `#load_directory("dist")` 把整个 `dist/` 编进 exe，得到编译期的 `{name, data}` 表；查找按文件名精确匹配，根路径与目录路径回落到 `index.html`
- MIME 按扩展名查静态表（html/js/css/svg/png/ico/wasm）
- ETag 是文件内容的 FNV-1a hash（内置资源在启动时算一次，磁盘模式每个请求算），命中 `If-None-Match` 返回 304——静态资源没有修改时间概念，内容 hash 是唯一可用的缓存键
- `--web-root <dir>` 开发模式开关：给定时改从磁盘读该目录（前端改样式不用重编 exe）；默认走内置表。两条路径共用同一套查找/MIME/兜底逻辑，磁盘实现只是把「查表」换成「读文件」
- 长度上限：单文件 8MB（esbuild 产物远小于此）；`app.js` 内已含 Alpine，不依赖 CDN

### SSE

- `Content-Type: text/event-stream`，`Cache-Control: no-cache`，`Connection: close`，禁用 Nagle（`TCP_NODELAY`）
- 帧格式：`event: <type>\ndata: <json>\nid: <seq>\n\n`；`id` 单调递增，浏览器 `Last-Event-ID` 重连时从 transcript 补齐缺口（phase 1 可只做「重连即重放全量」）
- 心跳：每 15s 发 `: ping\n\n` 注释行，防代理超时
- 写失败（EPIPE/连接 reset）即丢弃该订阅者，不影响 turn

## HTTP API

约定：请求/响应都是 `application/json; charset=utf-8`；错误用 `{"error": {"code": "...", "message": "..."}}`；status 一律语义化。

| 方法 | 路径 | 请求 | 响应 | 说明 |
| --- | --- | --- | --- | --- |
| GET | `/api/health` | – | `{"ok": true, "version": ...}` | 探活 |
| GET | `/api/config` | – | `{model, agent, max_steps, max_tokens, cwd, platform}` | 从 ap-web 启动参数/env 组装，前端展示；`platform` 决定是否显示目录选择入口 |
| GET | `/api/session/current` | – / `?session_key=<key>` | `{session_key, session_id, running, turn}` | 指定 key 时返回该 session 的运行态；不带参数返回「最近活跃」session（仅作新标签页兜底） |
| POST | `/api/session/new` | – | `{session_id: null, session_key}` | 只分配一个 slot，不落盘；下一条提示词让 ap 新建 session（同 ap-tui `/new`） |
| GET | `/api/sessions` | – | `[{session_id, ts, turns, running}]` | 复用 `internal/sessions.odin` 列表；`running` 表示该 transcript 对应的 session 是否在跑 |
| POST | `/api/session/resume` | `{session_id}` | `{session_id, session_key}` | 切换/注册该 session 的运行态；不因其他 session 在跑而 409，也不校验合法性（交给下一轮 ap 报错） |
| GET | `/api/history?session_id=<id>` | – | `{events: [...]}` | transcript 重放：逐行读 JSONL，`text_ref` / `input_ref` / `args_ref` / `content_ref` 从 blobs 解析（缺失则退化为对应 `*_preview`），超 200 行/20KB 的工具结果截断并标记（对齐 ap-tui 重放规则）；前端渲染初始画面 |
| GET | `/api/cwd` | – | `{cwd}` | 当前工作目录（启动目录；切换后为最后设置的值） |
| POST | `/api/cwd/pick` | – | `200 {cwd}` / `409 {error: cancelled}` / `501` | 弹出系统目录选择对话框（Windows：`IFileDialog` FOS_PICKFOLDERS）；用户确认后返回所选路径、更新 cwd 并清空所有 session 运行态。见「工作目录选择」 |
| POST | `/api/turn` | `{prompt, session_key?, model?, agent?, max_steps?, max_tokens?}` | `202 {accepted: true, session_key}` | 启动一轮；同一 session 运行中 409 `turn_running`，不同 session 可并发；`prompt` 为空 400 |
| DELETE | `/api/turn?session_key=<key>` | – | `202 {"cancelled": bool}` | 取消该 session 的 turn（终止进程树）；不带 key 时退化为当前 session |
| GET | `/api/events?session_key=<key>` | – | SSE 流 | 只订阅该 session 的事件；不带参数订阅全部（兼容/测试）。见下节 |

透传：`POST /api/turn` 可带可选 `model` / `agent` / `max_steps` / `max_tokens`，ap-web 原样转成命令行参数——与 ap-tui 透传规则一致；`session_key` 只用于定位运行态，不传给 ap。

## 工作目录选择

输入框旁有一个「选择目录」入口，点击后：

```
前端 ──POST /api/cwd/pick──► ap-web ──COM──► Windows 目录选择对话框（IFileDialog）
     ◄──── 200 {cwd} ────────  （用户确认）
```

为什么由服务器弹原生对话框，而不是浏览器自己的 `<input type="file" webkitdirectory>`：

- 浏览器出于安全只把 `<input type=file>` 的 `value` 暴露为 `C:\fakepath\`；`showDirectoryPicker()` 也只给句柄不给绝对路径。前端拿不到真实的 Windows 路径，而 ap 的工作目录必须是绝对路径
- 反过来，拿到路径也传不回去：`<input>` 没有赋值 API。所以必须由 ap-web 侧出对话框

实现要点：

1. **Windows**：`IFileDialog`（CLSID `FileOpenDialog`，`FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM`）取 `GetResult → GetPath`。COM 在专用的 STA 线程上初始化（`CoInitializeEx(COINIT_APARTMENTTHREADED)` + `IFileDialog::Show(NULL)` 阻塞到用户关闭）；accept 循环与其他连接不受影响（pick 请求自身会占用它的连接线程，见「实现细节与额外语义」）
2. **Unix**：无统一的原生目录对话框 API，phase 1 直接 `501 not_implemented`，前端隐藏该入口（`GET /api/config` 返回 `platform` 字段区分）；phase 2 可考虑 `zenity`/`kdialog` 探测
3. **取消语义**：用户关掉对话框 → `409 {error: {code: "cancelled"}}`，前端静默忽略
4. **生效范围**：确认后 ap-web 更新自己的 cwd（`os.set_cwd`）并返回给前端回显——输入区「选择目录」按钮旁与侧栏底部都显示当前 cwd；**下一次 turn 的 ap 子进程就在新目录里启动**。运行中的 turn 不受影响（其 cwd 已定）；任意 session 在跑时调用 `POST /api/cwd/pick` 都返回 409 `turn_running`
5. **持久化不做**：cwd 是进程级状态，重启 ap-web 回到启动目录。理由：会话 transcript 本身按 project 隔离（`-s <id>` 跨项目会明确报错），切目录后旧 session 不该再被追加。服务器在 pick 成功后清空所有 session 运行态；前端收到新的 cwd 后也清空当前 session/消息列表，并重新分配一个 slot 提示「已切换工作目录，请开始新 session」
6. **并发**：同一时刻只允许一个 pick 请求；重复调用返回 409 `picker_busy`（一个模态对话框只能有一份）

## SSE 事件流

SSE 事件是 ap stream-json 事件的**直转发**加上一层薄信封。不重新设计事件 schema：

```
event: ap
id: 42
data: {"v":1,"seq":7,"ts":...,"type":"message_update","delta":{"text":"..."}}

event: turn_done
id: 43
data: {"exit_code":0,"stop_reason":"stop","usage":{...},"stderr_preview":"..."}
```

| SSE event | data | 说明 |
| --- | --- | --- |
| `ap` | ap 的 stream-json 事件原样 | 前端按 `type` 分派（`session_start` / `message_update` / `message_end` / `tool_execution_start/update/end` / `turn_start/turn_end` / `error`） |
| `turn_done` | `{exit_code, stop_reason, usage, stderr_preview}` | turn 结束信封；`stop_reason` 取自 `turn_end`/`session_end`，主动取消但没有收尾事件时 ap-web 填 `cancelled`，其他缺失为 null |
| `ping` | `{ts}` | 心跳（也作为 SSE 注释行发送） |

`GET /api/events?session_key=<key>` 只转发该 session 的 `ap` / `turn_done` 帧；订阅者匹配 slot key 或真实 session id 任一即可。心跳（空 topic）仍发给所有订阅者。不带 `session_key` 时保持旧的全量订阅，仅用于兼容与测试。

事件顺序保证：单 session 内 ap-web 按收到顺序广播，天然与 stdout 行序一致；不做 seq 去重（ap 保证单调）。不同 session 的事件可能交错到达不同订阅者，但每个标签页只看到自己的 session。

### 历史与实时的衔接

前端两条路径到同一份事实（transcript）：

- 打开/切 session：`GET /api/session/current?session_key=<key>` 校正运行态，`GET /api/history` 渲染存量，然后 `GET /api/events?session_key=<key>` 订阅该 session 的增量
- 刷新页面：每个标签页从 `sessionStorage` 恢复自己的 `{session_key, session_id}`（优先真实 id，slot key 在 ap-web 重启后无意义）；没有记录时用 `/api/session/current` 兜底，仍为空则 `POST /api/session/new`
- 竞态：订阅成功后若发现 `session_start` 或按 `seq` 比对与已有末尾重复，初始化状态时直接跳过（transcript 事件的 `seq` 单调，前端以此为去重键）
- 刷新页面重连：重新走 history + subscribe；不做断点续传（phase 2 可用 `Last-Event-ID` + transcript seq 补差）

## 前端

- 依赖 `esbuild`（dev）+ `alpinejs`、`markdown-exit`、`github-markdown-css`（runtime）；`EventSource`、`fetch` 全用浏览器原生
- **目标浏览器**：只面向现代浏览器（Chrome/Edge/Firefox/Safari 近两年版本），CSS 可放心用 `interpolate-size`、`:has()`、CSS 嵌套等新特性，不写 polyfill、不做厂商前缀（reset 里保留的 `-webkit-font-smoothing` 除外）
- **样式基线**：`frontend/styles.css` 先 import `github-markdown-css`（供 assistant Markdown 使用），再以 Josh's Custom CSS Reset（joshwcomeau.com/css/custom-css-reset）原样引入，应用样式接在其后；不引入其他 reset/normalize/框架

### 布局约定

| 层级 | 用什么 | 落在哪 |
| --- | --- | --- |
| 页面骨架 | **grid** | `index.html` 的 `body`：`grid-template-columns: 16.5rem minmax(0, 1fr)`（会话侧栏 / 工作区）；工作区内部 `grid-template-rows: auto minmax(0, 1fr) auto`（标题栏 / 滚动消息区 / 输入区），消息区自身可 `overflow-y: auto`；窄屏（≤820px）侧栏折成顶部会话条 |
| 组件内部（块级布局） | **flex** | 消息行、工具卡片头部（状态点+名称+参数+耗时）、侧栏会话项、标题栏按钮组、输入区（textarea + 发送/停止/选目录按钮）一律 flexbox |

规则：grid 只出现在页面级骨架（定义行列区域），其余所有块级排列都是 flex；不用 float、不写绝对定位布局（仅个别 `position: sticky` 类效果允许）。消息区用 `minmax(0, 1fr)` 而不是 `1fr`，避免长内容把 grid 撑开——这是 grid 滚动容器的常见坑。

视觉语言对齐 Codex 桌面版的浅色风格：纯白工作区 + `#f9f9f9` 会话侧栏、单色（黑/灰）强调、1px 发丝边框、系统无衬线 + 等宽数据、圆角输入框与圆形发送按钮。**只提供浅色主题**：`color-scheme: light`，不写 `prefers-color-scheme: dark` 分支；Markdown 样式固定使用 `github-markdown-light.css`，避免跟随系统切到暗色。

- store 状态机与 ap-tui 渲染一一对应：`idle` / `running`；`message_update` 按 delta 累积，`message_end` 只补缺（避免重复，同 ap-tui 规则）
- 工具卡片：`tool_execution_start` 建卡片（名称 + 参数），`tool_execution_update` 增量追加（bash 流式），`tool_execution_end` 标记 ✓/✗、耗时、退出码；结果超限截断提示（完整内容在 transcript）
- 转义：用户输入与工具输出经 `textContent` 写入；仅 assistant 文本走 Markdown（`markdown-exit`，`html:false` 转义原始 HTML，危险协议链接不渲染，外链 `target="_blank" rel="noopener noreferrer"`，图片 `loading="lazy"` + 不发送 referrer），经 `x-html` 注入且只注入渲染器产物
- 多标签页：每个标签页持有自己的 `session_key`，SSE 按该 key 过滤；`sessionStorage` 保存本标签页的 `{key, id}`，刷新后优先按真实 id 恢复。会话列表/新建入口只按 `loading` 禁用，不按 `running`，所以一个标签页在跑时仍可切换或新开其他 session
- 单页应用，无路由库；同一 session 仍在客户端按 `running` 阻止重复发送，服务端再以 409 兜底

## 构建与运行

### 前端（可选，需要 Node）

```sh
npm --prefix ap-web install        # esbuild + alpinejs + markdown-exit + github-markdown-css
npm --prefix ap-web run build      # esbuild → dist/（index.html + app.js + styles.css）
npm --prefix ap-web run watch      # 开发期监听
```

`dist/` 提交进仓库，所以平时改 Odin 代码不需要 Node。

### 全量构建

```sh
./build.sh        # Windows 下 ./build.ps1
# 产物：bin/ap.exe  bin/ap-tui.exe  bin/ap-web.exe
```

构建脚本逻辑：

1. 探测 `npx`：存在则先跑 `npm --prefix ap-web run build` 刷新 dist；不存在则跳过（用仓库里已提交的 dist）
2. `odin build ../ap-web -out:ap-web -vet`（与 ap、ap-tui 并列）

注意：`#load_directory("dist")` 在**编译期**读取 `ap-web/dist/`，目录不存在直接编译失败——这就是 dist 必须提交仓库、且前端构建必须先于 Odin 构建的原因。

### 运行

```sh
./bin/ap-web                       # http://127.0.0.1:8417
./bin/ap-web --web-root ap-web/dist   # 开发模式：静态资源走磁盘，前端改动刷新即生效
./bin/ap-web -c                    # 启动即定位当前项目最近的 session
./bin/ap-web -s ses_...
```

## CLI

```
ap-web [--port 8417] [--host 127.0.0.1] [--web-root <dir>]
       [--agent-bin <path>] [-s <id>] [-c] [--model ...] [--agent ...]
       [--max-steps ...] [--max-tokens ...] [--config-dir <dir>] [--cwd <dir>]
```

- `--agent-bin` / `AP_AGENT_BIN` / 同目录 / PATH：可执行文件查找顺序与 ap-tui 相同
- `-s` / `-c`：启动时定位初始 session（复用 internal/sessions）
- `--cwd <dir>`：初始工作目录，默认进程启动目录；运行期可通过 Web UI 的目录选择修改（进程级，不持久化）
- `--port` 默认 8417；`--host` 默认 `127.0.0.1`，写死本机回环为默认值是刻意的安全默认

## 依赖方向与代码复用

对齐 [architecture.md](architecture.md)：

```
ap-web ──► internal ──► (core only)
ap-web 不 import ap、不 import ap-tui
```

事件解析、spawn/pipe、project hash 三块与 ap-tui 重复度高。方案：**先复制，后下沉**——phase 1 直接把 `ap-tui/agent.odin`、`events.odin`、`project.odin` 拷进 ap-web 起步（同一仓库，无碍）；跑通后把无 UI 依赖的部分（事件解析、spawn 封装）下沉到 `internal/`，ap-tui 与 ap-web 共同引用。避免第一版就做跨三个包的大重构。

## 安全

1. 默认只监听 `127.0.0.1`；显式 `--host 0.0.0.0` 时启动日志打印醒目警告（agent 可执行任意 bash）
2. 无鉴权是接受的设计：本工具与 `ap` CLI 本身同权限运行，攻击面等价于「能访问端口就能用 shell」——因此默认回环 + 不做 CORS 放开（同源部署，`Origin` 校验 phase 2 有需要再加）
3. 静态资源来自编译期内置表或 `--web-root` 白名单目录；磁盘模式下路径解析后必须落在 web-root 内，否则 403（内置表模式无路径可言，不存在穿越）
4. `POST /api/turn` 的 prompt 长度上限 1MB（超限 413）；ap 已把超过 blob 阈值的内容写成 blob，SSE 只转发带 `*_ref` 的事件，前端经 history 接口解析
5. 转发到 ap 的命令行参数全部来自服务端白名单映射，不拼接 shell

## 风险与对策

| 风险 | 对策 |
| --- | --- |
| 手写 HTTP 的边界 case（慢速攻击、畸形请求） | 只回环监听 + 头部/行上限 + 超时即断连；不追求公网健壮性 |
| `core:thread` 与 Odin runtime 交互（heap/allocator） | 每连接线程用独立 arena，请求结束释放；hub 用 `sync.Mutex` + 动态数组，不依赖复杂并发原语 |
| Windows 管道继承（ap-tui 已踩过的坑） | 直接复用 ap-tui 的 `mark_non_inheritable` 模式 |
| COM 对话框与 Odin 的交互（COM 头文件/绑定需手写、STA 要求） | `IFileDialog` 只用 5 个 vtable 方法（`SetOptions` / `Show` / `GetResult` / `GetPath` + `Release`），手写最小 COM 绑定放 `pickdir.odin`；专用 STA 线程隔离，失败时返回 500 并提示手输路径 |
| 模态对话框阻塞期间用户关掉浏览器 | pick 请求结果作废即可，无状态残留；对话框由用户自行关闭 |
| nightly stdlib 变动（`core:net` API 漂移） | 构建脚本已 pin 版本；socket 用法集中在一个文件 |
| `#load_directory` 要求 dist 在编译期存在 | dist 提交仓库 + 构建脚本先跑 esbuild（有 npx 时）；CI 无 Node 也能用提交的 dist 编译 |
| 内置资源让 exe 变大 | dist 三个文件合计 < 100KB（Alpine ~15KB gzip），可忽略 |
| SSE 被浏览器/代理缓冲 | `text/event-stream` + 立即 flush + 心跳；本地直连无中间代理，风险低 |
| 事件解析三处漂移（ap/ap-tui/ap-web） | phase 1 先复制起步，phase 2 下沉 `internal/` 后只剩一处 |

## 实现细节与额外语义

本节记录实现相对上面接口表的补充约定，以及几处刻意保留的取舍。

### 连接超时与错误体

- 连接线程读完一个请求后复用连接等待下一个请求，空闲上限 30s；开始读取某个请求后改用 10s（`SO_RCVTIMEO`，`platform_*.odin` 的 `socket_set_read_timeout`）。读超时即关闭连接，不写错误响应——慢速客户端不能长期占住连接线程
- 解析层的 4xx（含请求体超过 2MB 的 413）对 `/api/*` 目标同样返回 `{"error":{"code","message"}}`；静态资源仍回纯文本，方便直接用浏览器访问。请求体超限的 code 是 `payload_too_large`
- `api_json` 编码失败（服务端 bug）固定返回 500 `internal_error`，不会把错误体挂在 2xx 上

### 目录选择与连接线程

`POST /api/cwd/pick` 的请求会一直占用它自己的连接线程，直到用户关闭对话框：处理函数必须同步取回选择结果才能更新 cwd 并返回 200/409/501。对话框本身在独立 STA 线程上跑（`CoInitializeEx` + `IFileDialog::Show`），因此 accept 循环和其他连接不受影响；这也是 `picker_busy` 只挡第二个 pick、不挡其他请求的原因。

### SSE 订阅者按「已死」处理

订阅者 channel 满了（`SSE_SUBSCRIBER_BUFFER`，默认 256 帧）说明对应连接线程已经不再消费。实现丢弃该订阅者并关闭它的 channel，连接随后收尾关闭；这比反压 agent 更安全（SSE 写失败本来也只丢弃订阅者）。前端在 EventSource 重连后重新走 `GET /api/history` + 订阅，用 transcript 的 `seq` 去重补齐，不依赖服务端重放。

### 接口表的额外语义

| 端点 | 额外行为 | 理由 |
| --- | --- | --- |
| `POST /api/session/resume` | 不因其他 session 在跑而返回 409；只有 `POST /api/turn` 按 session 判忙 | 不同标签页可以各自查看/运行不同 session；单 session 的单飞由 turn 入口保证 |
| `GET /api/session/current` | 不带 `session_key` 时返回「最近活跃」session，仅作新标签页兜底 | 多标签页下不存在唯一的「当前 session」指针 |
| `DELETE /api/turn` | 202 `{"cancelled": bool}` | 前端需要区分「确实取消了」与「本来就没在跑」 |
| `POST /api/turn` | `max_steps` / `max_tokens` 非正数返回 400 `invalid_request` | 非正数对 ap 没有意义，在边界提前拒绝 |
| 任意 | 关停中（收到 SIGINT/SIGTERM 后）启动新 turn 返回 503 `shutting_down` | 进程即将退出，接受请求必然失败 |

### 平台差异

- Windows 监听使用 `SO_EXCLUSIVEADDRUSE`（而不是 `SO_REUSEADDR`），避免端口被其他进程抢占；Unix 侧仍用 `SO_REUSEADDR`，让崩溃后可以立刻重启
- 信号处理器只置原子标志，收尾（停心跳、终止 turn、清理作业表）由 shutdown watcher 线程执行；Unix 信号处理器因此保持 async-signal-safe

## 测试

1. `odin test ap-web`：HTTP 解析（request line/headers/body 上限、keep-alive）、SSE 帧编码、事件泵、路由、内置资源查找、按 session 的 SSE 过滤与并发隔离
2. `npm --prefix ap-web test`：前端事件归约（delta 累积、工具卡片、history 重放、seq 去重、turn_done 状态机）与 session_key 请求构造
3. 集成（真 spawn 假 agent）：一轮完整 turn 的 SSE 事件序列、同 session 409 单飞、不同 session 并发、按 session 取消与进程树终止、异常退出 stderr 呈现
4. 手动矩阵：Chrome/Edge/Firefox `EventSource` 行为；两个标签页各跑一个 session；Windows/Linux 双平台管道与进程树终止

## Phase 2 待做

1. `Last-Event-ID` 断点续传（transcript seq 补差）
2. diff 渲染、reasoning 展示开关、usage 状态条
3. session fork / 删除；文件附件上传
4. 事件解析与 spawn 层下沉 `internal/`，三消费者共用一份
5. 远程访问模式：`--host` 放开 + token 鉴权 + HTTPS 由外部代理
