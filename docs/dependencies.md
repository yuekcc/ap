# 包依赖与边界检查

Odin 没有 Go 的 `internal` 包机制：同仓库的相对 import 永远可达，`@(private)` / `#+private` 只限制声明可见性，不限制 import。因此边界靠目录结构 + 构建期脚本约束。

## 包布局

| 路径 | package | 职责 |
| --- | --- | --- |
| `cmd/ap/` | `main` | 入口：`os.exit(apcli.run(os.args))` |
| `cmd/ap-tui/` | `main` | 入口：`os.exit(aptui.run(os.args))` |
| `cmd/ap-web/` | `main` | 入口：`os.exit(apweb.run(os.args))` |
| `ap-cli/` | `apcli` | CLI adapter 与组装根：参数、加载 `settings.json`、定位 bash、agent 定义解析、system prompt sections、输出格式、退出码、信号 |
| `ap-cli/tools/` | `aptools` | 五个内置工具、`Tool_Config`、进程树清理、子代理启动 |
| `ap-cli/skills/` | `apskills` | 技能发现、frontmatter 解析、提示词块与 `--list-skills` 简表 |
| `ap-core/` | `apcore` | SDK 门面：接收 `config_dir` / `settings` / `tools`，`env_open`、`Session_Request` 组装、会话生命周期 |
| `ap-core/tool/` | `tool` | 工具契约、参数助手、注册表、执行管线、blob 文本读取 |
| `ap-core/protocol/` | `protocol` | 事件 schema、宽松解析、`Line_Reader`、usage 计算 |
| `ap-core/platform/` | `platform` | 路径、project/session、blob、JSON/文本、平台原语、进程树、取消 token |
| `ap-core/engine/` | `engine` | agent 机制：errors/config/session/loop/provider/sse/context/transcript |
| `ap-core/client/` | `client` | 前端 kit：spawn、逐行泵、取消、只读 session/blob、历史展示辅助 |
| `ap-tui/` | `aptui` | 终端前端库（`run` + 渲染/参数/agent） |
| `ap-web/` | `apweb` | HTTP/SSE 前端库（`run` + server/api/sse/runner/assets） |

同目录 = 同包。`ap-cli/*.odin` 是 CLI adapter 与组装根，也是唯一读 `settings.json`、读 `AP_*` 环境变量、定位 bash、解析 agent 文件与组装 prompt sections 的地方；技能扫描在 `ap-cli/skills`，工具实现在 `ap-cli/tools`，它们是独立子包。`ap-core/*.odin` 是 SDK 门面，只接收宿主解析好的 `Config`，不读配置文件、不读环境变量、不写 stdout、不装信号。`odin build cmd/ap` 只链接它 import 到的子包。`cmd/*` 只有 `main`，不得承载业务逻辑。

## 允许的边

| 源 | 允许 | 禁止 |
| --- | --- | --- |
| `cmd/ap` | `ap-cli` | 其他一切 |
| `cmd/ap-tui` | `ap-tui` | 其他一切 |
| `cmd/ap-web` | `ap-web` | 其他一切 |
| `ap-cli` | `apcore`、`ap-core/tool`、`ap-core/platform`、`ap-core/protocol`、`ap-cli/tools`、`ap-cli/skills`、`core:`/`vendor:` | `ap-core/engine`、`ap-core/client`、`ap-web`、`ap-tui` |
| `ap-cli/tools` | `ap-core/tool`、`ap-core/platform`、`ap-core/protocol`、`core:`/`vendor:` | `apcore`、`ap-core/engine`、`ap-cli/skills` |
| `ap-cli/skills` | `ap-core/platform`、`core:`/`vendor:` | `apcore`、`ap-core/engine`、`ap-cli/tools` |
| `ap-web` / `ap-tui` | `ap-core/client`、`ap-core/protocol`、`core:`/`vendor:` | `ap-core/engine`、`ap-core/platform`、`apcore` 根包、`ap-cli`、彼此 |
| `ap-core/client` | `ap-core/platform`、`ap-core/protocol`、`core:`/`vendor:` | `ap-core/engine`、`apcore` 根包 |
| `apcore` | `ap-core/engine`、`ap-core/tool`、`ap-core/platform`、`ap-core/protocol`、`core:`/`vendor:` | `ap-cli`、`ap-web`、`ap-tui`、`ap-core/client` |
| `ap-core/engine` | `ap-core/tool`、`ap-core/platform`、`ap-core/protocol`、`core:`/`vendor:` | `apcore`、`ap-cli`、`ap-cli/tools`、`ap-cli/skills`、`ap-core/client`、`ap-web`、`ap-tui` |
| `ap-core/tool` | `ap-core/platform`、`ap-core/protocol`、`core:`/`vendor:` | 所有其它本地包 |
| `ap-core/platform` | `core:`/`vendor:` | 所有本地包 |
| `ap-core/protocol` | `core:` | 所有本地包 |

`apcore` 根包不得定义 `main`，否则 `apcli` 或前端 import 它时会把入口链进来。`ap-cli` 不得直接 import `ap-core/engine`：engine 只能经 `apcore` 门面访问，这是「core 可被宿主嵌入」的边界保证。`ap-core/tool` 不得 import engine，也不得被 engine 反向依赖到具体工具实现。

## 检查器

`tools/check-deps.ps1` / `tools/check-deps.sh`：

1. **import 扫描**：逐行检查上表的源目录，只允许白名单路径；`cmd/*` 只允许 import 对应的库包；`ap-cli` 只允许 `apcore`、tool、platform、protocol 与自己的 tools/skills 子包，禁止直接 import `engine`。
2. **编译文件清单**：对 `cmd/ap-web` / `cmd/ap-tui` 各跑一次
   ```
   odin build <dir> -out:<tmp> -export-dependencies:json -export-dependencies-file:<tmp>/deps.json
   ```
   断言 `source_files` 里没有 `ap-core/engine/`。这证明 agent 代码没有进入前端二进制。
3. **反向用例**：`tools/check-deps.ps1 -SelfTest` / `tools/check-deps.sh --self-test` 会临时在 `ap-web`、`cmd/ap-web`、`ap-cli` 各加一条禁止 import，并新增 `engine` 反向 import `ap-cli/tools` 的用例，确认检查器返回失败。

接入方式：`test.ps1` / `test.sh` 末尾调用；`build.ps1` / `build.sh` 在编译前调用。CI 可以只跑检查器作为独立 job。
