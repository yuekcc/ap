# 04: turn runner 与 HTTP API 全量接线

**What to build:** 浏览器能通过 API 完成一轮对话：`api.odin` 实现路由表 → handler；`runner.odin` 实现 turn runner（独立线程执行，单飞锁：运行中 POST /api/turn 返回 409 turn_running；取消 DELETE /api/turn 终止进程树；从最后一条 session_start 取 session_id 存为当前 session；turn 结束广播 turn_done 含 exit_code/stop_reason/stderr_preview；ap-web 进程退出时终止运行中 turn 并等至多 5s）。API 全表：GET /api/health、GET /api/config（model/agent/max_steps/max_tokens/cwd/platform）、GET/POST /api/session/current|new、GET /api/sessions、POST /api/session/resume、GET /api/history?session_id=（transcript 重放 + *_ref blob 解析 + 200 行/20KB 截断标记，对齐 ap-tui 重放规则）、GET /api/cwd、POST /api/cwd/pick（本工单 Unix 返回 501、Windows 可先返回 501，工单 06 再补 COM 对话框；picker_busy 409 并发约束生效）、POST /api/turn（prompt 空 400、上限 1MB、可选 model/agent/max_steps/max_tokens 透传）、DELETE /api/turn、GET /api/events（注册 hub，SSE 头 + TCP_NODELAY + 心跳）。错误统一 `{"error":{"code","message"}}`。odin test 覆盖路由分派与 JSON 编解码；用 ap 的 test_helpers 模式做集成测试（真 spawn：一轮完整 turn 的 SSE 事件序列、409 单飞、取消语义、异常退出 stderr 呈现）。

参考：docs/web.md「HTTP API」「Turn 生命周期」「取消与并发约束」「SSE 事件流」；笔记 agent-notes.md、events-notes.md、project-notes.md。

**Blocked by:** 01（需要 server.odin/http_util.odin 的请求/响应抽象与路由挂点）、02（事件泵与命令组装）、03（hub 广播）

**Status:** done
