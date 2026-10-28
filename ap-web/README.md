# ap-web

`ap-web` 是 [ap](../README.md) 的浏览器客户端：一个用 Odin 手写的 HTTP/SSE 服务器 + 内置 Alpine.js 单页应用。它把 `ap` 的 `stream-json` 事件实时渲染到浏览器，但自身不实现 agent、provider、工具或 transcript 写入——每个用户 turn 都启动一个新的 `ap` 子进程。

```
浏览器 ──fetch/EventSource──► ap-web ──spawn──► ap --print0 --output-format stream-json
                                │                        │
                                │◄── HTTP API ───────────┤
                                │◄── SSE 事件转发 ───────┤
                                ▼                        │
                         内置 Web UI（编译进 exe）        ▼
                                                transcript / blobs
```

最终产物是单个 `ap-web.exe`，Web 资源在编译期内置，运行时不需要 Node，也不需要随 exe 分发前端文件。

## 功能

- 浏览器聊天界面：用户消息、assistant Markdown、工具卡片（参数、流式输出、耗时、退出码）
- SSE 实时转发 ap 事件；15s 心跳，断线自动重连并按 transcript `seq` 补齐
- 侧栏按工作目录分组：每个 project 下列出自己的 session；切换对话时同时切换 cwd 与 transcript
- session 新建 / 恢复；每个标签页独立持有自己的 session，刷新页面后从 transcript 重放历史
- 多 session 并发：不同 project、不同标签页可以同时跑 turn；同一 session 仍单飞，重复提交返回 409 `turn_running`
- 单轮取消按 session 生效；SSE 按 `session_key` 过滤，只收到本标签页的事件
- 工作目录选择：Windows 调用原生 `IFileDialog`，确认后在该目录打开一个新 session；不再中断其他目录的运行中 turn
- 默认只监听 `127.0.0.1`；非回环监听会打印安全警告
- 前端 `dist/` 已提交，只改 Odin 代码时无需安装 Node

## 快速开始

### 依赖

- Odin nightly（开发使用 `dev-2026-09-nightly:a2fb372`）
- 一个可执行的 `ap`（`--agent-bin`、`AP_AGENT_BIN`、`AP_BIN`、同目录 `ap`/`ag`、`PATH` 依次查找）
- Windows 需要 Git for Windows 提供的 `bash.exe`（ap 本身的要求）
- 仅修改前端时需要 Node + npm

### 构建

在仓库根目录执行：

```sh
# Linux / macOS，产物：bin/ap、bin/ap-web
./build.sh
```

```powershell
# Windows，产物：bin\ap.exe、bin\ap-web.exe
.\build.ps1
```

只构建 ap-web（入口 `cmd/ap-web`）：

```sh
mkdir -p bin
odin build cmd/ap-web -out:bin/ap-web -vet
```

`build.sh` / `build.ps1` 检测到 `npx` 时会先刷新 `ap-web/dist`，否则直接使用仓库里已提交的产物。`#load_directory("dist")` 在**编译期**读取 `ap-web/dist/`，所以该目录必须存在。

### 运行

```sh
./bin/ap-web                         # http://127.0.0.1:8417
./bin/ap-web --port 9000
./bin/ap-web -c                      # 定位当前项目最近的根 session
./bin/ap-web -s ses_20261022_120000_abcdef123456
./bin/ap-web --cwd /path/to/project
```

打开浏览器访问 `http://127.0.0.1:8417`。ap 的配置（`model`、`base_url`、`api_key` 等）仍由 `ap` 自己读取，默认是 `~/.ap/settings.json`，可用 `--config-dir` 或 `AP_CONFIG` 覆盖。

## CLI

