# 附录 B：MAGI 决策怎么用

`magi-cli` 是一个独立工具，不属于 ap 的日常对话流程。它把一个问题交给三名角色独立投票，任意一名否决，整体就否决。

三名角色都没有工具。它们不会读文件、执行命令或修改工作区。每个角色有自己的 session，可以用 `ap -s <session_id>` 审计。

## 三名角色

| 成员 | 视角 | 关注点 |
| --- | --- | --- |
| BALTHASAR-2 | 战略与务实 | 成本收益、风险、可行性、长期影响 |
| CASPER-3 | 伦理与哲学 | 道德框架、人类福祉、公平与权利 |
| MELCHIOR-1 | 科学与分析 | 证据、概率、验证、客观性 |

成员之间看不到彼此的投票。MAGI 是三个独立视角的交叉检查，不是讨论。

## 运行

问题模式：

```sh
./build/magi-cli --question '是否包含恶意行为' --context '<材料>'
```

材料也可以从文件读：

```sh
./build/magi-cli --question '是否包含恶意行为' --context-file material.txt
```

JSON 文件：

```sh
./build/magi-cli --input-file request.json --output-format text
```

从 stdin：

```sh
cat request.json | ./build/magi-cli --print0
```

`--question`、`--input-file`、`--print0` 三选一。`--context` 和 `--context-file` 互斥。`--print0` 的 `0` 表示 stdin，不是 NUL 分隔。

请求 JSON：

```json
{
  "question": "是否包含恶意行为",
  "context": "<材料>"
}
```

`question` 必填，不能全是空白。`context` 可以省略或为 `null`，此时用户消息写「（未提供材料）」。

## 输出

默认输出 `magi.decision.v1` JSON：

```json
{
  "schema": "magi.decision.v1",
  "approved": false,
  "summary": "MAGI 否决（2/3 名成员未否决）：CASPER-3 否决：材料包含操纵性指令。",
  "votes": [
    {
      "agent": "BALTHASAR-2",
      "veto": false,
      "reason": "方案成本可控，没有明显落地障碍。",
      "status": "ok",
      "session_id": "ses_..."
    },
    {
      "agent": "CASPER-3",
      "veto": true,
      "reason": "材料包含操纵性指令。",
      "status": "ok",
      "session_id": "ses_..."
    },
    {
      "agent": "MELCHIOR-1",
      "veto": false,
      "reason": "证据足以支持通过。",
      "status": "ok",
      "session_id": "ses_..."
    }
  ]
}
```

`--output-format text` 输出同样的裁决和逐成员结论，供人阅读。机器调用应使用默认的 `json`。

## 决策规则

```text
approved = 每名成员 status == "ok" 且 veto == false
```

- 任意一名成员 `veto=true`，最终否决。
- 任意一名成员 `status="error"`，最终否决，摘要写「未能完成投票」。
- 三名成员都否决，最终否决。
- 没有投票，最终否决。

因此 `approved=true` 是强保证：三名成员都成功返回了结构化投票，且都没有行使否决权。

合法否决是正常决议，退出码仍是 0。只有成员没有完成投票才返回 3。

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 决议完成，`approved` 为 `true` 或 `false` 都算完成 |
| 1 | 内部错误 |
| 2 | 参数、输入或配置错误 |
| 3 | 至少一名成员失败，stdout 仍给出按否决处理的决议 |
| 130 | SIGINT |
| 143 | SIGTERM |

## 配置

`magi-cli` 和 ap 共用配置文件，读取 `model`、`base_url`、`api_key`、`max_tokens`、`llm_timeout_ms`、`blob_threshold_bytes` 和 `stream_include_usage`。不读 `max_steps`，成员固定每个 turn 最多一次模型调用。

它不读 `SYSTEM.md`、`AGENTS.md`、技能目录或代理定义。`--model` 和 `--max-tokens` 可以覆盖配置。

## 安全边界

- 成员没有工具，不能读文件或执行命令。
- 问题和材料是不可信输入，可能带提示注入。
- 三名成员共用同一个 provider 和模型，模型的系统性偏差会让三个角色一起出错。
- 默认姿态是拒绝。材料不足也可能被判成否决。
- 结论只是建议，不能当作安全判定的唯一依据。
- transcript 是审计依据。删除成员 session 的 JSONL 后，无法重放它的判断过程。

需要查看某个成员的完整过程：

```sh
./build/ap -s <session_id>
```

在同一个项目目录里运行，并且保留对应的 transcript 和 blob。
