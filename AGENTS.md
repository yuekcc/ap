# AGENTS.md

面向在本仓库工作的 coding agent。开始改动前先读 [README.md](README.md) 和 [docs/README.md](docs/README.md)。`docs/` 是本项目的规格；实现与规格冲突时，先判断哪边是有意变更，再同时修正另一边。只改代码、不改对应文档，视为未完成。

## 项目形态

ap 是用 Odin 写的 coding agent。`ap` 本体是一次性 CLI：一条提示词进，一个 turn 出。`ap-tui` 和 `ap-web` 是独立前端，每轮启动一个 `ap` 子进程，通过 `--output-format stream-json` 交互。任何协议改动都可能同时影响 CLI、子代理、TUI 和 Web 四个消费者。

## 环境

- Odin nightly，开发和验证使用 `dev-2026-10-nightly:84bc3fc`。nightly 的 stdlib 会变，不要依赖更新版本的 API；升级 Odin 后必须重跑完整测试。
- Windows 需要 Git for Windows 提供 `bash.exe`。ap 会跳过 `C:\Windows\System32` 下的 WSL `bash.exe`；`AP_BASH` 可指定绝对路径。
- Linux 和 macOS 需要系统 libcurl 开发包。Windows 使用 Odin 随附的静态 libcurl。
- Node 和 npm 只在修改 `ap-web/frontend/` 时需要。`ap-web/dist/` 是提交进仓库的构建产物。
- 构建入口是 `./build.sh`，测试入口是 `./test.sh`。仓库没有 `build.ps1` 或 `test.ps1`，不要引用不存在的脚本。
- 不要提交 `build/`、`tmp/`、`.ap/`、`node_modules/`、日志、真实 API key 或其他密钥。

## 构建与测试

```sh
./build.sh                 # 刷新前端（有 npx 时）、检查依赖边、编译四个入口
./test.sh                  # 全部 Odin 测试 + tools/check-deps.sh
tools/check-deps.sh        # 只检查包边界
tools/check-deps.sh --self-test   # 验证检查器本身能抓到违规
npm --prefix ap-web test   # 前端单元测试
```

`build.sh` 在检测到 `npx` 时会重建前端。`ap-web/node_modules` 不存在时先跑 `npm --prefix ap-web install`，或直接 `odin build` 使用已提交的 `dist/`。

聚焦单个包时使用与 `test.sh` 相同的参数：

```sh
odin test ap-core/engine -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
odin test ap-cli -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
odin test ap-web -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
odin test magi -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
odin test lineedit -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
```

测试不调用真实 LLM，也不依赖外网。需要 HTTP 或 agent 时使用本地替身，例如 `ap-web/testdata/fake_agent/`。

## 包边界

依赖方向是单向的，违反即设计错误。完整白名单见 [docs/dependencies.md](docs/dependencies.md)。

| 包 | 职责 | 关键禁止 |
| --- | --- | --- |
| `cmd/ap`、`cmd/ap-tui`、`cmd/ap-web`、`cmd/magi-cli` | 只放 `main`，调用对应库的 `run` | 不承载业务逻辑 |
| `ap-cli`（`apcli`） | CLI adapter 与组装根：argv、环境变量、`settings.json`、agent、技能、prompt、输出、退出码、信号 | 不直接 import `ap-core/engine` |
| `ap-cli/tools`（`aptools`） | 五个工具的实现、工具配置、进程树、子代理启动 | 不 import `apcore`、`engine` |
| `ap-cli/skills`（`apskills`） | 技能发现、frontmatter、提示词块 | 不 import `apcore`、`engine`、`aptools` |
| `ap-core`（`apcore`） | SDK 门面，接收显式 `Config` | 不读 argv/env/`settings.json`、不写 stdout、不装信号、不 `os.exit` |
| `ap-core/engine` | loop、provider、context、transcript、session | 不 import `apcore`、`ap-cli`、前端 |
| `ap-core/tool` | 工具契约、注册表、执行管线 | 不 import engine 或具体工具 |
| `ap-core/platform` | 路径、project/session、blob、JSON/文本、进程树、取消 token | 不 import 任何本地包 |
| `ap-core/protocol` | 事件 schema 与 wire 常量、宽松解析、行分帧、usage | 只依赖 `core:` |
| `ap-core/client` | 前端 kit：spawn、逐行泵、取消、只读 session | 不 import engine 或 `apcore` |
| `ap-tui`、`ap-web` | 前端库，提供 `run` | 本地包只允许 `ap-core/client`、`ap-core/protocol`；`ap-tui` 另可用 `lineedit`；不互相 import |
| `magi` | 三角色投票 CLI：参数、输入、提示词、并行 session、一票否决 | 不直接 import `ap-core/engine`、`ap-cli` 或前端；不执行工具 |
| `lineedit` | 独立行编辑器：decoder、editor、layout、render、history、transport | 不 import 任何 ap 本地包；只允许 `core:`/`base:`/`vendor:` |

