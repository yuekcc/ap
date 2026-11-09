# ap-web：HTTP/SSE 前端

`ap-web` 把 `ap` 暴露给浏览器。它不实现 agent、provider、工具或 transcript 写入。每个用户 turn 启动一个新的 `ap` 子进程，通过 `stream-json` 读取事件，再经 HTTP API 和 SSE 转发给前端。通用的进程契约和 turn 生命周期见 [integration.md](integration.md)，事件 schema 见 [react-loop-and-session.md](react-loop-and-session.md)。

```text
浏览器 ──fetch──► ap-web ──spawn──► ap --print0 --output-format stream-json [-s <id>]
                     │                        │
                     │◄── HTTP API ───────────┤
                     │◄── SSE: 转发的事件 ────┤  stdout: 事件
                     │                        │  stderr: 日志（缓存）
                     ▼
               Web UI（Alpine.js SPA，内置于 exe）
```

一个 `ap-web/` 目录承载 Odin 服务器、前端源码和前端构建配置。产物是单个 `ap-web.exe`。Web 资源在编译期读入 exe，不需要随 exe 分发文件。

## 进程模型

`ap-web` 主进程有以下几类线程：

| 线程 | 职责 |
| --- | --- |
| accept 线程 | `core:net` 阻塞 accept，建立连接后交给连接线程 |
| 连接线程 | 每个连接一个，处理 HTTP 请求、静态资源、API 或 SSE |
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
- 连接空闲等待上限 30 秒。开始读取某个请求后改为 10 秒。读超时直接关闭连接，不写错误响应。
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

## HTTP API

请求和响应都是 JSON。错误统一为 `{"error": {"code": "...", "message": "..."}}`。

| 方法 | 路径 | 请求 | 响应 | 说明 |
| --- | --- | --- | --- | --- |
| GET | `/api/health` | – | `{ok, version}` | 探活 |
| GET | `/api/config` | – | `{model, agent, max_steps, max_tokens, cwd, platform}` | 启动参数快照。`cwd` 是默认目录。`platform` 取值 `windows`、`linux`、`darwin` 或 `unix` |
| GET | `/api/session/current` | `?session_key=<key>` 可选 | `{session_key, session_id, cwd, running, turn}` | 带 key 返回该 session 的运行态。不带 key 返回最近活跃 session，仅作新标签页兜底 |
| POST | `/api/session/new` | `{cwd?}` | `{session_id: null, session_key, cwd}` | 分配 slot，不落盘。`cwd` 决定 slot 所属 project |
| GET | `/api/sessions` | `?cwd=<dir>` 可选 | `[{session_id, ts, turns, running}]` | 该 project 的 session 列表，按文件 mtime 倒序。`turns` 数 `turn_start` |
| GET | `/api/projects` | – | `[{cwd, hash, latest_ts, sessions}]` | 枚举 `path.txt` 发现 project，按最近活动倒序。默认 project 有 session 时也会补进结果 |
| POST | `/api/session/resume` | `{session_id, cwd?}` | `{session_id, session_key, cwd}` | 注册或切换运行态，不校验 transcript |
| GET | `/api/history` | `?session_id=<id>&cwd=<dir>` | `{events: [...]}` | 重放 transcript，解析 blob 引用并截断工具结果 |
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

`GET /api/history` 逐行读 JSONL，并做以下增强：

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

- phase 1 没有统一的原生目录对话框 API，返回 501 `not_implemented`。前端隐藏入口。

目录选择遵循下面的语义。

- 用户关闭对话框返回 409 `cancelled`。前端静默忽略。
- 同一时刻只允许一个 pick 请求。重复调用返回 409 `picker_busy`。
- 成功只返回规范化后的绝对路径。服务器不修改进程级 `cwd`，也不清空其他 session。
- 前端随后调用 `POST /api/session/new {cwd}`，在该目录开新 slot。
- `cwd` 属于每个 `Session_Runtime`。不同 project 的 turn 可以同时运行。
- `ap-web` 重启后默认 project 回到启动目录。侧栏仍可通过 `/api/projects` 打开其他目录的历史 session。
- 前端把本标签页的 `{key, id, cwd}` 存到 `sessionStorage`。刷新时优先按真实 id 加 cwd 恢复。

