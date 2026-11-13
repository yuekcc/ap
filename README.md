# ap

ap 是一个用 [Odin](https://odin-lang.org/) 写的命令行 coding agent。给它一条提示词，它进入 ReAct 循环：请求 LLM、执行工具、把结果送回模型，直到任务完成或命中终止条件，然后退出。

名字取自 **agent process**：一条提示词对应一个进程、一个 turn；子代理和前端每轮也各自拉起一个 `ap` 子进程。

`ap` 本体是一次性 CLI。`ap-tui`（终端）和 `ap-web`（浏览器）是独立前端，每轮启动一个 `ap` 子进程，读取 `stream-json` 事件并渲染。`magi-cli` 是三名角色独立投票、一票否决的决策工具，基于 `apcore` SDK。

**用户手册见 [docs/README.md](docs/README.md)。** 安装、配置、日常使用、三种界面、安全边界和参数速查都在手册里；本文件只保留仓库入口和开发信息。

## 设计取舍

- **一次性 CLI 当内核。** 一条提示词进，一个 turn 出。参数、配置、输出格式和退出码保持稳定，脚本、子代理和其他前端都能复用。
- **transcript 是唯一事实来源。** 对话事件只追加到 JSONL；恢复时只读 transcript，不重新执行工具，也不调用模型生成摘要。内存里的消息列表只是投影。
- **全自动执行。** 没有审批弹窗、权限规则或沙箱。可追溯的记录、实时可见的工具输出和信号取消是仅有的止损手段，部署前要清楚这一点。
- **工具保持最小。** 只有读、写、编辑、bash 和子代理五个。grep、glob、ls 一类能力交给 bash，减少工具 schema 和模型的选择成本。
- **SDK 只保留机制。** agent loop、provider、transcript、context 和工具契约在 `ap-core`；具体工具、技能、`AGENTS.md`、agent 定义和 CLI 语义在 `ap-cli`。

## 快速开始

支持 Windows、Linux 和 macOS，shell 统一使用 Bash。需要 Odin nightly（开发和验证使用 `dev-2026-10-nightly:84bc3fc`）、bash 和 libcurl。Windows 的 bash 由 Git for Windows 提供。`ap-web/dist/` 不提交进仓库，编译 `ap-web` 需要 Node 和 npm 先生成它。

```sh
./build.sh
```

脚本会用 `npm --prefix ap-web run build` 重新生成 `ap-web/dist`、运行 `tools/check-deps.sh`，再编译四个入口。产物在 `build/`：`ap`、`ap-tui`、`ap-web`、`magi-cli`；Windows 为对应的 `.exe`。

配置并运行：

```sh
mkdir -p ~/.ap
cp settings.example.json ~/.ap/settings.json
# 编辑 model、base_url、api_key
./build/ap --print "找出读取配置的代码，给出文件和行号"
```

完整步骤见手册的 [安装](docs/02-install.md)、[连接模型](docs/03-connect-model.md) 和 [第一次对话](docs/04-first-run.md)。全部配置字段见 [settings.example.json](settings.example.json) 和 [配置项速查](docs/19-config-reference.md)。

## 测试

```sh
./test.sh
tools/check-deps.sh
```

`test.sh` 跑全部 Odin 测试，最后运行依赖边界检查；测试离线，不调用真实 LLM。

改过前端再跑：

```sh
npm --prefix ap-web test
npm --prefix ap-web run build
```

`ap-web/dist/` 是构建产物，不提交进仓库，不要手改。

## 架构

`ap-cli` 是 CLI adapter 和组装根，`ap-core` 是 SDK 门面，`ap-core/engine` 放 loop、provider、context、transcript 和 session。前端的本地包只依赖 `ap-core/client` 和 `ap-core/protocol`。依赖方向由 `tools/check-deps.sh` 强制。

模块图、包职责和进程模型见 [docs/internal/architecture.md](docs/internal/architecture.md)，允许的 import 边见 [docs/internal/dependencies.md](docs/internal/dependencies.md)。

## 文档

| 文件 | 内容 |
| --- | --- |
| [AGENTS.md](AGENTS.md) | 仓库维护指南：构建、测试、包边界、改动地图 |
| [docs/README.md](docs/README.md) | 用户手册入口 |
| [docs/internal/README.md](docs/internal/README.md) | 规格总览、决策、术语、文档地图 |
| [docs/internal/architecture.md](docs/internal/architecture.md) | 模块边界、依赖方向、进程模型 |
| [docs/internal/cli-and-config.md](docs/internal/cli-and-config.md) | 参数、配置、输出、存储 |
| [docs/internal/tools.md](docs/internal/tools.md) | 五个工具与 blob |
| [docs/internal/magi.md](docs/internal/magi.md) | MAGI 决策契约 |
