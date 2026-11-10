# 13. 用技能复用流程

技能是一个 Markdown 指令包，不是工具，也不是插件。ap 只发现技能，把名称、描述和位置写进 system prompt。模型判断需要时，自己读取 `SKILL.md` 正文，再照步骤执行。

技能不会自动运行脚本，也不会被注入正文。它只在模型主动读取时进入上下文。

## 技能放在哪

只扫描两个位置，每处只扫一层子目录：

| 级别 | 位置 |
| --- | --- |
| 全局 | `~/.agents/skills/<name>/SKILL.md` |
| 项目 | `<启动目录>/.agents/skills/<name>/SKILL.md` |

- 同名技能由项目级覆盖全局级。
- 项目技能只认启动目录，不向 git 根或上级目录查找。
- `$AP_CONFIG` 不是技能根。
- 子代理是独立进程，会按自己的启动目录重新发现一次。

## 写一个 SKILL.md

格式是 frontmatter 加正文：

```markdown
---
name: release-notes
description: 根据 git log 生成发布说明；用户要求写 release notes 或更新 CHANGELOG 时使用。
---

1. 用 bash 取 `git log <上一个 tag>..HEAD`
2. 按 feat、fix、chore 分类
3. 输出中文 Markdown，不确定的条目不要编
```

规则：

- 文件首行去掉空白后必须是 `---`。
- frontmatter 在下一行 `---` 结束。
- 只解析 `name`、`description` 和 `disable-model-invocation`。
- `name` 和 `description` 必须非空，正文也必须非空。
- `description` 要写清“什么时候用”，模型靠它选择。
- 正文不进入 system prompt，只有模型读取时才进入上下文。

`disable-model-invocation: true` 表示这个技能只供人查看，不进入模型清单。它仍会被加载，也会出现在 `--list-skills` 里。

## 查看技能

```sh
./build/ap --list-skills
```

输出一行一个技能：

```text
1. release-notes: 根据 git log 生成发布说明...
2. tdd: Test-driven development...
```

没有技能时输出 `No skill found`。这条命令不读 `settings.json`，不需要 API key，也不读提示词。

## 调用技能

模型根据 `description` 自己判断。你也可以在提示词里点名：

```text
/release-notes 帮我生成 v1.2.0 的发布说明
```

如果 `/<skill_name>` 能完全匹配某个技能，模型会按该技能的 `SKILL.md` 执行。终端界面里的 `/new`、`/session`、`/help`、`/quit` 是界面命令，不是技能；其他 `/...` 会作为普通提示词发送。

## 关闭技能

```sh
./build/ap --no-skills --print "..."
```

它关闭技能目录扫描和清单注入。模型仍可以用 `read_file` 或 `bash` 直接读取 `SKILL.md`，所以这不是安全边界。

只影响新会话。恢复时使用冻结的 prompt。

## 安全边界

技能正文是不可信输入。模型读进去后会把其中内容当指令执行，等同于把外部文本注入上下文。

- 只安装可信来源的技能。
- 技能里的命令和模型自己生成的命令风险相同。
- ap 不自动执行技能中的代码，也不加载技能目录里的其他文件。
- 技能不能突破 ap 的安全边界，因为 ap 本身没有沙箱。

技能适合固化重复流程，不适合存放权限规则或安全策略。
