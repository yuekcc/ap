# 技能

技能（skill）是给模型按需读取的 Markdown 指令包，不是工具，也不是插件。ap 只负责发现技能、把清单元数据写进 system prompt。模型判断需要时，用 `read_file` 或 `bash` 读取 `SKILL.md`，再照其中步骤执行。
本文件定义发现位置、`SKILL.md` 格式、提示词注入块、`--list-skills` 和安全边界。技能所属的包边界见 [dependencies.md](dependencies.md)，记忆文件见 [context-management.md](context-management.md)。

技能属于应用层（`ap-cli/skills`，package `apskills`）。SDK 不扫描技能目录、不解析 `SKILL.md`，也不认识 `skill` 概念。ap 不执行技能脚本，不传参数，不做版本管理、远程安装或市场，也不把正文直接注入 system prompt。

## 发现

每次新 session 组装 system prompt 时扫描两处，每处只扫一层子目录：

| 级别 | 位置 |
| --- | --- |
| 全局 | `~/.agents/skills/<name>/SKILL.md` |
| 项目 | `<启动目录>/.agents/skills/<name>/SKILL.md` |

规则：

1. 目录里必须有 `SKILL.md`。文件读不到、不是合法 UTF-8 或解析失败时跳过，不报错、不终止。
2. `name`、`description` 和正文三者都非空才算有效技能。
3. 同名技能由项目级覆盖全局级。同一级别里同名时，后扫描到的覆盖先扫描到的。
4. 结果按 `name` 升序排列，保证同一目录集合产出稳定的提示词。
5. `$AP_CONFIG` 不是技能根。全局技能固定在 `~/.agents/skills`。
6. 项目技能只认启动目录，不向 git 根或上级目录查找。
7. 恢复 session 不重新扫描。system prompt 在 `session_start` 冻结。
8. `--no-skills` 关闭发现与注入，但不改变 `--list-skills`。

子代理是独立 ap 进程，会按子进程的启动目录重新发现一次。`task` 不改变工作目录，通常得到与父进程相同的清单。

## SKILL.md 格式

```markdown
---
name: release-notes
description: 根据 git log 生成发布说明；用户要求写 release notes 或更新 CHANGELOG 时使用。
---

1. 用 bash 取 `git log <上一个 tag>..HEAD`
2. 按 feat、fix、chore 分类
3. 输出中文 Markdown，不确定的条目不要编
```

约束：

1. 文件可以带 UTF-8 BOM，读取时先去掉 BOM。首行去掉空白后必须是 `---`。
2. frontmatter 在后续某一行的 `---` 结束，该行两侧空白会被忽略。缺少结束行时跳过。
3. 只解析 `name`、`description` 和 `disable-model-invocation`。其余字段忽略，`#` 开头的行忽略，没有冒号的行忽略。
4. `name` 与 `description` 出现多次时，以第一个非空值为准。`disable-model-invocation` 出现多次时，以最后一次为准。
5. 值可以不加引号，也可以用单引号或双引号包裹。双引号内的 `\\`、`\"`、`\n`、`\t`、`\r` 会还原，其它反斜杠序列保持原样。
6. `name` 只是标识，不要求等于目录名。`description` 写清什么时候该用，模型据此选择。
7. 正文是结束 `---` 之后的全部内容，去掉首尾空白后必须非空。文件接受 CRLF，正文按 LF 归一。
8. 正文不进入 system prompt。只有模型主动读取时才进入上下文。
9. `disable-model-invocation: true` 表示该技能只供用户查看，不进入 system prompt。只识别 `true`，不区分大小写，缺省为 `false`。该技能仍会加载，也会出现在 `--list-skills` 中。

## 提示词注入

`ap-cli/prompt.odin` 只在新 session 组装应用层 section 时注入技能清单。位置在「环境」之后、「全局记忆」之前。完整顺序见 [context-management.md](context-management.md)。

有可注入技能时，小节内容如下：

```text
## 可用技能

若 <available_skills> 里有明显适用于当前任务的 skill，先用 read_file 读取其 <location> 指向的 SKILL.md（文件过大或需要定位片段时用 bash），再照其中步骤执行。若多个都沾边，选最贴切的那个；若都不贴切，一个都不要读。skill 中引用相对路径时，以该 SKILL.md 所在目录为基准解析成绝对路径再使用。

用户也会使用 /<skill_name> 方式调用 skill，如果 <skill_name> 能完全匹配某个 skill，也用上述的方式调用 skill。

<available_skills>
  <skill>
    <name>release-notes</name>
    <description>...</description>
    <location>C:/Users/me/.agents/skills/release-notes/SKILL.md</location>
  </skill>
</available_skills>
```

约束：

1. 没有任何可注入技能时，包括全部技能都声明 `disable-model-invocation: true`，整个「可用技能」小节不出现，不留空标题或“暂无技能”之类内容。
2. `name`、`description` 和 `location` 做 XML 转义，覆盖 `&`、`<`、`>`、`"`、`'`。
3. `location` 使用 `/`，避免 Windows 反斜杠被当成转义符。
4. 只注入元数据，不注入正文。技能再多也只占清单的 token。
5. agent 的工具白名单不参与发现。agent 既没有 `read_file` 也没有 `bash` 时，清单仍会注入，但它无法读取正文。需要技能时给该 agent 加上 `read_file`。
6. `--no-skills` 时完全不扫描技能目录，也不注入「可用技能」小节。它只影响新 session 的提示词，不是安全边界。模型仍可用 `read_file` 或 `bash` 直接读取 `SKILL.md`。

## 查看技能

```sh
ap --list-skills
```

输出一行一个技能，包括声明了 `disable-model-invocation: true` 的技能：

```text
1. release-notes: 根据 git log 生成发布说明...
2. tdd: Test-driven development...
```

没有技能时输出 `No skill found`。该命令不读 `settings.json`，不需要 API key，也不读提示词。`--config-dir` 对它没有影响，`--no-skills` 也不改变输出。该命令在加载配置之前处理，`--help` 与 `--version` 的优先级更高。

## 安全边界

1. 技能正文是不可信输入。模型读取后会把其中内容当指令执行，等同于把外部文本注入上下文。只安装可信来源的技能。
2. 技能不能突破 ap 的安全边界。ap 没有沙箱、审批或权限规则，技能里的命令和模型自己生成的命令风险相同。
3. `location` 可以是项目外的绝对路径，全局技能就在 home 下。`read_file` 与 `bash` 本身不受目录限制。
4. ap 不自动执行技能中的代码，也不加载技能目录里的其它文件。只有模型点名的那份 `SKILL.md` 会被读取。

## 相关文档

- [cli-and-config.md](cli-and-config.md)：`--list-skills` 与 `--no-skills` 在 CLI 中的处理顺序。
- [context-management.md](context-management.md)：技能小节的完整顺序与 system prompt 组装。
- [subagents.md](subagents.md)：子代理如何重新发现技能。
- [tools.md](tools.md)：`read_file` 与 `bash` 的读取边界。
- [dependencies.md](dependencies.md)：`ap-cli/skills` 的 import 约束。
