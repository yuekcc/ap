# 变更记录：提示词来源改为显式三选一

状态：**已全部落地**。当前参数行为、错误码与帮助文本以 [cli-and-config.md](../cli-and-config.md) 的「提示词来源」为准。本文只记录当时为什么删除隐式 stdin 回退。

## 当时的问题

旧版 `ap` 在没有任何提示词来源时会回退到 stdin：stdin 是 TTY 就报用法错误，不是 TTY 就读到 EOF。这个回退带来两个具体问题。

第一，同一条命令在不同环境下走不同分支。CI、服务、编辑器插件和宿主进程给 ap 继承的 stdin 可能是管道、重定向，也可能是一个保持打开的非 TTY 句柄。调用方无法从命令行本身判断 ap 会不会读 stdin。

第二，保持打开的非 TTY stdin 会让 ap 永久等待。turn 永远不开始，进程也不退出。对于把 ap 当子进程拉起的集成方，这比报错更难诊断。

这个回退还与 `--print0` 重叠。`--print0` 已经显式表示「从 stdin 读」，隐式回退只是同一能力的另一种触发方式，而且触发条件不可见。

## 选择的规则

提示词来源收紧为三选一：

- `-p, --print <提示词>`
- `--input-file <路径>`
- `--print0`

正常运行必须且只能给一个。两个以上由 `parse_args` 拒绝，一个都没有由 `read_prompt` 拒绝。两条错误路径都返回退出码 2。

校验拆在两个位置，是因为检查命令不需要提示词。`--help`、`--version`、`--list-skills`、`--print-system-prompt` 在读取提示词之前返回。`parse_args` 无法可靠判断后续会不会走这些分支，所以只在 `read_prompt` 里要求来源存在。

`--print-system-prompt` 也会打印上下文，但它不是提示词来源，不参与三选一。`--input-file` 的相对路径按启动目录解析。

行为矩阵只保留四条判断：

| 命令 | 结果 |
| --- | --- |
| `ap --print <文本>` | 正常执行，不读 stdin |
| `ap --input-file <文件>` | 正常执行，不读 stdin |
| `ap --print0` | 等待 stdin 直到 EOF，然后开始 turn |
| `ap`，没有来源 | 无论 stdin 是 TTY、管道还是继承句柄，都不读 stdin，退出码 2 |

`--print0` 在 TTY 上仍会等待 EOF。这是显式要求读 stdin 的结果，不是遗漏。

## 放弃的方案

保留隐式回退但增加 warning。不可行。warning 不能消除等待，也不能让命令行本身表达来源。

新增 `--stdin` 别名。不采纳。同一能力多一个名字只会扩大参数面。`--print0` 的 `0 = stdin` 已经写在帮助文本里。

重命名 `--print0`。不采纳。仓库内所有集成方已经使用这个名字，改名没有收益。

在 `parse_args` 里强制要求提示词。不可行。`--help` 等检查命令不读提示词，强制要求会把它们一并挡掉。

把「缺少提示词」提前到配置加载之前。这次没有做。方案只要求删掉隐式分支，提前校验需要另改 `run` 的顺序，不属于同一次行为修复。

## 迁移

这次变更会破坏依赖 `echo x | ap` 或 `cat x | ap --output-format json` 的外部脚本。升级后这些命令不再读取 stdin，并以退出码 2 失败，提示三个来源。需要管道输入时改为显式 `--print0`。

仓库内的调用方在变更前已经全部传 `--print0`，包括 `ap-tui`、`ap-web`、`ap-core/client` 的 spawn 路径和子代理启动。因此这次变更不需要兼容层。

迁移分三步完成：

1. 删除 `read_prompt` 的隐式 stdin 分支，换成缺少来源的错误。
2. 更新 `USAGE_TEXT`，删除「stdin 不是 TTY 时读取 stdin」的用法行，写明三选一。
3. 补回归测试，覆盖缺来源、互斥来源、`--print` 的 UTF-8 校验和检查命令不需要提示词。

## 落地核对

当前代码与方案一致：

- `ap-cli/options.odin` 的 `parse_args` 统计三个来源，超过一个返回 `--print, --input-file and --print0 are mutually exclusive`。
- `read_prompt` 的默认分支返回 `no prompt given; use --print, --input-file, or --print0`，不访问 stdin。
- `ap-cli` 中已经没有任何 `os.is_tty` 调用。
- `--print0` 仍走 `read_all_stdin`，UTF-8 校验保留。
- `ap-cli/options_test.odin` 有 `test_cli_requires_prompt_source`、`test_cli_rejects_conflicting_prompt_sources` 和帮助文本断言。

## 相关文档

- [cli-and-config.md](../cli-and-config.md)：当前参数表与提示词来源规则
- [integration.md](../integration.md)：前端如何用 `--print0` 驱动 ap
- [architecture.md](../architecture.md)：CLI adapter 在参数与输入上的职责
