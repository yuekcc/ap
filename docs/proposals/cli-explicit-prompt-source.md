# 变更方案：移除隐式 stdin 提示词输入，`--print` / `--input-file` / `--print0` 三选一

状态：**草案，待评审**。评审通过后按第 9 节顺序落地；本文件不属于定稿规格。

## 1. 摘要

当前 `ap` 在没有任何提示词来源时会回退到隐式读取 stdin：stdin 不是 TTY 就读到 EOF，是 TTY 才报用法错误。该行为与 `--print0` 重叠，并带来两个问题：

- 行为不确定：同一条命令在 TTY / 管道 / 重定向下走不同分支。
- 可能永久挂起：集成方、服务、CI 或宿主进程给 ap 继承了一个保持打开的非 TTY stdin 时，ap 会一直等 EOF，turn 永远不开始。

本方案删除该隐式回退，把提示词来源收紧为**三选一**：

- `-p, --print <提示词>`
- `--input-file <path>`
- `--print0`（从 fd 0 读取到 EOF）

正常运行必须且只能给一个；同时出现或都没给都返回退出码 2。`--help`、`--version`、`--list-skills`、`--print-system-prompt` 不需要提示词，不受此限制。

ap 主要由 ap-tui、ap-web、SDK 子代理等程序集成，仓库内所有调用方均已显式使用 `--print0`；直接调用时多传一个开关也可以接受。

## 2. 已接受的设计决策

| 决策 | 结论 |
| --- | --- |
| 是否保留隐式 stdin | 删除。需要 stdin 时必须显式传 `--print0` |
| 三个来源的关系 | 三选一；正常运行必须且只能给一个 |
| 校验位置 | 多个来源由 `parse_args` 拒绝；缺少来源由 `read_prompt` 拒绝 |
| 为什么不在 `parse_args` 强制必填 | `--help` / `--version` / `--list-skills` / `--print-system-prompt` 不需要提示词，`parse_args` 无法区分后续命令 |
| 错误消息 | 缺来源：`no prompt given; use --print, --input-file, or --print0` |
| 是否保留 `read_all_stdin` | 保留，`--print0` 仍使用 |
| 是否重命名 `--print0` | 不重命名；`0 = stdin` 的说明继续保留 |
| 是否新增 stdin 别名 | 否；需要 stdin 就用 `--print0` |
| 是否提前到配置加载前校验 | 否，本方案保持最小改动；见第 10 节 |

## 3. CLI 表面

### 3.1 提示词来源

| 参数 | 值 | 说明 |
| --- | --- | --- |
| `-p, --print <prompt>` | 提示词 | 参数即提示词；空字符串视为用法错误；必须是合法 UTF-8 |
| `--input-file <path>` | 文件路径 | 文件必须存在、可读、非空、合法 UTF-8；相对路径按启动目录解析 |
| `--print0` | — | 从 fd 0 读取整条提示词直到 EOF；内容非空且为合法 UTF-8 |

`--print-system-prompt` 也会打印上下文，但它不是提示词来源，不参与三选一。

### 3.2 校验规则

1. `parse_args` 继续统计来源数量，`> 1` 时返回用法错误（退出码 2）：
   `--print, --input-file and --print0 are mutually exclusive`
2. `parse_args` 不检查来源是否为 0，因为检查命令不需要提示词。
3. 正常运行路径上，`run` 调用 `read_prompt`；`read_prompt` 的默认分支在来源为 0 时返回：
   `no prompt given; use --print, --input-file, or --print0`
4. `--help` / `--version` / `--list-skills` 在 `read_prompt` 之前返回；`--print-system-prompt` 由 `run.odin` 显式跳过 `read_prompt`。因此这些命令不会触发“缺少提示词”。

### 3.3 帮助文本

`ap-cli/app.odin` 的 `USAGE_TEXT` 用法段改为：

