# 包依赖与边界检查

本文件定义 ap 的包布局、允许的相对 `import` 边，以及 `tools/check-deps.sh` 与 `tools/check-deps.ps1` 的检查规则。模块职责、进程模型和接口契约见 [architecture.md](architecture.md)。

Odin 没有 Go 的 `internal` 机制。同仓库的相对 `import` 永远可达，`@(private)` 与 `#+private` 只限制声明可见性，不限制包之间的引用。边界由目录结构和构建期脚本共同保证。

## 包布局

| 路径 | package | 职责 |
| --- | --- | --- |
| `cmd/ap/` | `main` | 入口，调用 `apcli.run(os.args)` |
| `cmd/ap-tui/` | `main` | 入口，调用 `aptui.run(os.args)` |
| `cmd/ap-web/` | `main` | 入口，调用 `apweb.run(os.args)` |
| `cmd/magi-cli/` | `main` | 入口，调用 `magi.run(os.args)` |
| `ap-cli/` | `apcli` | CLI adapter 与组装根：argv、环境发现、`settings.json`、agent 定义、prompt sections、输出格式、退出码、信号 |
| `ap-cli/tools/` | `aptools` | 五个内置工具、`Tool_Config`、进程树清理、子代理启动 |
| `ap-cli/skills/` | `apskills` | 技能发现、frontmatter 解析、提示词块与 `--list-skills` 简表 |
| `ap-core/` | `apcore` | SDK 门面：`Config`、`Env`、会话生命周期、日志入口 |
| `ap-core/engine/` | `engine` | session、loop、provider、sse、context、transcript、errors、prompts |
| `ap-core/tool/` | `tool` | 工具契约、参数助手、注册表、执行管线、blob 文本读取 |
| `ap-core/platform/` | `platform` | 路径、project/session、blob、JSON 与文本、平台原语、进程树、取消 token、文件日志 |
| `ap-core/protocol/` | `protocol` | 事件 schema 与 wire 常量、宽松解析、`Line_Reader`、usage |
| `ap-core/client/` | `client` | 前端 kit：spawn、逐行泵、取消、只读 project/session/blob、历史展示辅助 |
| `ap-tui/` | `aptui` | 终端前端库：参数、agent 调度、渲染、输入、编辑器、按键、终端控制 |
| `ap-web/` | `apweb` | HTTP 与 SSE 前端库：server、api、sse、runner、assets、pickdir、net |
| `magi/` | `magi` | 三角色投票：参数、输入、提示词、并行 session、聚合、输出、信号 |

同目录即同包。`ap-cli/tools` 与 `ap-cli/skills` 是独立子包，不是 `apcli` 的一部分。`cmd/*` 每个目录只有 `main`，没有业务逻辑。`ap-core/*.odin` 的包名是 `apcore`，它不得定义 `main`，否则导入它的宿主会把入口链进来。

`ap-cli` 是 ap 的组装根。它解析 argv、读取 `settings.json`、定位 bash、解析 agent 文件、发现技能、组装 prompt sections、安装信号、选择输出格式并映射退出码。`magi/settings.odin` 另有一份只读的 `settings.json` 读取器，只取 SDK 设置字段。`apcore` 只接收宿主传入的 `Config`，不读 argv、环境变量或 `settings.json`，不写 stdout，不装信号，不调用 `os.exit`。`ap-tui` 与 `ap-web` 通过 `ap-core/client` 读取 `AP_CONFIG`、`AP_AGENT_BIN` 与 `AP_BIN`。

## 允许的 import 边

检查器逐行扫描下列文件集合。表里没有写出的本地路径一律视为违规。`core:`、`base:`、`vendor:` 是 Odin 的标准库与供应商前缀。

| 扫描的文件 | 允许的 import 路径 |
| --- | --- |
| `ap-web/*.odin`、`ap-tui/*.odin` | `core:`、`base:`、`vendor:`、`../ap-core/client`、`../ap-core/protocol` |
| `ap-core/client/*.odin` | `core:`、`base:`、`vendor:`、`../platform`、`../protocol` |
| `ap-cli/*.odin` | `core:`、`base:`、`vendor:`、`../ap-core`、`../ap-core/platform`、`../ap-core/protocol`、`../ap-core/tool`、`tools`、`skills` |
| `ap-cli/tools/*.odin` | `core:`、`base:`、`vendor:`、`../../ap-core/tool`、`../../ap-core/platform`、`../../ap-core/protocol` |
| `ap-cli/skills/*.odin` | `core:`、`base:`、`vendor:`、`../../ap-core/platform` |
| `magi/*.odin` | `core:`、`base:`、`vendor:`、`../ap-core`、`../ap-core/platform` |
| `ap-core/engine/*.odin` | `core:`、`base:`、`vendor:`、`../platform`、`../protocol`、`../tool` |
| `ap-core/tool/*.odin` | `core:`、`base:`、`vendor:`、`../platform`、`../protocol` |
| `ap-core/platform/*.odin`、`ap-core/protocol/*.odin` | `core:`、`base:`、`vendor:` |
| `ap-core/*.odin` | `core:`、`base:`、`vendor:`、`engine`、`platform`、`protocol`、`tool` |
| `cmd/*/*.odin` | `core:`、`base:`、`vendor:`，加该入口对应的一个库包 |

