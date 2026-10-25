# 03: SSE hub 与帧编码

**What to build:** `sse.odin` 提供两块能力并全部有测试：(a) SSE 帧编码器——`event: <type>\ndata: <json>\nid: <seq>\n\n` 格式、单调递增 id、`turn_done` 信封（exit_code/stop_reason/usage/stderr_preview）、`: ping` 心跳注释行；(b) hub——订阅表（互斥锁 + 动态数组），订阅者用带缓冲 channel，广播非阻塞（满则丢弃该订阅者），写失败即退订。每个 SSE 连接注册到 hub 后阻塞读 channel 写 chunk；心跳定时（15s）由 hub 侧统一发。不接真实连接也可以测：帧编码输出到 builder 做逐字节断言，hub 用假 channel 测广播/退订语义。

参考：docs/web.md「SSE」节；笔记 style-notes.md 里「render-to-file 测试技巧改造为 SSE 帧断言」。

**Blocked by:** None (can start immediately)

**Status:** done