```text
用法:
  ap --print <提示词> [选项]   # -p 为 --print 的别名
  ap --input-file <文件> [选项]
  ap --print0 [选项]          # 0 = stdin，读取到 EOF

必须从以上三种方式中选择一种提供提示词；ap 不会隐式读取 stdin。
```

删除原第 55 行：

```text
  ap [选项]                    # stdin 不是 TTY 时读取 stdin
```

`--print0` 在“提示词与上下文”段中的说明保持不变：

```text
      --print0                从 stdin 读取提示词直到 EOF
```

## 4. 行为规格

### 4.1 来源与 stdin 组合矩阵

| 命令 | stdin | 结果 |
| --- | --- | --- |
| `ap --print "x"` | TTY / 管道 / 重定向 | 正常执行，不读 stdin |
| `ap --input-file prompt.txt` | TTY / 管道 / 重定向 | 正常执行，不读 stdin |
| `ap --print0` | 管道或重定向，写入后关闭 | 正常执行，读到 EOF 后开始 turn |
| `ap --print0` | TTY | 保持现有行为：等待 EOF；这是显式要求读 stdin 的后果 |
| `ap`（无来源） | TTY | 退出码 2，提示三个来源 |
| `ap`（无来源） | 管道 / 重定向 | **不再读取**，立即退出码 2 |
| `ap`（无来源） | 继承的、保持打开的非 TTY stdin | **不再挂起**，立即退出码 2 |
| `ap --print x --print0` | 任意 | `parse_args` 退出码 2 |
| `ap --help` | 任意 | 打印帮助，退出码 0 |
| `ap --version` | 任意 | 打印版本，退出码 0 |
| `ap --list-skills` | 任意 | 列出技能，退出码 0 |
| `ap --print-system-prompt` | 任意 | 打印 system prompt，退出码 0，不读 stdin |

### 4.2 `read_prompt` 流程

调整后 `read_prompt` 的分支为：

1. `opts.print_prompt != nil`：校验非空与 UTF-8，直接作为提示词。
2. `opts.input_file != nil`：解析路径、读取文件，校验非空与 UTF-8。
3. `opts.print0`：调用 `read_all_stdin`，校验非空与 UTF-8。
4. 其他：返回用法错误，不访问 stdin。

原来的第 4 分支（`os.is_tty(os.stdin)` 判断 + 回退读取）整段删除。

### 4.3 错误消息

| 场景 | 消息 | 退出码 |
| --- | --- | --- |
| 同时给多个来源 | `--print, --input-file and --print0 are mutually exclusive` | 2 |
| 正常运行时没有来源 | `no prompt given; use --print, --input-file, or --print0` | 2 |
| `--print` 空值 | `--print requires a non-empty prompt` | 2 |
| `--input-file` 空文件 | `--input-file is empty: <path>` | 2 |
| `--print0` 空输入 | `--print0 received an empty prompt from stdin` | 2 |

### 4.4 编码与 EOF 语义

- `read_all_stdin` 的 UTF-8 校验不变；非法字节返回退出码 2。
- `--print0` 的“0 = stdin”语义不变，仍然不是 NUL 分隔。
- 写完提示词后关闭 stdin 写端仍然表示 EOF，集成文档的行为不变。
- 本方案只改变“未指定来源时是否读 stdin”，不改变 `--print0` 的读取实现。

## 5. 代码改动清单

### 5.1 `ap-cli/options.odin`

删除 `read_prompt` 末尾的隐式 stdin 分支（当前约 419–433 行）：

```odin
	case:
		if os.is_tty(os.stdin) {
			return "", make_error(
				.Usage,
				"no prompt given; use --print, --input-file, --print0, or pipe a prompt on stdin",
			)
		}
		data, derr := read_all_stdin()
		if !is_ok(derr) {
			return "", derr
		}
		if len(data) == 0 {
			return "", make_error(.Usage, "empty prompt on stdin")
		}
		prompt = data
```