`cmd/*` 的对应关系是：`cmd/ap` 允许 `../../ap-cli`，`cmd/magi-cli` 允许 `../../magi`，其余入口允许 `../../<目录名>`。

几条关键边由这张表直接推出：

- `ap-cli` 不能 import `ap-core/engine`。宿主只通过 `apcore` 门面使用 agent 机制，SDK 才能被第二个宿主嵌入。
- `ap-core/engine` 不能 import `apcore`、`ap-cli`、`ap-cli/tools` 或 `ap-cli/skills`。engine 不认识应用层。
- `ap-core/tool` 不能 import engine，也不能反向依赖具体工具实现。它只定义契约与执行管线。
- `ap-tui` 与 `ap-web` 不能 import `ap-core/engine`、`ap-core/platform`、`apcore` 根包、`ap-cli` 或彼此。前端只通过进程协议和 `ap-core/client` 工作。
- `magi` 不能 import `ap-core/engine`、`ap-cli`、`ap-core/client` 或前端。它是 `apcore` 的第二个宿主，不与 CLI 共享代码。

不要用 import 别名、条件编译或注释绕过检查器。别名不改变被扫描的路径。需要放宽边界时，先改这份规格与两个检查脚本，再改代码。

## 检查器

### 运行方式

```sh
tools/check-deps.sh
tools/check-deps.sh --self-test
```

```powershell
tools/check-deps.ps1
tools/check-deps.ps1 -SelfTest
```

正常检查通过时输出 `check-deps: ok`，退出码为 0。每发现一条违规就打印文件名与路径，并返回非 0。`build.sh` 在编译四个入口之前调用它，`test.sh` 在全部 Odin 测试之后调用它。`tools/check-deps.ps1` 可以在 PowerShell 中单独运行。仓库没有 `build.ps1` 或 `test.ps1`。

### 正常检查做两件事

第一件是 import 扫描。脚本按上一节的目录集合读取每个 `*.odin` 文件，只检查以 `import` 开头的行，取出引号里的路径，与允许列表比较。`cmd/*` 还要求每个入口只 import 自己对应的库包。扫描不解析 Odin 语法，也不展开别名。

第二件是编译文件清单检查。脚本对 `cmd/ap-web` 与 `cmd/ap-tui` 各跑一次：

```sh
odin build cmd/ap-web -out:<tmp> -export-dependencies:json -export-dependencies-file:<tmp>/ap-web.json
odin build cmd/ap-tui -out:<tmp> -export-dependencies:json -export-dependencies-file:<tmp>/ap-tui.json
```

随后断言导出的依赖清单里不出现 `ap-core/engine/`。POSIX 脚本直接匹配 JSON 文本，PowerShell 脚本检查 `source_files` 字段。这条断言证明 agent 代码没有进入前端二进制。`odin build` 失败也算检查失败。检查只构建这两个前端，不构建 `cmd/ap` 或 `cmd/magi-cli`。

### `--self-test` 验证什么

自检临时写入四个探针文件，每次只写一个，跑完立即删除：

| 探针 | 写入的违规 import |
| --- | --- |
| `ap-web/__check_deps_probe.odin` | `../ap-core/engine` |
| `cmd/ap-web/__check_deps_probe.odin` | `../../ap-core/engine` |
| `ap-cli/__check_deps_probe.odin` | `../ap-core/engine` |
| `ap-core/engine/__check_deps_probe.odin` | `../../ap-cli/tools` |

每个探针都必须让 import 扫描失败。只要有一个探针通过，自检就报失败并以 1 退出。四个都检出后，脚本打印 `check-deps: self-test 通过` 并以 0 退出。

自检只验证 import 扫描能抓到禁止的边。它不验证编译文件清单，也不能替代一次正常的 `tools/check-deps.sh`。自检期间探针文件短暂存在于源码树，正常运行不会写入任何源文件。

## 相关文档

- [architecture.md](architecture.md)：模块职责、依赖方向、进程与内存契约
- [README.md](README.md)：规格入口、术语与文档地图
- [tools.md](tools.md)：五个内置工具的参数与边界
