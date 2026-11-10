# 16. 数据存在哪

ap 的所有本地数据都在配置根目录下。默认是：

```text
~/.ap
```

可以用 `--config-dir <path>` 或环境变量 `AP_CONFIG` 改变位置。`--config-dir` 优先。

## 目录结构

```text
$AP_CONFIG/
  settings.json                   # 或 settings.jsonc，同时存在时后者优先
  SYSTEM.md                       # 存在时替换基础提示词
  agents/
    <name>.md                     # 代理定义
  logs/
    app-YYYY-MM-DD.log            # 诊断日志，按本地日期一天一个
  projects/
    <project_hash>/
      path.txt                    # 规范化后的项目路径
      blobs/
        <sha256>                  # 内容寻址的大块数据
        <sha256>.txt              # bash 分页续读用的完整输出
      <session_id>.jsonl          # 会话记录
```

全局记忆和全局技能不在 `$AP_CONFIG` 下：

```text
~/.agents/AGENTS.md
~/.agents/skills/<name>/SKILL.md
```

## 项目目录怎么分

ap 以启动目录作为项目根，规范化后计算一个哈希：

1. 解析为绝对路径。
2. 清理 `.`、`..`，解析符号链接和 Windows junction。
3. 去掉尾部分隔符，把 `\` 统一成 `/`。
4. Windows 上把整条路径转小写。
5. 取 FNV-1a 哈希的 8 位十六进制。

因此 `Z:\Projects\AP` 和 `Z:\projects\ap` 会落到同一个项目。从子目录启动会落到不同项目，`-s` 和 `-c` 不会跨项目查找。

`path.txt` 保存规范化路径。同一个哈希下 `path.txt` 内容不同时，ap 视为冲突并退出 2。

## 会话记录

每个会话一个 JSONL 文件，一行一个完整事件。规则：

- 只追加，完整事件永不改写。
- 每个事件写入后立即 flush。
- 恢复时唯一允许的物理改动是截掉崩溃留下的不完整尾行。
- 恢复不重新执行工具，不重试模型请求，也不生成摘要。

会话结束时会写 `session_end`。如果上一次运行没有写它，恢复时会 warning，说明上次是异常退出。

不要手动编辑 transcript。需要清理时删除整个会话文件，而不是改中间某一行。

## blob

大块内容写到 `projects/<hash>/blobs/`：

- 单次工具结果超过 `blob_threshold_bytes` 时写 blob，默认 100 KiB。
- 内容按 sha256 寻址，相同内容自动去重。
- 工具参数、图片和 system prompt 也可能写 blob。
- transcript 只保存引用、字节数和预览。

blob 不会自动回收。删除 blob 会让引用它的会话无法完整恢复。恢复时 blob 缺失、哈希不匹配或权限错误都会退出 2。

`bash` 输出超过 2000 行时还会写 `<sha256>.txt`，供模型用 `read_file` 续读。这个文件不在 transcript 中引用。

## 日志

诊断日志在：

```text
$AP_CONFIG/logs/app-YYYY-MM-DD.log
```

- 默认记录 warning 及以上级别。
- `--verbose` 加上 info，`--debug` 再加上 debug。
- 一条日志一行，格式是 `YYYY-MM-DD HH:MM:SS [level] message`。
- 日志不记录 `api_key`。
- 日志写入失败不影响运行和退出码。

日志可能包含文件路径、命令和错误信息。分享前先检查是否含敏感内容。

## 备份

要完整备份一个会话，必须同时备份：

```text
projects/<hash>/<session_id>.jsonl
projects/<hash>/blobs/
```

只复制 JSONL 不够。大工具结果、图片和 system prompt 可能在 blob 里。

整个配置目录一起备份最省事：

```sh
cp -a ~/.ap ~/.ap.backup
```

## 清理

可以安全删除的内容：

- `logs/` 下过期的日志。
- 不再需要的整个会话文件及其独占的 blob。

删除 blob 前要确认没有其他会话引用它。blob 按内容哈希共享，分叉会话也会共用同一份。

删除会话文件不会自动删除 blob，因此磁盘占用可能不会立刻下降。反过来，删除 blob 会破坏所有引用它的会话。

## 权限

配置文件里有 API key。不要把 `$AP_CONFIG` 放进公开仓库，也不要把 `settings.json` 提交到版本控制。使用单独的 key，方便吊销和限额。