改 import 后先跑 `tools/check-deps.sh`。不要用别名、条件编译或注释绕过检查器；需要放宽边界时，先改规格和检查器。

## 不可破坏的契约

1. **transcript 只追加。** 完整事件永不改写。恢复时唯一允许的物理改动是截掉崩溃留下的不完整尾行。不要写“修复事件”。
2. **transcript 是唯一事实来源。** 不允许出现只在内存里的对话内容。流式增量只用于实时展示，不参与恢复。
3. **`context_build` 必须是纯函数。** 同一 transcript 和 project 必须得到逐字节相同的 messages。不调用 LLM、不压缩、不写 transcript、不重新扫描记忆或技能。带预算的 `context_build_budgeted` 扩展成「(transcript, budget) 的纯函数」：水位与校准值显式传入，不读环境或时钟。
4. **恢复以冻结值为准。** `session_start` 中的 system prompt、model、provider、agent、cwd、工具集在恢复和 fork 时不再重算。冲突参数只 warning 并忽略。
5. **stdout 是机器通道。** `text`、`json`、`stream-json` 的 stdout 只放结果或事件；日志、进度、工具输出走 stderr。子代理的 stdout 是 `stream-json`，stderr 是人类日志。
6. **取消必须及时。** 设置取消标志、中止 HTTP 请求、终止工具和子代理的进程树。工具要尊重取消并返回 `ok:false`。
7. **工具串行且无状态。** 一个 step 内的多个 tool call 按顺序执行，不共享 cwd、环境变量或 shell 变量。
8. **blob 先写后引用。** blob 必须 fsync 后再追加引用它的事件。blob 缺失时恢复失败，不静默降级。
9. **不做隐藏的安全拦截。** 当前是全自动、无审批、无沙箱。不要顺手加入审批、沙箱或权限规则；这类变更先写规格。
10. **退出码由 CLI adapter 统一映射。** SDK 和工具返回错误值，不调用 `os.exit`；`ap-cli` 与 `magi` 各自映射自己的退出码。

## 改动地图

| 要改什么 | 从哪里开始 | 同步更新 |
| --- | --- | --- |
| CLI 参数 | `ap-cli/options.odin`、`ap-cli/run.odin` | `print_usage`、`options_test.odin`、`docs/cli-and-config.md` |
| `settings.json(c)` | `ap-cli/settings.odin`、`magi/settings.odin` | `settings.example.json`、`docs/cli-and-config.md` |
| 输出格式或 stderr 排版 | `ap-cli/output.odin` | `docs/cli-and-config.md`、输出测试 |
| 基础 system prompt | `ap-core/engine/prompts/system.md` | `docs/context-management.md`、`--print-system-prompt` 行为 |
| 交接提示词 | `ap-core/engine/prompts/handoff.md` | `docs/context-management.md` 的 handoff 章 |
| 上下文预算、省略与 handoff | `ap-core/engine/budget.odin`、`handoff.odin`、`config.odin` | `budget_test.odin`、`docs/context-management.md`、`docs/proposals/context-budget-and-handoff.md` |
| handoff 的参数与新 session | `ap-cli/run.odin`、`options.odin`、`output.odin` | `options_test.odin`、`handoff_test.odin`、`docs/cli-and-config.md` |
| 应用层 prompt sections | `ap-cli/prompt.odin` | `prompt_test.odin`、`docs/context-management.md` |
| agent 定义解析 | `ap-cli/agent.odin` | `docs/subagents.md` |
| 技能发现 | `ap-cli/skills/skills.odin` | `docs/skills.md` |
| 内置工具 | `ap-cli/tools/definitions.odin`、对应的 `tool_*.odin` | `docs/tools.md`、工具测试；新增工具还要先改规格 |
| Loop 或重试 | `ap-core/engine/loop.odin` | `loop_test.odin`、`docs/react-loop-and-session.md`、`docs/errors-and-cancellation.md` |
| Provider 或 SSE | `ap-core/engine/provider.odin`、`sse.odin` | `docs/provider.md`、provider 测试 |
| 事件 schema | `ap-core/protocol/schema.odin`、`parse.odin`、`engine/transcript.odin` | `docs/react-loop-and-session.md`、`docs/integration.md`、TUI/Web 解析与测试；破坏性变更要升 `SCHEMA_VERSION` |
| 恢复或 fork | `ap-core/engine/session.odin`、`transcript.odin` | `docs/react-loop-and-session.md`、崩溃恢复测试 |
| SDK 门面 | `ap-core/sdk.odin` | `sdk_test.odin`、`docs/architecture.md` |
| TUI | `ap-tui/` | `docs/tui.md`、`tui_test.odin` |
| 行编辑器 | `lineedit/` | `lineedit/*_test.odin`、`docs/internal/lineedit.md` |
| Web 后端 | `ap-web/server.odin`、`api.odin`、`sse.odin`、`runner.odin` | `docs/web.md`、对应 `*_test.odin` |
| Web 前端 | `ap-web/frontend/`、`ap-web/index.html` | 重新生成 `ap-web/dist/`，跑 `npm --prefix ap-web test`；不要手改 `dist/`；图标是 `data-icon` 占位，由 `build.mjs` 从 `bootstrap-icons` 内联 |
| MAGI 决策 | `magi/`、`cmd/magi-cli/` | `docs/magi.md`、`docs/README.md`、README 的 MAGI 段落 |
| 包边界 | `tools/check-deps.sh`、`tools/check-deps.ps1` | `docs/dependencies.md`、`docs/architecture.md` |

