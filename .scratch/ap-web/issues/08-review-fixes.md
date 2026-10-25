# 08: code review 修复

**What to build:** 落实 ap-web 集成分支 review（Standards + Spec 两轴）提出的全部问题：连接读超时、解析层 413 的 JSON 错误体、JSON 编码失败状态码、turn 线程回收、分配器所有权、取消竞态、Windows 作业表锁、Unix 信号处理器 async-signal-safe、死代码与过时注释、错误处理惯用法、格式、history 的 `input_ref`/`content_ref`、目录选择入口位置、切目录后前端 session 重置，以及 docs/web.md 的额外语义说明。每项修复都要有能捕获回归的 Odin 或 node:test 测试。

参考：review-fixes 笔记（A–E 节）；docs/web.md；全局 AGENTS.md。

**Blocked by:** 01–07

**Status:** done
