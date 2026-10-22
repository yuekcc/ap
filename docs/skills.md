# 技能（skills）

技能是给模型按需读取的 Markdown 指令包，不是工具、不是插件。ap 只负责发现技能、把清单写进 system prompt；模型判断需要时，用 `read_file`（必要时 `bash`）读取对应 `SKILL.md`，再照其中步骤执行。

v1 不做：技能脚本执行、参数传入、版本管理、远程安装/市场、把正文直接注入 system prompt。

## 发现

每次新 session 组装 system prompt 时扫描两处，只扫一层子目录：

| 级别 | 位置 | 说明 |
| --- | --- | --- |
| 全局 | `~/.agents/skills/<name>/SKILL.md` | 与其它 agent 共用；用户级技能放这里 |
| 项目 | `<启动目录>/.agents/skills/<name>/SKILL.md` | 只认启动目录，不向 git 根或上级目录查找 |

规则：

1. 目录里必须有 `SKILL.md`；读不到、不是 UTF-8、解析失败都跳过，不报错、不终止
2. `name` / `description` / 正文三者都非空才算有效技能
3. 同名技能**项目级覆盖全局级**；同一级别里同名时后扫描到的覆盖先扫描到的
4. 结果按 `name` 升序排列，保证同一目录集合产出稳定的提示词
5. `$AP_CONFIG` 不是技能根；全局技能固定在 `~/.agents/skills`
6. 恢复 session 不重新扫描：system prompt 在 `session_start` 冻结，见 [context-management.md](context-management.md)

子代理是独立 `ap` 进程，会用子进程的启动目录重新发现一次。`task` 不改变工作目录，因此通常与父进程看到同一份清单。

## SKILL.md 格式

```markdown
---
name: release-notes
description: 根据 git log 生成发布说明；用户要求写 release notes 或更新 CHANGELOG 时使用。
---

1. 用 bash 取 `git log <上一个 tag>..HEAD`
2. 按 feat / fix / chore 分类
3. 输出中文 Markdown，不确定的条目不要编
```

约束：

1. front matter 必须从文件第一行 `---` 开始，以单独一行 `---` 结束
2. 只解析 `name`、`description` 与 `disable-model-invocation`；其余字段忽略，`#` 开头的行忽略
3. 值可以不加引号，也可以用单/双引号包裹；双引号内的 `\"`、`\\`、`\n`、`\t`、`\r` 会还原
4. `name` 只是标识，不要求等于目录名；`description` 写清“什么时候该用它”，模型据此选择
5. 正文是 front matter 之后的全部内容，必须非空
6. 文件接受 UTF-8 BOM 与 CRLF，正文按 LF 归一
7. 正文不会被截断地注入提示词；它只在模型主动读取时进入上下文
8. `disable-model-invocation: true` 表示该技能只供用户查看，不进入 system prompt；只识别 `true`（不区分大小写），缺省为 false。它仍会加载，并出现在 `--list-skills` 中

## 注入 system prompt

只在新 session 组装提示词时注入，位置在「环境」之后、「全局记忆」之前：

```text
## 可用技能

若 <available_skills> 里有明显适用于当前任务的 skill，先用 read_file 读取其 <location> 指向的 SKILL.md（文件过大或需要定位片段时用 bash），再照其中步骤执行。
若多个都沾边，选最贴切的那个；若都不贴切，一个都不要读。
skill 中引用相对路径时，以该 SKILL.md 所在目录为基准解析成绝对路径再使用。

<available_skills>
  <skill>
    <name>release-notes</name>
    <description>...</description>
    <location>C:/Users/me/.agents/skills/release-notes/SKILL.md</location>
  </skill>
</available_skills>
```

约束：

1. 没有任何可注入技能时（包括全部技能都声明 `disable-model-invocation: true`），整个「可用技能」小节不出现，不留空标题或“暂无技能”之类噪音
2. `name` / `description` / `location` 做 XML 转义；路径统一用 `/`，避免 Windows 反斜杠在提示词里被当成转义符
3. 只注入元数据，不注入正文：技能再多也只占清单的 token
4. `--append-system-prompt` 仍排在技能之后，用户追加的指令优先级更靠后但位置最后
5. agent 工具白名单不参与发现；如果 agent 既没有 `read_file` 也没有 `bash`，清单仍会注入，但它无法读取正文。需要技能时给该 agent 加上 `read_file`
6. 声明 `disable-model-invocation: true` 的技能从清单中剔除，但仍会出现在 `--list-skills` 输出中

## 查看

```bash
ap --list-skills
```

输出所有人读简表（包括 `disable-model-invocation: true` 的技能），一行一个：

```text
1. release-notes: 根据 git log 生成发布说明...
2. tdd: Test-driven development...
```

没有技能时输出 `No skill found`。该命令不读 `settings.json`、不需要 API key，也不读提示词；`--config-dir` 对它没有影响。

## 参考实现与差异

本功能移植自 `mp-next/odin`（llmcli 的 Odin 重写版）的 `skill.odin`，保留其核心模型：两处发现、front matter、项目覆盖、按名排序、XML 转义、正文按需读取。适配 ap 时有四处差异：

| 维度 | odin/llmcli | ap |
| --- | --- | --- |
| 读取方式 | 提示词让模型用 bash（C3 版为 Python）读文件 | ap 有 `read_file`，优先用它；大文件再用 `bash` |
| 触发入口 | `llmcli skills` 子命令 | `ap --list-skills`（ap 没有子命令） |
| 注入位置 | 追加在 system prompt 末尾 | 环境之后、记忆与 agent 定义之前 |
| 正文 | 不注入，解析时只做有效性校验 | 同左 |

llmcli 的 `Skill.content` 会读入内存用于校验；ap 同样校验正文非空，但正文不进入提示词。

## 安全

1. 技能正文是**不可信输入**：模型读取后会把其中内容当指令执行，等同于把外部文本注入上下文。只安装可信来源的技能
2. skill 不能突破 ap 的安全边界：没有沙箱、没有审批，技能里的命令同样直接执行；风险与模型自己生成的命令相同
3. `location` 可以是项目外的绝对路径（全局技能就在 home 下）；`read_file` / `bash` 本身不受目录限制
4. ap 不自动执行技能中的任何代码，也不加载技能目录里的其它文件；只读模型点名的那份 `SKILL.md`

## 测试

单元测试见 `cli/skills_test.odin`，覆盖：

- front matter 解析、引号与转义、BOM/CRLF、正文 trim
- 缺少 name / description / 正文、缺少结束 `---`、没有 front matter 时判为无效
- 同名覆盖、按 name 排序、两处根目录的发现顺序
- 提示词块的空/非空、XML 转义、路径正斜杠、跳过 `disable-model-invocation: true` 的技能
- 简表格式（包含被禁用的技能）
- system prompt 中的小节位置（技能 → 全局记忆 → 追加指令）
