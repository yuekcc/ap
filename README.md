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
- 跨平台：Windows / Linux / macOS；shell 统一使用 Bash

## 环境

- Odin nightly。开发与验证使用 `dev-2026-09-nightly:a2fb372`；nightly 的 stdlib 会变，升级 Odin 后请重新跑测试。
- Windows 需要 Git for Windows（提供 `bash.exe`）。ap 会跳过 `C:\Windows\System32` 下的 WSL `bash.exe`，优先使用 PATH 或常见 Git 安装位置；也可以用 `AP_BASH` 指定绝对路径。
- Windows 通过 `vendor:curl` 静态链接随 Odin 分发的 libcurl，产物是单个 exe。
- Linux / macOS 链接系统 libcurl（`system:curl`）；构建和运行需要系统已安装 libcurl 开发包。
- 构建产物需要能在 PATH 中找到 `bash`。

## 构建

Windows：

```powershell
.\build.ps1
# 或
odin build src -out:ap.exe -vet
```

Linux / macOS：

```sh
./build.sh
# 或
odin build src -out:ap -vet
```

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

### 技能

技能是放在 `SKILL.md` 里的 Markdown 指令包，ap 只负责发现并把清单注入 system prompt；模型需要时用 `read_file` 读取正文，再照步骤执行。发现位置：

- 全局：`~/.agents/skills/<name>/SKILL.md`（多 agent 共用）
- 项目：`<启动目录>/.agents/skills/<name>/SKILL.md`（同名覆盖全局）

正文不进入上下文，也不自动执行。格式与规则见 [docs/skills.md](docs/skills.md)。

## 存储

```
$AP_CONFIG/
  settings.json
  AGENTS.md
  agents/<name>.md
  projects/<sha256(规范化 cwd)>/
    path.txt
    blobs/<sha256>
    <session_id>.jsonl
```

transcript 只追加；恢复以 transcript 为准，system prompt / model / agent / cwd 冻结。blob 不自动回收，删除后引用它的 session 无法完整恢复。

## 测试

```powershell
.\test.ps1
# 或
odin test src -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
```

当前测试覆盖：CLI/配置/路径、transcript/blob/fork/半行修复、context 投影与重放、SSE 解析、provider tool call 组装与错误映射、文件工具、bash 超时/取消/进程树清理、loop 的 turn/step/重试/取消、大参数 blob、技能发现与提示词注入。

真实 LLM 端到端验证（使用本地 OpenAI 兼容端点，注意用量与超时）：

```powershell
$env:AP_API_KEY = "sk-..."
$cfg = Join-Path $env:TEMP "ap-e2e-config"
New-Item -ItemType Directory -Force $cfg | Out-Null
'{"model":"hy3","base_url":"http://127.0.0.1:8788/v1","max_steps":4,"max_tokens":512}' |
  Set-Content -Encoding utf8 (Join-Path $cfg "settings.json")
.\ap.exe --config-dir $cfg --print "Create hello.txt with content hello, then reply done" --output-format json
```

## 平台说明

- Windows 控制台输出中文前会设置 UTF-8 code page。
- 文件工具只支持 UTF-8，CRLF 统一为 LF；二进制或非 UTF-8 文件请用 `bash` 处理。
- `bash` 每次调用是独立进程，不保留 cwd、环境变量或 shell 变量；stdin 为 NUL。
- 超时/取消会终止整棵进程树：Windows 使用 Job Object（失败时退化 `taskkill /T /F`）；Unix 因 `core:os` 不暴露 `setpgid`，用递归后代扫描发送 `SIGTERM`，2s 后发送 `SIGKILL`。
- 子代理通过当前 ap 可执行文件重新拉起，stdout 是 `stream-json` 事件，stderr 是人类可读日志。父进程不设 `task` 超时，靠信号取消。

## 非目标（v1）

交互模式、审批/沙箱、上下文压缩、token 预算、hooks、plan mode、MCP、WebFetch/Search、`--add-dir`、blob GC、技能脚本执行与远程安装。详见 [docs/README.md](docs/README.md)。