## 前端

前端依赖下面这些包。

- `alpinejs`、`markdown-exit`、`github-markdown-css`。
- 构建期依赖 `esbuild`。
- `EventSource` 和 `fetch` 使用浏览器原生实现。
- `build.mjs` 的目标是 Chrome 110、Edge 110、Firefox 110、Safari 16。不写 polyfill 和厂商前缀。
- `dist/` 的产物是 `index.html`、`app.js`、`styles.css`。

样式遵循下面的基线。

- 先引入 `github-markdown-css`，再用 Josh's Custom CSS Reset，应用样式接在后面。
- 只提供浅色主题。`color-scheme: light`，不写暗色分支。
- 视觉风格是 iOS 18 的扁平分组列表：`body` 用系统分组背景 `--bg-grouped`，卡片、标题栏和输入区是纯白 `--bg`，用 hairline `--separator` 分隔，不用背景模糊、投影和渐变。
- 系统色与形状收敛成 `--bg-grouped`、`--fill`、`--separator`、`--accent`、`--radius-*` 等自定义属性。改主题只改这些变量，不在选择器里散写颜色。
- 强调色用 systemBlue `#007aff`；用户消息是纯色填充的 iMessage 气泡（18px 圆角，右下角 4px），助手文本保持正文色。
- 交互只保留 120ms 的背景色淡入和聚焦色淡入；运行中脉冲与减少动态偏好下的禁用沿用原语义。
- 页面骨架用 grid。工作区是 `grid-template-rows: auto minmax(0, 1fr) auto`，消息区自己滚动。
- 块级组件用 flex。窄屏（`max-width: 820px`）把侧栏折成顶部列表条，会话项改成胶囊；窄屏输入框字号不小于 16px，避免 iOS 聚焦时自动放大。

前端行为与 `ap-tui` 对齐。

- store 状态机与 `ap-tui` 对齐。`message_update` 按 delta 累积。`message_end` 只在没有 delta 时补全文。
- `tool_execution_start` 建卡片。`tool_execution_update` 增量追加。`tool_execution_end` 标记状态、耗时和退出码。非流式结果超过 200 行或 20000 字节时截断。
- 用户输入和工具输出用 `textContent` 写入。只有 assistant 文本走 Markdown。
- Markdown 用 `markdown-exit`，设置 `html: false`、`linkify: true`、`breaks: true`。原始 HTML 被转义，`javascript:` 和 `data:` 链接不会变成可点链接。外链带 `target="_blank"` 和 `rel="noopener noreferrer"`。图片设置 `loading="lazy"` 和 `referrerpolicy="no-referrer"`。
- 侧栏按 `/api/projects` 的 `cwd` 分组。当前 project 即使还没有落盘 session，也在本地合成一个空组。
- 每个标签页持有自己的 `session_key`，SSE 按该 key 过滤。
- 打开已有 session 的顺序是 `POST /api/session/resume`、`GET /api/history`、`GET /api/events`。
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

`dist/` 提交进仓库。只改 Odin 代码时不需要 Node。

全量构建执行下面的命令。

```sh
./build.sh
```

构建脚本按下面的顺序执行。

1. 找到 `npx` 时先执行 `npm --prefix ap-web run build` 刷新 `dist/`。找不到时使用仓库里已提交的 `dist/`。
2. 执行 `tools/check-deps.sh`。
3. 依次构建 `cmd/ap`、`cmd/ap-tui`、`cmd/ap-web`、`cmd/magi-cli`，产物在 `build/`。
4. Windows 的产物带 `.exe`。

`#load_directory("dist")` 在编译期读取 `ap-web/dist/`。目录不存在时编译失败。这就是 `dist/` 必须提交、且前端构建要先于 Odin 构建的原因。

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
- 前端：delta 累积、工具卡片、history 重放、`seq` 去重、`turn_done` 状态机、请求构造、Markdown 转义。
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
