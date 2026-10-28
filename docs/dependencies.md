# 包依赖与边界检查

Odin 没有 Go 的 `internal` 包机制：同仓库的相对 import 永远可达，`@(private)` / `#+private` 只限制声明可见性，不限制 import。因此边界靠目录结构 + 构建期脚本约束。

## 包布局

| 路径 | package | 职责 |
| --- | --- | --- |
| `cmd/ap/` | `main` | 入口：`os.exit(apcore.run(os.args))` |
| `cmd/ap-tui/` | `main` | 入口：`os.exit(aptui.run(os.args))` |
| `cmd/ap-web/` | `main` | 入口：`os.exit(apweb.run(os.args))` |
| `ap-core/` | `apcore` | CLI adapter：参数、配置入口、输出格式、退出码、信号 |
| `ap-core/protocol/` | `protocol` | 事件 schema、宽松解析、`Line_Reader`、usage 计算 |
| `ap-core/platform/` | `platform` | 路径、project/session、blob、JSON/文本、平台原语、进程树、取消 token |
| `ap-core/engine/` | `engine` | agent：errors/config/session/loop/provider/sse/skills/transcript/process/tools |
| `ap-core/client/` | `client` | 前端 kit：spawn、逐行泵、取消、只读 session/blob、历史展示辅助 |
| `ap-tui/` | `aptui` | 终端前端库（`run` + 渲染/参数/agent） |
| `ap-web/` | `apweb` | HTTP/SSE 前端库（`run` + server/api/sse/runner/assets） |

同目录 = 同包。`ap-core/*.odin` 只有 CLI adapter；`odin build cmd/ap` 只链接它 import 到的子包。`cmd/*` 只有 `main`，不得承载业务逻辑。

## 允许的边

| 源 | 允许 | 禁止 |
| --- | --- | --- |
| `cmd/ap` | `ap-core` | 其他一切 |
| `cmd/ap-tui` | `ap-tui` | 其他一切 |
| `cmd/ap-web` | `ap-web` | 其他一切 |
| `ap-web` / `ap-tui` | `ap-core/client`、`ap-core/protocol`、`core:`/`vendor:` | `ap-core/engine`、`ap-core/platform`、`apcore` 根包、彼此 |
| `ap-core/client` | `ap-core/platform`、`ap-core/protocol`、`core:`/`vendor:` | `ap-core/engine`、`apcore` 根包 |
| `apcore` | `ap-core/engine`、`ap-core/platform`、`ap-core/protocol`、`core:`/`vendor:` | `ap-web`、`ap-tui` |
| `ap-core/engine` | `ap-core/platform`、`ap-core/protocol`、`core:`/`vendor:` | `apcore`、`ap-core/client`、`ap-web`、`ap-tui` |
| `ap-core/platform` | `core:`/`vendor:` | 所有本地包 |
| `ap-core/protocol` | `core:` | 所有本地包 |

`apcore` 根包不得定义 `main`，否则前端 import 它时会把入口链进来。

## 检查器

`tools/check-deps.ps1` / `tools/check-deps.sh`：

1. **import 扫描**：逐行检查上表的源目录，只允许白名单路径；`cmd/*` 只允许 import 对应的库包。
2. **编译文件清单**：对 `cmd/ap-web` / `cmd/ap-tui` 各跑一次
   ```
   odin build <dir> -out:<tmp> -export-dependencies:json -export-dependencies-file:<tmp>/deps.json
   ```
   断言 `source_files` 里没有 `ap-core/engine/`。这证明 agent 代码没有进入前端二进制。
3. **反向用例**：`tools/check-deps.ps1 -SelfTest` / `tools/check-deps.sh --self-test` 会临时在 `ap-web` 和 `cmd/ap-web` 各加一条禁止 import，确认检查器返回失败。

接入方式：`test.ps1` / `test.sh` 末尾调用；`build.ps1` / `build.sh` 在编译前调用。CI 可以只跑检查器作为独立 job。
