# ap

ap 是一个一次性命令行 coding agent：接收一条提示词，通过 ReAct 循环调用 LLM 与本地工具，直到任务完成。实现语言为 Odin，规格见 [docs/README.md](docs/README.md)。

## 状态

v1 已实现：

- 一次性 CLI（无交互 REPL），`text` / `json` / `stream-json` 三种输出
- session 持久化、恢复（`-s` / `-c`）、fork、只追加 JSONL transcript、内容寻址 blob
- OpenAI chat completions 兼容 provider（stream SSE、tool calls、usage、重试/超时/取消）
- 五个工具：`read_file`、`write_file`、`edit_file`、`bash`、`task`
- 独立进程子代理、agent 定义文件、工具白名单
- 技能（skill）：发现 `~/.agents/skills` 与项目 `.agents/skills`，把清单注入 system prompt，由模型按需读取正文；`--list-skills` 查看
- 独立的交互式 `ap-tui`：每轮启动一次 ap 子进程，滚动渲染 stream-json，管理单个活动 session
- 独立的浏览器客户端 `ap-web`：HTTP + SSE 服务器，内置 Alpine.js 单页；每轮启动 ap 子进程，实时渲染消息与工具卡片，侧栏按工作目录分组并支持跨目录切换会话、history 恢复、取消、多标签页/多 project 并发与 Windows 目录选择
- 跨平台：Windows / Linux / macOS；shell 统一使用 Bash

## 环境

- Odin nightly。开发与验证使用 `dev-2026-09-nightly:a2fb372`；nightly 的 stdlib 会变，升级 Odin 后请重新跑测试。
- Windows 需要 Git for Windows（提供 `bash.exe`）。ap 会跳过 `C:\Windows\System32` 下的 WSL `bash.exe`，优先使用 PATH 或常见 Git 安装位置；也可以用 `AP_BASH` 指定绝对路径。
- Windows 通过 `vendor:curl` 静态链接随 Odin 分发的 libcurl，产物是单个 exe。
- Linux / macOS 链接系统 libcurl（`system:curl`）；构建和运行需要系统已安装 libcurl 开发包。
- 构建产物需要能在 PATH 中找到 `bash`。
- 修改 `ap-web` 前端时才需要 Node（`esbuild` + `alpinejs`、`markdown-exit`、`github-markdown-css`）；`ap-web/dist/` 已提交，平时构建不需要 Node。

## 构建

Windows：

```powershell
.\build.ps1
# 或
mkdir bin
odin build ap -out:bin/ap.exe -vet
odin build ap-tui -out:bin/ap-tui.exe -vet
odin build ap-web -out:bin/ap-web.exe -vet
```

Linux / macOS：

```sh
./build.sh
# 或（源码目录 ap/ 与二进制 ap 同名，Unix 上产物放 bin/）
mkdir -p bin
odin build ap -out:bin/ap -vet
odin build ap-tui -out:bin/ap-tui -vet
odin build ap-web -out:bin/ap-web -vet
```

构建产物统一放在 `bin/`（Unix 上源码目录 `ap/` 与二进制 `ap` 同名，不能都放在仓库根目录）。把 `bin/` 加入 `PATH`，或直接使用 `./bin/ap`（Windows 为 `.\bin\ap.exe`）。`build.sh` / `build.ps1` 会在检测到 `npx` 时先刷新 `ap-web/dist`，否则使用仓库里已提交的前端产物。

## 配置

配置文件固定为 `$AP_CONFIG/settings.json`，默认 `~/.ap`，可用 `--config-dir` 或 `AP_CONFIG` 覆盖。最快的做法是把仓库里的示例复制过去：

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.ap" | Out-Null
Copy-Item settings.example.json "$env:USERPROFILE\.ap\settings.json"
```

然后编辑其中的 `model`、`base_url`、`api_key`。

```json
{
  "model": "hy3",
  "base_url": "http://127.0.0.1:8788/v1",
  "api_key": "sk-...",
  "max_steps": 100,
  "max_agent_depth": 1,
  "max_tokens": 8192,
  "tool_timeout_ms": 120000,
  "llm_timeout_ms": 600000,
  "blob_threshold_bytes": 102400,
  "max_capture_bytes": 67108864,
  "stream_include_usage": true
}
```

`api_key` 也可由环境变量 `AP_API_KEY` 提供（优先级更高）；日志和 transcript 不记录密钥。`bash` 工具执行命令前会剔除 `AP_API_KEY`。

JSON 输出（transcript、json/stream-json、provider 请求）保留 UTF-8 原文，不再把中文转成 `\uXXXX`；只有控制字符、引号、反斜杠和非法 UTF-8 字节保持转义。

## 使用

```sh
# 直接提示词
ap --print "找出 config 加载路径并给出文件与行号"

# 从文件 / stdin
ap --input-file prompt.txt
cat prompt.txt | ap --print0

# 结构化输出
ap --print "..." --output-format json
ap --print "..." --output-format stream-json

# 恢复、继续、fork
ap -s <session_id> --print "..."
ap -c --print "..."
ap -c --fork-session --print "..."

# 指定 agent / 模型 / 上限
ap --agent scout --model hy3 --max-steps 30 --print "..."

# 查看当前目录可见的技能
ap --list-skills
```

相对路径相对启动目录；`~/...` 会展开。没有 `--add-dir`。

## 交互式 TUI

`ap-tui` 是独立可执行文件，内部按轮启动 `ap`，自己不实现 agent 逻辑；路径、project hash、session 发现和 blob 读取与 ap 共用 `internal/`。

```sh
# 新 session
./bin/ap-tui