替换为：

```odin
	case:
		return "", make_error(
			.Usage,
			"no prompt given; use --print, --input-file, or --print0",
		)
```

影响：

- 不再调用 `os.is_tty`；这是 `ap-cli` 中唯一一处使用。
- `os` 仍被 `os.stdin`、`os.read`、`os.exists`、`os.read_entire_file_from_path` 使用，import 不变。
- `read_all_stdin` 保留，`--print0` 继续使用。
- `parse_args` 的来源计数与互斥检查（当前约 248–260 行）**不改**。

### 5.2 `ap-cli/app.odin`

- 删除 `USAGE_TEXT` 中的 `ap [选项]                    # stdin 不是 TTY 时读取 stdin`。
- 在用法段末尾补一句“必须三选一，ap 不会隐式读取 stdin”。
- 其余帮助文本不变。

### 5.3 不改的部分

- `ap-core/client/spawn.odin`：已固定追加 `--print0`。
- `ap-core/engine/tool_task.odin`：子代理已传 `--print0`。
- `ap-tui` / `ap-web`：已通过 `--print0` 启动 ap。
- `ap-core/client/turn.odin`：提示词写 stdin 后关写端的协议不变。
- `read_all_stdin` 的 UTF-8 校验与 EOF 处理。
- 退出码枚举与错误映射。

## 6. 文档改动清单

本次已先按本方案更新：

| 文件 | 改动 |
| --- | --- |
| `README.md` | “使用”开头声明必须显式指定三个来源之一，ap 不会隐式读 stdin |
| `docs/cli-and-config.md` | “提示词来源”改为三选一；删除 TTY/非 TTY 回退描述；补集成建议 |
| `docs/integration.md` | `--print0` 必传说明与规则行补充“不会隐式读取 stdin” |

无需改动（已经显式使用 `--print0`）：

- `docs/tui.md`
- `docs/web.md`
- `docs/subagents.md`
- `docs/architecture.md`
- `ap-web/README.md`

保留原样：

- `docs/proposals/cli-prompt-context-tools.md`：历史提案，不随本次行为回改。

## 7. 测试计划

### 7.1 单元测试（`ap-cli/options_test.odin`）

新增“没有来源必须报错”的测试。该测试在删除隐式分支后才可稳定运行：

```odin
@(test)
test_cli_requires_prompt_source :: proc(t: ^testing.T) {
	_, err := read_prompt(Options{}, ".")
	testing.expect_value(t, err.code, Exit_Code.Usage)
	testing.expect(t, strings.contains(err.message, "--print"))
	testing.expect(t, strings.contains(err.message, "--input-file"))
	testing.expect(t, strings.contains(err.message, "--print0"))
}
```

保留并确认：

- `test_cli_rejects_conflicting_prompt_sources`：两个来源仍然退出码 2。
- `test_cli_rejects_invalid_utf8_print_prompt`：`--print` 的 UTF-8 校验不受影响。
- `test_cli_help_and_version`、`test_cli_list_skills`、`test_cli_print_system_prompt`：不需要提示词仍能解析。

扩展帮助文本测试：

- `USAGE_TEXT` 包含 `--print`、`--input-file`、`--print0`。
- `USAGE_TEXT` 不再包含 `stdin 不是 TTY`。
- `USAGE_TEXT` 不再包含裸的 `ap [选项]` 用法行。

### 7.2 命令级验证

```sh
# 正常来源
./build/ap --help
./build/ap --version
./build/ap --list-skills
./build/ap --print-system-prompt

# 管道必须显式 --print0
printf 'hello' | ./build/ap --print0 --output-format json

# 以下必须退出码 2，且不能挂起
printf 'hello' | ./build/ap
./build/ap
printf 'hello' | ./build/ap --print x
```

Windows 下用 `build/ap.exe`，并检查 `echo hello | build/ap.exe` 同样立即返回 2。

### 7.3 回归测试

