# ap 用户手册

ap 是一个命令行 coding agent。你给它一条任务，它会读文件、改文件、运行命令，直到给出结果或停下来。

本手册面向会用终端、但不维护 ap 源码的读者。它只讲怎么用，不讲 ap 的内部实现。维护者文档在 [docs/internal/README.md](internal/README.md)。

## 先读哪几章

- 第一次用：第 1 章到第 4 章。
- 已经能跑，想把活干完：第 5 章到第 8 章。
- 选一个顺手的界面：第 9 章、第 10 章、第 11 章。
- 让它记住项目规矩：第 12 章到第 14 章。
- 担心出事，或者已经出错：第 15 章到第 17 章。
- 查参数和文件位置：第 18 章到第 20 章。

## 目录

### 起步

- [1. ap 是什么](01-what-is-ap.md)
- [2. 安装 ap](02-install.md)
- [3. 连接模型](03-connect-model.md)
- [4. 第一次对话](04-first-run.md)

### 日常任务

- [5. 写一条清楚的任务](05-writing-tasks.md)
- [6. 看懂执行过程](06-understand-runs.md)
- [7. 会话管理](07-sessions.md)
- [8. 控制时间与花费](08-context-and-cost.md)

### 三种使用方式

- [9. 命令行一次性使用](09-cli.md)
- [10. 终端界面 ap-tui](10-tui.md)
- [11. 浏览器界面 ap-web](11-web.md)

### 定制

- [12. 让 ap 记住项目规矩](12-memory.md)
- [13. 用技能复用流程](13-skills.md)
- [14. 定义专用代理](14-agents.md)

### 安全与维护

- [15. 全自动执行意味着什么](15-safety.md)
- [16. 数据存在哪](16-data.md)
- [17. 出错了怎么办](17-troubleshooting.md)

### 参考

- [18. 命令与参数速查](18-cli-reference.md)
- [19. 配置项速查](19-config-reference.md)
- [20. 文件布局与术语](20-files-and-terms.md)
- [附录 A：五个工具速查](appendix-a-tools.md)
- [附录 B：MAGI 决策怎么用](appendix-b-magi.md)

## 命令约定

- 示例里的 `./build/ap` 指 `./build.sh` 的产物。在 ap 仓库根目录运行时直接用它；处理其他项目时，用绝对路径调用，或把构建目录加入 `PATH`。Windows 写 `.exe`。
- `~` 会展开为主目录。相对路径相对你启动 ap 的目录。
- 示例里的 `ses_...` 是占位符，换成你自己的 session id。
- 带值的长参数可以写 `--flag value`，也可以写 `--flag=value`。短参数 `-s` 和 `-p` 只接受分开的值。

## 开始之前先知道三件事

1. **ap 是全自动的。** 没有审批弹窗、权限规则或沙箱。它可以改文件、删文件、运行任意命令。读 [第 15 章](15-safety.md)。
2. **stdout 是答案，stderr 是过程。** 解析输出时不要把两者混在一起。
3. **会话只追加，不会自动整理。** 用 `-s` 或 `-c` 恢复。读 [第 7 章](07-sessions.md)。
