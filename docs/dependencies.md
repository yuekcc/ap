# 包依赖与边界检查

Odin 没有 Go 的 `internal` 包机制：同仓库的相对 import 永远可达，`@(private)` / `#+private` 只限制声明可见性，不限制 import。因此边界靠目录结构 + 构建期脚本约束。

## 包布局

| 路径 | package | 职责 |
| --- | --- | --- |
| `cmd/ap/` | `main` | 入口：`os.exit(ap.run(os.args))` |
| `ap/` | `ap` | CLI adapter：参数、配置入口、输出格式、退出码、信号 |
| `ap/protocol/` | `protocol` | 事件 schema、宽松解析、`Line_Reader`、usage 计算 |
| `ap/platform/` | `platform` | 路径、project/session、blob、JSON/文本、平台原语、进程树、取消 token |
| `ap/engine/` | `engine` | agent：errors/config/session/loop/provider/sse/skills/transcript/process/tools |
| `ap/client/` | `client` | 前端 kit：spawn、逐行泵、取消、只读 session/blob、历史展示辅助 |
| `ap-tui/` | `tui` | 终端前端 |
| `ap-web/` | `main` | HTTP/SSE 前端 |

同目录 = 同包。`ap/*.odin` 只有 CLI adapter；`odin build cmd/ap` 只链接它 import 到的子包。

## 允许的边

| 源 | 允许 | 禁止 |
| --- | --- | --- |
| `ap-web` / `ap-tui` | `ap/client`、`ap/protocol`、core/vendor | `ap/engine`、`ap/platform`、`ap` 根包、彼此 |
| `ap/client` | `ap/platform`、`ap/protocol`、core/vendor | `ap/engine`、`ap` 根包 |
| `ap` | `ap/engine`、`ap/platform`、`ap/protocol`、core/vendor | `ap-web`、`ap-tui` |
| `ap/engine` | `ap/platform`、`ap/protocol`、core/vendor | `ap`、`ap/client`、`ap-web`、`ap-tui` |
| `ap/platform` | core/vendor | 所有本地包 |
| `ap/protocol` | core | 所有本地包 |

`ap` 根包不得定义 `main`，否则前端 import 它时会把入口链进来。

## 检查器

`tools/check-deps.ps1` / `tools/check-deps.sh`：

1. **import 扫描**：逐行检查上表的源目录，只允许白名单路径。
2. **编译文件清单**：对 `ap-web` / `ap-tui` 各跑一次
   ```
   odin build <dir> -out:<tmp> -export-dependencies:json -export-dependencies-file:<tmp>/deps.json
   ```
   断言 `source_files` 里没有 `ap/engine/`。这证明 agent 代码没有进入前端二进制。
3. **反向用例**：`tools/check-deps.ps1 -SelfTest` / `tools/check-deps.sh --self-test` 会临时在 `ap-web` 加一条 `import "../ap/engine"`，确认检查器返回失败。

接入方式：`test.ps1` / `test.sh` 末尾调用；`build.ps1` / `build.sh` 在编译前调用。CI 可以只跑检查器作为独立 job。
