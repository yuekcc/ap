# 01: ap-web 骨架：CLI 参数、静态资源内置、最小 HTTP 服务器

**What to build:** `bin/ap-web` 可启动：解析 `--port`（默认 8417）、`--host`（默认 127.0.0.1）、`--web-root <dir>`、`--agent-bin <path>`、`-s <id>`、`-c`、`--model/--max-steps/--max-tokens/--config-dir/--cwd`，在 host:port 上 accept 循环（每连接一个 core:thread 线程），把 `GET /`、`GET /index.html` 交给静态资源层返回 `ap-web/dist/` 内置的占位 index.html。错误的请求行/头部返回 400 并断连；未知方法 405；未知路径 404。浏览器访问 http://127.0.0.1:8417 能看到占位页面。`--host` 显式非回环时启动日志打印警告。测试覆盖 request line/headers/body 上限、keep-alive、405/404。

范围说明（为后续工单铺路）：本工单交付 `main.odin`（入口/accept 循环）、`server.odin`（HTTP/1.1 解析 + keep-alive 状态机 + 响应写出）、`http_util.odin`（MIME、percent-decode、状态行/头部写出）、`assets.odin`（`#load_directory("dist")` 内置资源表 + `--web-root` 磁盘模式 + 路径穿越 403 + ETag/304 + 8MB 上限）、`platform_windows.odin`/`platform_unix.odin`（本工单可先只放 accept 循环需要的平台差异）、`dist/`（占位 index.html，直接提交）。HTTP 请求解析约束按 spec：逐行到 CRLF CRLF，单行 32KB、头部 100 个上限，方法 GET/POST/DELETE，不支持 chunked 请求体，SSE/出错响应后关连接。API 路由表本工单先返回 404。

参考：docs/web.md「HTTP 层（手写）」「内置静态资源」「CLI」三节；笔记 C:\Users\feng\AppData\Local\Temp\opencode\apweb-notes\build-notes.md、style-notes.md、internal-notes.md（args.odin 的参数解析模式可照搬）。

**Blocked by:** None (can start immediately)

**Status:** done