## 代码约定

- 跟随现有 Odin 风格：缩进用 tab；类型名用 `Title_Case`（如 `Loop_Result`），过程、字段、变量用 `snake_case`，常量用 `SCREAMING_SNAKE_CASE`。
- 相对 import 并保留现有别名，例如 `import apcore "../ap-core"`、`import aptools "tools"`。
- 错误是值：使用 `platform.Error`、`apcore.Error`、`Provider_Error` 等显式错误类型和 `errorf` / `is_ok`。非测试代码不要用 `panic` 表达预期失败，在 CLI 边界映射成退出码。
- 用 `defer` 释放文件、进程和临时资源；按现有代码选择 `context.allocator` 或 `context.temp_allocator`；避免全局可变状态。
- 需要并发时传入 `^platform.Cancel_Token`，并确保取消路径能停下来。
- 注释和文档用中文，标识符用英文。注释解释为什么，不复述代码。
- 不新增第三方库。HTTP/TLS 统一走 `vendor:curl`；不要引入额外的 C 依赖或新的第三方包。
- `cmd/*` 保持一行入口；业务逻辑放进对应库包。

## 测试约定

- 测试文件与被测代码同目录，命名为 `*_test.odin`，使用 `@(test)` 和 `core:testing`。
- 文件和 session 测试使用现有的 `test_temp_dir` / `test_cleanup` 辅助过程，不写死路径，不污染用户目录。
- 每个 bug 修复至少加一个回归测试；用户可见的行为变更要在所属层补测试。
- `ap-web` 的进程、SSE 和并发测试使用 fake agent，在本地端口上跑，不访问外网。
- 前端逻辑测试放 `ap-web/frontend/*.test.mjs`，用 `node --test` 跑。
- 完成前至少跑 `./test.sh`。改过前端再跑 `npm --prefix ap-web test` 和 `npm --prefix ap-web run build`。

## 文档维护

- `docs/README.md` 是规格入口和文档地图。新增文档要登记；修改决策或术语要同步。
- 改包布局或 import 边时，同时更新 `docs/architecture.md` 和 `docs/dependencies.md`。
- 改用户可见的参数、输出、存储布局或平台行为时，更新 `README.md` 和对应分篇。
- 大的设计变更先写 `docs/proposals/`，达成一致后再落到定稿文档和代码。
- 文档中的路径、命令、字段名必须和代码一致；不要写不存在的脚本或目录。

## 提交与评审

- 提交信息用中文 conventional 前缀，例如 `feat(cli):`、`fix(web):`、`refactor(engine):`、`docs(tools):`、`test(loop):`。
- 一个提交只做一件事。重构和行为变更尽量分开，方便审查和回滚。
- 提交前检查 `git status`，确认没有构建产物、临时文件、密钥或无关改动。
- 描述写清改了什么、为什么改、跑了哪些测试、哪些文档已同步。不要粘贴整段会话日志。

## 完成前检查清单

- [ ] `./test.sh` 通过，`tools/check-deps.sh` 没有违规
- [ ] 改过前端：`npm --prefix ap-web test` 通过，`ap-web/dist/` 已重新生成
- [ ] 行为变更已有测试，bug 修复有回归用例
- [ ] `README.md`、`docs/`、`settings.example.json` 中受影响的说明已同步
- [ ] 没有破坏 transcript、stdout、取消和恢复的契约
- [ ] 没有新增未记录的参数、工具、环境变量或依赖
- [ ] 没有提交 `build/`、`tmp/`、`.ap/`、`node_modules/`、日志或密钥
