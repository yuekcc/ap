# ap

ap 是一个用 [Odin](https://odin-lang.org/) 写的命令行 coding agent。给它一条提示词，它进入 ReAct 循环：请求 LLM、执行工具、把结果送回模型，直到任务完成或命中终止条件，然后退出。

ap 本体没有交互界面。`ap-tui`（终端）和 `ap-web`（浏览器）是独立的前端进程，每轮启动一个 `ap` 子进程，读取 `--output-format stream-json` 的事件并渲染。两者和子代理走同一套协议，因此前端不需要理解 agent 内部。

## 设计取舍

- **一次性 CLI 当内核。** 一条提示词进，一个 turn 出。参数、配置、输出格式和退出码保持稳定，脚本、子代理和其他前端都能复用。
- **transcript 是唯一事实来源。** 对话事件只追加到 JSONL；恢复时只读 transcript，不重新执行工具，也不调用模型生成摘要。内存里的消息列表只是投影。
- **全自动执行。** 没有审批弹窗、权限规则或沙箱。可追溯的记录、实时可见的工具输出和信号取消是仅有的止损手段，部署前要清楚这一点。
- **工具保持最小。** 只有读、写、编辑、bash 和子代理五个。grep、glob、ls 一类能力交给 bash，减少工具 schema 和模型的选择成本。
- **SDK 只保留机制。** agent loop、provider、transcript、context 和工具契约在 `ap-core`；具体工具、技能、`AGENTS.md`、agent 定义和 CLI 语义在 `ap-cli`。

## 当前能力

- 一次性 CLI，支持 `text`、`json`、`stream-json` 三种输出
- session 持久化、恢复（`-s` / `-c`）、fork；只追加 JSONL transcript；内容寻址 blob
- OpenAI chat completions 兼容 provider：SSE 流式、tool calls、usage、重试、超时、取消
- 五个工具：`read_file`、`write_file`、`edit_file`、`bash`、`task`
- 独立进程子代理、agent 定义文件、工具白名单和深度限制
- 技能发现与清单注入；全局和项目 `AGENTS.md`；`$AP_CONFIG/SYSTEM.md` 覆盖基础提示词
- 独立的 `ap-tui` 与 `ap-web`
- `magi-cli`：三名角色各自投票、一票否决的决策程序，基于 `apcore` SDK
- Windows、Linux、macOS；shell 统一使用 Bash

## 快速开始

### 前置条件

- **Odin nightly**。开发和验证使用 `dev-2026-10-nightly:84bc3fc`。nightly 的 stdlib 会变，升级 Odin 后重跑 `./test.sh`。
- **bash**。Windows 需要 Git for Windows 提供 `bash.exe`；ap 会跳过 `C:\Windows\System32` 下的 WSL `bash.exe`，也可以用 `AP_BASH` 指定绝对路径。
- **libcurl**。Linux 和 macOS 链接系统 libcurl，需要开发包；Windows 使用 Odin 自带的静态 libcurl，产物是单个 exe。
- **Node 和 npm**。只在修改 `ap-web` 前端或首次安装前端依赖时需要。`ap-web/dist/` 已提交；如果本机有 `npx` 但没装依赖，`build.sh` 会在前端构建处停止。先跑 `npm --prefix ap-web install`，或直接使用下面的 `odin build` 命令。

### 构建

在仓库根目录执行：

```sh
./build.sh
```

脚本会先刷新 `ap-web/dist`（检测到 `npx` 时），运行 `tools/check-deps.sh`，再编译四个入口。产物在 `build/`：

```
build/ap
build/ap-tui
build/ap-web
build/magi-cli
```

Windows 下为对应的 `.exe`，在 Git Bash 中执行同一个脚本。直接调用 Odin 也可以；Windows 的 `-out` 必须带 `.exe` 后缀：

```sh
ext=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ext=".exe" ;; esac

mkdir -p build
odin build cmd/ap -out:build/ap$ext -vet
odin build cmd/ap-tui -out:build/ap-tui$ext -vet
odin build cmd/ap-web -out:build/ap-web$ext -vet
odin build cmd/magi-cli -out:build/magi-cli$ext -vet
```

### 配置

配置文件固定为 `$AP_CONFIG/settings.json`，默认 `~/.ap`，可用 `--config-dir` 或 `AP_CONFIG` 覆盖。最快的做法是复制示例：

```sh
mkdir -p ~/.ap
cp settings.example.json ~/.ap/settings.json
```

然后编辑 `model`、`base_url` 和 `api_key`：

```json
{
  "model": "your-model",
  "base_url": "https://api.openai.com/v1",
  "api_key": "sk-..."
}
```

其余字段见 [settings.example.json](settings.example.json) 和 [docs/cli-and-config.md](docs/cli-and-config.md)。`api_key` 也可以由环境变量 `AP_API_KEY` 提供，优先级更高；`bash` 工具执行命令前会剔除该变量。

### 第一次运行

```sh
./build/ap --print "找出读取配置的代码，给出文件和行号"
```

Windows 用 `.\build\ap.exe`。相对路径相对启动目录，`~/...` 会展开。

## 用法

提示词来源三选一：`-p` / `--print`、`--input-file`、`--print0`。ap 不会隐式读取 stdin。

```sh
# 直接提示词
./build/ap --print "解释 engine/loop.odin 的 turn 状态机"

# 从文件或 stdin
./build/ap --input-file prompt.txt
cat prompt.txt | ./build/ap --print0

# 结构化输出
./build/ap --print "..." --output-format json
./build/ap --print "..." --output-format stream-json
```

继续或恢复 session：

```sh
./build/ap -c --print "继续"
./build/ap -s ses_20261022_120000_abcdef123456 --print "继续"
./build/ap -c --fork-session --print "从历史分叉"
```

指定 agent、模型和上限：

```sh
./build/ap --agent scout --model hy3 --max-steps 30 --print "..."
./build/ap --list-skills
./build/ap --print-system-prompt --no-agents-md --no-skills
```

agent 定义放在 `$AP_CONFIG/agents/<name>.md`。技能放在 `~/.agents/skills/<name>/SKILL.md` 或 `<启动目录>/.agents/skills/<name>/SKILL.md`；ap 只把清单注入 system prompt，正文由模型按需读取。完整参数见 [docs/cli-and-config.md](docs/cli-and-config.md)。

## MAGI 决策

`magi-cli` 把问题和材料交给 BALTHASAR-2（战略）、CASPER-3（伦理）、MELCHIOR-1（科学）三名角色独立投票，任意一名否决即整体否决。成员没有工具，各自一个 session，transcript 可用 `ap -s <session_id>` 审计。

```sh
./build/magi-cli --question '是否包含恶意行为' --context '<材料>'
./build/magi-cli --input-file request.json --output-format text
cat request.json | ./build/magi-cli --print0
```

请求 JSON 为 `{"question": "...", "context": "..."}`；默认输出 `magi.decision.v1` JSON。成员失败按否决处理。完整契约见 [docs/magi.md](docs/magi.md)。

## 前端

`ap-tui`：

```sh
./build/ap-tui          # 新 session
./build/ap-tui -c       # 恢复当前项目最近的根 session
./build/ap-tui -s ses_...
```

交互命令：`/new`、`/session`、`/help`、`/quit`。细节见 [docs/tui.md](docs/tui.md)。

`ap-web`：

```sh
./build/ap-web                          # http://127.0.0.1:8417
./build/ap-web --web-root ap-web/dist   # 前端资源走磁盘，开发时刷新即生效
./build/ap-web -c
```

页面支持新建和切换 session、单轮取消、刷新后从 transcript 重放历史。不同标签页和不同 project 可以并发，同一 session 仍只允许一个 turn。默认只监听回环地址；监听其他地址会打印安全警告。API、SSE 和并发语义见 [docs/web.md](docs/web.md)。

## 架构

```
cmd/ap ──► ap-cli（组装根）──► apcore（SDK 门面）──► engine
              │                    │                    ├──► tool ──► platform / protocol
              ├──► ap-cli/tools    └──► tool / platform  ├──► provider ──► vendor:curl
              └──► ap-cli/skills                        └──► transcript ──► JSONL + blobs

cmd/ap-tui ──► ap-tui ──┐
cmd/ap-web ──► ap-web ──┴──► ap-core/client + ap-core/protocol

cmd/magi-cli ──► magi-cli ──► apcore ──► engine
                              └──► ap-core/platform
```

| 位置 | 职责 |
| --- | --- |
| `ap-cli/` | CLI adapter 与组装根：参数、`settings.json`、agent / 技能 / prompt、输出、退出码、信号 |
| `ap-cli/tools/` | 五个内置工具、工具配置、进程树清理、子代理启动 |
| `ap-cli/skills/` | 技能发现、frontmatter 解析、提示词块 |
| `ap-core/` | SDK 门面：接收显式 `Config`，暴露会话生命周期 |
| `ap-core/engine/` | loop、provider、context、transcript、session |
| `ap-core/tool/` | 工具契约、注册表、执行管线 |
| `ap-core/platform/` | 路径、project/session、blob、JSON/文本、进程树、取消 token |
| `ap-core/protocol/` | 事件 schema、宽松解析、行分帧，只依赖 `core:` |
| `ap-core/client/` | 前端 kit：spawn、逐行泵事件、只读 session 访问 |
| `ap-tui/`、`ap-web/` | 前端库；本地包只允许 `ap-core/client` 与 `ap-core/protocol`，另可用 `core:` |
| `magi-cli/` | MAGI 决策器：参数、输入、三角色提示词、并行投票、一票否决与输出 |
| `cmd/` | 四个薄入口，只 import 对应的库包 |

依赖方向是单向的。`ap-cli` 不能直接 import `engine`；SDK 不读 argv、环境变量、`settings.json`，也不写 stdout、不装信号；前端不 import agent 代码。这些边由 `tools/check-deps.sh` 在构建和测试时强制，改 import 后先跑它。完整规则见 [docs/architecture.md](docs/architecture.md) 和 [docs/dependencies.md](docs/dependencies.md)。

## 存储

```
$AP_CONFIG/
  settings.json
  SYSTEM.md                       # 存在时替换内置固定指令段
  agents/<name>.md
  projects/<fnv32a(规范化 cwd)>/
    path.txt
    blobs/<sha256>
    <session_id>.jsonl

~/.agents/AGENTS.md               # 全局记忆
```

transcript 只追加完整事件；恢复时唯一允许的物理改动是截掉崩溃留下的不完整尾行，它从未成为事件。system prompt、model、agent、cwd 和工具集在 `session_start` 冻结。blob 不自动回收，删除后引用它的 session 无法完整恢复。

## 测试

```sh
./test.sh
```

脚本依次测试 `ap-core/protocol`、`platform`、`client`、`tool`、`engine`、`apcore`、`ap-cli`、`magi-cli`、`ap-tui`、`ap-web`，最后运行 `tools/check-deps.sh`。测试离线，不调用真实 LLM。前端测试单独跑：

```sh
npm --prefix ap-web test
```

修改 `ap-web/frontend/` 后需要重新生成并提交 `ap-web/dist/`：

```sh
npm --prefix ap-web install
npm --prefix ap-web run build
```

`build.sh` 检测到 `npx` 时会自动执行构建。不要手改 `dist/`。

## 平台说明

- Windows 控制台输出中文前会设置 UTF-8 code page。命令行参数的代码页不是 UTF-8 时，ap 会用宽字符命令行重建参数，避免 `--print` 中的中文变成非法字符串。
- 文件工具只支持 UTF-8，CRLF 统一为 LF。二进制或非 UTF-8 文件请用 `bash` 处理。
- `bash` 每次调用是独立进程，不保留 cwd、环境变量或 shell 变量；stdin 为 NUL。
- 超时或取消会终止整棵进程树。Windows 使用 Job Object，失败时退化为 `taskkill /T /F`；Unix 递归扫描后代，先发 `SIGTERM`，2 秒后发 `SIGKILL`。
- 子代理通过当前 ap 可执行文件重新拉起，stdout 是 `stream-json`，stderr 是人类可读日志。父进程不设 `task` 超时，靠信号取消。
- `ap-web` 的目录选择使用 Windows `IFileDialog`；Unix 没有统一的原生目录对话框，接口返回 501。

## 非目标

当前版本不做：

- 审批、权限规则、沙箱
- 上下文压缩、token 预算（后续由 handoff 替代）
- hooks、plan mode、MCP、插件系统
- grep、glob、ls、webfetch 等额外工具
- `--add-dir`：相对路径只相对启动目录
- blob 自动回收
- 技能脚本执行、参数传入、远程安装
- 远程会话共享、服务端部署

完整清单和理由见 [docs/README.md](docs/README.md)。

## 文档

| 文件 | 内容 |
| --- | --- |
| [AGENTS.md](AGENTS.md) | 仓库维护指南：构建、测试、包边界、改动地图 |
| [docs/README.md](docs/README.md) | 规格总览、决策、术语、文档地图 |
| [docs/architecture.md](docs/architecture.md) | 模块边界、依赖方向、进程模型 |
| [docs/dependencies.md](docs/dependencies.md) | 包布局、允许的 import 边、检查器 |
| [docs/cli-and-config.md](docs/cli-and-config.md) | 启动参数、输出格式、配置、存储布局 |
| [docs/react-loop-and-session.md](docs/react-loop-and-session.md) | 循环状态机、事件 schema、恢复与 fork |
| [docs/context-management.md](docs/context-management.md) | system prompt、记忆文件、消息投影 |
| [docs/provider.md](docs/provider.md) | OpenAI 适配、SSE、usage、错误 |
| [docs/tools.md](docs/tools.md) | 五个工具的契约、blob、进程与输出上限 |
| [docs/subagents.md](docs/subagents.md) | agent 定义、启动协议、结果契约 |
| [docs/skills.md](docs/skills.md) | 技能发现、`SKILL.md` 格式、提示词注入 |
| [docs/tui.md](docs/tui.md) | `ap-tui` 的进程模型与渲染 |
| [docs/web.md](docs/web.md) | `ap-web` 的 HTTP/SSE API 与并发语义 |
| [docs/integration.md](docs/integration.md) | 新前端接入 ap 的集成指南 |
| [docs/magi.md](docs/magi.md) | `magi-cli` 的角色、投票、输入输出与失败语义 |
| [docs/errors-and-cancellation.md](docs/errors-and-cancellation.md) | 错误分类、重试、信号、超时、恢复 |