# 继续当前项目最近的根 session（启动时会重放历史）
./bin/ap-tui -c

# 恢复指定 session
./bin/ap-tui -s ses_20261022_120000_abcdef123456

# 指定 agent 可执行文件（默认找同目录 ap / ap.exe / ag）
./bin/ap-tui --agent-bin /path/to/ap
```

Windows 下产物在 `bin\`，直接使用 `.\bin\ap-tui.exe` 即可。

交互命令：`/new`、`/session`、`/help`、`/quit`。TUI 使用普通滚动输出和行输入；每轮结束回到 `> `。第一阶段的输入框依赖终端自带行编辑，方向键历史、运行中取消等留给第二阶段。协议、历史重放和限制见 [docs/tui.md](docs/tui.md)。

## 浏览器 UI

`ap-web` 是独立可执行文件，把同一套 `stream-json` 协议渲染到浏览器；agent 逻辑、transcript 仍由每轮启动的 `ap` 子进程负责，`ap-web` 自己不实现 agent。

```sh
./bin/ap-web                          # http://127.0.0.1:8417
./bin/ap-web --web-root ap-web/dist   # 开发模式：静态资源走磁盘，前端改动刷新即生效
./bin/ap-web -c                       # 启动即定位当前项目最近的 session
./bin/ap-web -s ses_...
```

默认只监听 `127.0.0.1`；显式监听其他地址会打印安全警告。页面支持单轮取消、刷新后从 transcript 恢复画面、切换/新建 session；不同标签页可各自跑一个 session，同一 session 仍单飞。Windows 下可弹出系统目录选择框切换工作目录。需要改前端时先 `npm --prefix ap-web install && npm --prefix ap-web run build`。API、SSE、并发语义、目录选择与安全默认见 [docs/web.md](docs/web.md)。

### 技能

技能是放在 `SKILL.md` 里的 Markdown 指令包，ap 只负责发现并把清单注入 system prompt；模型需要时用 `read_file` 读取正文，再照步骤执行。发现位置：

- 全局：`~/.agents/skills/<name>/SKILL.md`（多 agent 共用）
- 项目：`<启动目录>/.agents/skills/<name>/SKILL.md`（同名覆盖全局）

正文不进入上下文，也不自动执行。声明 `disable-model-invocation: true` 的技能不会注入 system prompt，但仍会出现在 `--list-skills` 中。格式与规则见 [docs/skills.md](docs/skills.md)。

## 存储

```
$AP_CONFIG/
  settings.json
  AGENTS.md
  agents/<name>.md
  projects/<fnv32a(规范化 cwd)>/
    path.txt
    blobs/<sha256>
    <session_id>.jsonl
```

transcript 只追加完整事件；恢复时只会截掉崩溃留下的不完整尾行。恢复以 transcript 为准，system prompt / model / agent / cwd 冻结。blob 不自动回收，删除后引用它的 session 无法完整恢复。

## 测试

```powershell
.\test.ps1
# 或
odin test ap -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
odin test ap-tui -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
odin test ap-web -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
npm --prefix ap-web test
```

当前测试覆盖：CLI/配置/路径、transcript/blob/fork/半行修复、context 投影与重放、SSE 解析、provider tool call 组装与错误映射、文件工具、bash 超时/取消/进程树清理、loop 的 turn/step/重试/取消、大参数 blob、技能发现与提示词注入；`ap-web` 覆盖 HTTP 解析/路由、SSE hub 与按 session 过滤、agent 事件泵、同 session 单飞与多 session 并发、内置/磁盘静态资源、目录选择与前端事件归约。

真实 LLM 端到端验证（使用本地 OpenAI 兼容端点，注意用量与超时）：

```powershell
$env:AP_API_KEY = "sk-..."
$cfg = Join-Path $env:TEMP "ap-e2e-config"
New-Item -ItemType Directory -Force $cfg | Out-Null
'{"model":"hy3","base_url":"http://127.0.0.1:8788/v1","max_steps":4,"max_tokens":512}' |
  Set-Content -Encoding utf8 (Join-Path $cfg "settings.json")
.\bin\ap.exe --config-dir $cfg --print "Create hello.txt with content hello, then reply done" --output-format json
```

## 平台说明

- Windows 控制台输出中文前会设置 UTF-8 code page。命令行参数默认由 CRT 按系统 ANSI 代码页（ACP）编码；ACP 不是 UTF-8 时，ap 会改用宽字符命令行重建参数并转成 UTF-8，避免 `--print` 的中文变成非法字符串。
- 文件工具只支持 UTF-8，CRLF 统一为 LF；二进制或非 UTF-8 文件请用 `bash` 处理。
- `bash` 每次调用是独立进程，不保留 cwd、环境变量或 shell 变量；stdin 为 NUL。
- 超时/取消会终止整棵进程树：Windows 使用 Job Object（失败时退化 `taskkill /T /F`）；Unix 因 `core:os` 不暴露 `setpgid`，用递归后代扫描发送 `SIGTERM`，2s 后发送 `SIGKILL`。
- 子代理通过当前 ap 可执行文件重新拉起，stdout 是 `stream-json` 事件，stderr 是人类可读日志。父进程不设 `task` 超时，靠信号取消。
- `ap-web` 的目录选择使用 Windows `IFileDialog`；Unix 没有统一的原生目录对话框，接口返回 501。

## 非目标（v1）

交互模式、审批/沙箱、上下文压缩、token 预算、hooks、plan mode、MCP、WebFetch/Search、`--add-dir`、blob GC、技能脚本执行与远程安装。详见 [docs/README.md](docs/README.md)。