```
ap-web [options]

服务:
  --port <n>                监听端口（默认 8417）
  --host <addr>             监听地址（默认 127.0.0.1）
  --web-root <dir>          开发模式：静态资源从磁盘读取，默认用内置 dist/

Agent:
  --agent-bin <path>        每轮 turn 使用的 ap 可执行文件
  --config-dir <dir>        传给 ap 的配置目录，默认 ~/.ap
  --model <id>              传给 ap 的 --model
  --agent <name>            传给 ap 的 --agent
  --max-steps <n>           传给 ap 的 --max-steps
  --max-tokens <n>          传给 ap 的 --max-tokens
  --cwd <dir>               初始工作目录，默认进程启动目录

Session:
  -c, --continue            继续当前项目最近一次根 session
  -s, --session <id>        恢复指定 session

其他:
  -h, --help                显示帮助
  --version                 显示版本
```

`--model`、`--agent`、`--max-steps`、`--max-tokens` 是默认值；`POST /api/turn` 请求体里的同名字段可以覆盖它们。

## HTTP API

请求/响应均为 `application/json; charset=utf-8`。错误统一为：

```json
{"error": {"code": "turn_running", "message": "a turn is already running"}}
```

| 方法 | 路径 | 请求 | 响应 | 说明 |
| --- | --- | --- | --- | --- |
| GET | `/api/health` | – | `{ok, version}` | 探活 |
| GET | `/api/config` | – | `{model, agent, max_steps, max_tokens, cwd, platform}` | 前端展示用 |
| GET | `/api/session/current` | – / `?session_key=<key>` | `{session_key, session_id, cwd, running, turn}` | 指定 session 的运行态；不带参数时返回最近活跃 session |
| POST | `/api/session/new` | `{cwd?}` | `{session_id: null, session_key, cwd}` | 只分配 slot；`cwd` 决定 slot 所属 project（缺省用默认目录） |
| GET | `/api/sessions` | – / `?cwd=<dir>` | `[{session_id, ts, turns, running}]` | 指定工作目录的 session 列表；不带 `cwd` 时用默认 project |
| GET | `/api/projects` | – | `[{cwd, hash, latest_ts, sessions}]` | 侧栏分组：所有有 session 的 project 及其会话，按最近活动排序 |
| POST | `/api/session/resume` | `{session_id, cwd?}` | `{session_id, session_key, cwd}` | 注册/切换该 session；不因其他 session 在跑而 409 |
| GET | `/api/history?session_id=<id>&cwd=<dir>` | – | `{events: [...]}` | 从该 project 的 transcript 重放历史，解析 blob 引用 |
| GET | `/api/cwd` | – | `{cwd}` | 默认工作目录（启动目录 / `--cwd`），不随会话切换变化 |
| POST | `/api/cwd/pick` | – | `{cwd}` | 弹出目录选择框；取消 409，Unix 501；只返回路径，不改变任何运行态 |
| POST | `/api/turn` | `{prompt, session_key?, cwd?, model?, agent?, max_steps?, max_tokens?}` | `202 {accepted: true, session_key}` | 启动一轮；同一 session 运行中 409，不同 session/project 可并发 |
| DELETE | `/api/turn?session_key=<key>` | – | `202 {cancelled}` | 取消该 session 的 turn（终止进程树） |
| GET | `/api/events?session_key=<key>` | – | SSE 流 | 只订阅该 session；不带参数订阅全部 |

其他常见状态码：prompt 为空 400、prompt 超过 1MB 413、同一 session 已有 turn 409、`cwd` 不存在 400 `invalid_cwd`、关停中启动 turn 503、方法不匹配 405、未知端点 404。

### SSE

`GET /api/events?session_key=<key>` 返回三类事件；订阅者匹配 slot key 或真实 session id 任一即可，不带参数时订阅全部：

| event | data | 说明 |
| --- | --- | --- |
| `ap` | ap 的 `stream-json` 事件原样 | 前端按 `type` 分派 |
| `turn_done` | `{exit_code, stop_reason, usage, stderr_preview}` | turn 结束信封；主动取消且无收尾事件时 `stop_reason` 为 `cancelled` |
| `ping` | `{ts}` | 心跳，同时发送 `: ping` 注释行 |

