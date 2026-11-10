# 2. 安装 ap

当前版本没有面向普通用户的预编译安装包。你需要从源码构建。构建一次会得到四个可执行文件：

- `ap`：一次性命令行。
- `ap-tui`：终端界面。
- `ap-web`：浏览器界面。
- `magi-cli`：三名角色投票的决策工具。

## 准备环境

| 依赖 | 用途 | 说明 |
| --- | --- | --- |
| Odin nightly | 编译 ap | 开发和验证使用 `dev-2026-10-nightly:84bc3fc`。nightly 的 stdlib 会变，升级后重跑测试 |
| Bash | `bash` 工具 | Windows 需要 Git for Windows 提供 `bash.exe` |
| libcurl | 访问模型接口 | Linux 和 macOS 需要系统开发包；Windows 使用 Odin 随附的静态 libcurl |
| Node 和 npm | 重新构建网页前端 | 只在修改 `ap-web/frontend/` 或首次安装前端依赖时需要 |

Windows 用户请在 Git Bash 里执行构建命令，不要在 `cmd.exe` 或 PowerShell 里直接跑 `build.sh`。ap 会跳过 `C:\Windows\System32` 下的 WSL `bash.exe`，避免误用。需要指定 Bash 时，设置 `AP_BASH` 为 `bash.exe` 的绝对路径。

## 构建

在仓库根目录执行：

```sh
./build.sh
```

脚本会做三件事：

1. 检测到 `npx` 时，重新构建 `ap-web/dist`。
2. 检查包依赖边界。
3. 编译四个入口。

产物在 `build/`：

```text
build/ap
build/ap-tui
build/ap-web
build/magi-cli
```

Windows 下是对应的 `.exe` 文件。

如果 `build.sh` 在前端构建处停下，通常是 `ap-web/node_modules` 不存在。先安装依赖：

```sh
npm --prefix ap-web install
```

或者直接使用仓库里已提交的 `ap-web/dist/`，跳过前端构建，只编译你需要的入口。不要手改 `ap-web/dist/`。

## 验证安装

```sh
./build/ap --version
./build/ap --help
```

`--version` 打印版本号后退出。`--help` 打印参数用法后退出。两者都不需要提示词，也不需要读取模型配置。

再验证另外两个常用入口：

```sh
./build/ap-tui --help
./build/ap-web --help
```

## Windows 注意事项

- 在 Git Bash 中运行 `./build.sh`。
- 调用构建产物时写 `./build/ap.exe`，或使用 Windows 路径 `.\build\ap.exe`。
- 文件工具只处理 UTF-8 文本，CRLF 会归一为 LF。二进制文件请交给 `bash`。
- 控制台代码页不是 UTF-8 时，ap 会尝试用宽字符命令行重建参数。仍有乱码时，改用 `--input-file` 传提示词。

## 常见安装失败

**找不到 bash。** 安装 Git for Windows，或把 `AP_BASH` 指向 `bash.exe` 的绝对路径。不要指向 WSL 的 bash。

**前端构建失败。** 先跑 `npm --prefix ap-web install`。如果本机没有 Node，直接使用已提交的 `dist/`，不要删除它。

**libcurl 链接失败。** Linux 安装 `libcurl` 开发包；macOS 确认系统 libcurl 头文件可用。Windows 应使用 Odin 随附的静态 libcurl，不要手动替换。

**Odin 版本不匹配。** 换回 `dev-2026-10-nightly:84bc3fc`，或按新版 stdlib 修代码后重跑 `./test.sh`。

构建成功后，下一步是 [连接模型](03-connect-model.md)。
