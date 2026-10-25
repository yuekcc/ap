# 02: 事件解析与 agent 子进程泵（复制自 ap-tui）

**What to build:** ap-web 能像 ap-tui 一样启动并消费 ap 子进程：`events.odin` 提供 `parse_event_line`（与 ap-tui/events.odin 同构，先整文件复制再按 ap-web 命名调整）；`agent.odin` 复刻 ap-tui/agent.odin 的 spawn/pipe/事件泵/退出码逻辑——`resolve_agent_bin`（--agent-bin → AP_AGENT_BIN/AP_BIN → 同目录 ap → PATH）、`build_agent_command`（透传 --model/--agent/--max-steps/--max-tokens/--config-dir、-s）、3 根管道 + Windows `mark_non_inheritable` + stdin 写提示词后关写端、逐行读 stdout 逐事件回调、stderr 64KB 环形缓存、进程退出码归一（130/143 取消）；`project.odin` 复刻（project hash 定位、session 列表、transcript 只读、blob 解析，实际转发 internal/）。`platform_windows.odin`/`platform_unix.odin` 补齐 mark_non_inheritable 与进程树终止（Windows Job Object/taskkill 退化为准；Unix PPid 递归扫描 SIGTERM→2s→SIGKILL，从 ap/process.odin 复制，ap-web 不 import ap）。odin test 覆盖事件解析与命令组装。

这一步不接 HTTP：proc 层面以回调/结构体交付，由工单 04 接线。参考：docs/web.md「进程模型」「Turn 生命周期」；docs/tui.md「调用协议」；笔记 agent-notes.md、events-notes.md、project-notes.md、internal-notes.md。

**Blocked by:** None (can start immediately)

**Status:** done