前端先通过 `/api/history` 渲染存量，再订阅 `/api/events?session_key=<key>`；transcript 事件带单调 `seq`，用于去重。

## 工作目录

启动目录或 `--cwd` 只是**默认**工作目录。每个 session 在创建/恢复时记录自己的 `cwd`，turn 的 `ap` 子进程就在该目录启动；因此不同工作目录的 session 可以同时运行，互不打断。

- 侧栏按 `cwd` 分组；点击组内 session 会切换当前 project，并载入对应 transcript。
- 组标题右侧的 `+` 在该目录新建 session，顶部「新会话」在当前 project 新建。
- Windows 上页面里的「选择目录」调用服务器端原生对话框；确认后前端把该路径作为新 project 打开，并在其中分配一个新 slot。服务器不再修改进程级 cwd，也不会清空其他 session。
- Unix 没有统一的目录对话框，`POST /api/cwd/pick` 返回 501，前端隐藏入口。
- ap-web 重启后回到启动目录；各 project 的 transcript 仍留在 `$AP_CONFIG/projects/<hash>` 下，可通过侧栏继续打开。

## 前端开发

以下命令在仓库根目录执行：

```sh
npm --prefix ap-web install
npm --prefix ap-web run build      # frontend/main.js -> dist/{index.html,app.js,styles.css}
npm --prefix ap-web run watch      # 监听并增量构建
npm --prefix ap-web test           # 前端单元测试
```

开发时可以配合磁盘静态资源，改样式后刷新即可，不需要重编 exe：

```sh
./bin/ap-web --web-root ap-web/dist
```

目录约定：

```
ap-web/
├── main.odin            # run：参数解析、监听、accept 循环（入口在 cmd/ap-web/main.odin）
├── server.odin          # HTTP/1.1 解析、响应、keep-alive
├── api.odin             # 路由与 JSON 编解码
├── sse.odin             # SSE 帧编码、hub、心跳
├── agent.odin           # spawn ap、管道、事件泵
├── runner.odin          # session registry、按 session 分飞、取消、stderr 缓存、turn_done
├── events.odin          # stream-json 事件解析
├── assets.odin          # 内置 dist/ + ETag + 磁盘模式
├── pickdir.odin         # Windows IFileDialog 目录选择
├── index.html           # Alpine 模板
├── frontend/            # 前端源码（api/sse/store/render/markdown/app）
├── dist/                # esbuild 产物，提交进仓库
└── build.mjs            # esbuild 构建脚本
```

前端使用 Alpine.js、原生 `fetch`/`EventSource`、`markdown-exit` 和 `github-markdown-css`，由 esbuild 打包成单个 IIFE；不依赖 CDN。

## 测试

```sh
# 后端（HTTP、SSE、路由、资源、事件泵、取消等）
odin test ap-web -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false

# 前端（delta 累积、工具卡片、history 重放、seq 去重、turn_done）
npm --prefix ap-web test
```

仓库根目录的 `./test.sh` / `.\test.ps1` 会依次测试 `ap-core`、`ap-tui`、`ap-web` 和前端。

## 安全与限制

- 默认只监听回环地址。`--host 0.0.0.0` 等非回环地址会让任何能访问端口的人通过 agent 执行 shell 命令，仅在可信网络使用。
- 没有鉴权、CORS、HTTPS；ap-web 是单用户本地工具，需要远程访问时请放在反向代理和鉴权之后。
- 手写 HTTP 只覆盖 UI 所需子集：无 chunked 请求体、无 gzip、无 range、无 HTTP/2。
- 同一 session 同一时刻只允许一个 turn；不同 session（不同标签页）可以并发，`Last-Event-ID` 断点续传、diff 渲染、session fork/删除等属于后续阶段。
- Windows 取消是整棵进程树强制终止，transcript 可能停在中间事件；Unix 走 SIGTERM，收尾事件更完整。

更详细的设计、协议语义和取舍见 [docs/web.md](../docs/web.md)；ap 本身的构建、配置与使用见仓库根目录的 [README.md](../README.md)。