- `odin test ap-cli -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false`
- `./test.sh`
- `./build.sh`
- ap-tui / ap-web 各跑一轮，确认 `--print0` 路径正常。

## 8. 兼容性、风险与缓解

### 8.1 兼容性影响

- **会破坏**：外部脚本直接依赖 `echo x | ap`、`cat x | ap --output-format json` 等隐式 stdin 写法。升级后这些命令退出码 2。
- **不会破坏**：所有显式使用 `--print` / `--input-file` / `--print0` 的调用。
- **不会破坏**：仓库内 ap-tui、ap-web、SDK 子代理及测试，它们均已显式传 `--print0`。
- **不会破坏**：文档中唯一公开的管道示例 `cat prompt.txt | ap --print0`。

### 8.2 风险与缓解

| 风险 | 缓解 |
| --- | --- |
| 外部集成方以为不传开关也能读 stdin | 错误消息直接列出三个来源；发布说明写明行为变更 |
| `--print0` 在 TTY 上仍会等待 EOF | 保持现状；这是显式读 stdin 的预期行为，帮助文本已写“读取到 EOF” |
| 删除分支后 `os.is_tty` 变成未使用 | 确认 `os` 包其他 API 仍在使用；构建时用 `-vet` 检查 |
| 缺少来源的报错发生在配置加载之后 | 已知限制，本方案不扩大到早期校验；见第 10 节 |
| 有调用方依赖“TTY 下报错、非 TTY 下读取”的差异 | 该差异正是要消除的歧义；要求调用方显式声明来源 |

### 8.3 发布说明建议

> ap 不再在未指定提示词来源时隐式读取 stdin。请使用 `--print`、`--input-file` 或 `--print0` 之一；从 stdin 输入时显式传 `--print0`。

## 9. 实施顺序

1. 修改 `ap-cli/options.odin`：删除隐式 stdin 分支，替换错误消息。
2. 修改 `ap-cli/app.odin`：更新 `USAGE_TEXT`。
3. 修改 `ap-cli/options_test.odin`：新增缺来源测试，扩展帮助文本断言。
4. 文档改动（本文件第 6 节）已先行完成，评审时一并核对。
5. 运行 `odin test ap-cli`、`./test.sh`、`./build.sh`。
6. 手工验证第 7.2 节的命令，确认无挂起、退出码正确。
7. 更新发布说明。

## 10. 非目标（本方案）

- 不重命名 `--print0`，也不新增 `--stdin` 之类的别名。
- 不删除 `--input-file`。
- 不改变 `--print0` 在 TTY 上等待 EOF 的行为。
- 不改变 stdin 的 UTF-8 校验规则。
- 不把“缺少提示词”的校验提前到配置加载之前；如后续需要，可单独增加 `run` 层的前置检查，让 `ap` 在缺少来源时不必加载 `settings.json` 或 API key 就能报用法错误。
- 不改动历史提案 `docs/proposals/cli-prompt-context-tools.md`。

## 11. 验收标准

1. `ap` 不带来源时，无论 stdin 是 TTY、管道、重定向还是保持打开的继承句柄，都立即退出码 2，并打印三个来源提示。
2. `printf 'x' | ap` 退出码 2，且不会读取 stdin 内容。
3. `printf 'x' | ap --print0` 正常执行，行为与改动前一致。
4. `ap --print "x"`、`ap --input-file f` 正常执行，且不访问 stdin。
5. 同时传两个来源仍退出码 2。
6. `ap --help`、`ap --version`、`ap --list-skills`、`ap --print-system-prompt` 不需要提示词即可运行。
7. `USAGE_TEXT` 不再出现“stdin 不是 TTY 时读取 stdin”，且明确写出三选一。
8. `ap-cli` 单测、`./test.sh`、`./build.sh` 全部通过。
9. ap-tui、ap-web 各完成一轮对话，确认 `--print0` 集成未受影响。
