# 9. 命令行一次性使用

`ap` 本体是一次性程序：一条提示词进，一个 turn 出，然后退出。它没有 REPL，也不会停在提示符等你输入下一句。

适合这些场景：

- 问一句就走。
- 把结果交给脚本。
- 批量处理多个任务。
- 作为子代理被父进程调用。

## 三种输出格式

```sh
./build/ap --print "解释这个函数" --output-format text
./build/ap --print "解释这个函数" --output-format json
./build/ap --print "解释这个函数" --output-format stream-json
```

| 格式 | stdout | 适合 |
| --- | --- | --- |
| `text` | 最后一条含文本的 assistant 消息 | 人看 |
| `json` | 单个结果对象 | 脚本读取结果和状态 |
| `stream-json` | 每行一个事件 | 前端、集成、实时消费 |

默认是 `text`。

## json 结果

```json
{
  "session_id": "ses_...",
  "result": "最终答案",
  "stop_reason": "stop",
  "num_steps": 2,
  "usage": {
    "input_tokens": 0,
    "output_tokens": 0,
    "cached_tokens": 0,
    "reasoning_tokens": 0,
    "total_tokens": 0
  },
  "handoff": null
}
```

字段没有值时写 `null`，不要用 0 冒充真实值。发生交接时 `handoff` 会带上新 session id、交接正文和这次调用的 usage。

## stream-json

每行一个 JSON 对象。持久事件带 `v`、`seq`、`ts`、`type`，流式增量不带。常见事件包括：

- `session_start`：会话开始，带冻结的模型和 agent。
- `message_update`：文本或工具参数的增量。
- `tool_execution_start`、`tool_execution_update`、`tool_execution_end`：工具过程。
- `turn_end`、`session_end`：本轮和会话结束。

如果你不是在写前端或集成，用 `text` 或 `json` 就够了。事件字段属于程序接口，不是人读格式。

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 正常结束，包括 `max_steps`、`max_tokens`、`handoff` |
| 1 | 内部错误 |
| 2 | 用法或配置错误 |
| 3 | 模型接口错误，或关闭交接后的上下文超限 |
| 4 | 工具基础设施故障 |
| 130 | Ctrl+C 或 SIGINT |
| 143 | SIGTERM |

退出码 0 不代表模型正常说完。脚本要结合 `stop_reason` 判断。

## 在脚本里用

```sh
result=$(./build/ap --print "只回答 OK" --output-format json)
printf '%s\n' "$result"
```

把 stdout 交给下游解析。不要把 stderr 合并进 stdout：

```sh
# 不要这样
./build/ap --print "..." --output-format json 2>&1 | parser
```

合并后，进度和错误会混进 JSON，解析会失败。需要日志时单独重定向：

```sh
./build/ap --print "..." --output-format json >result.json 2>run.log
```

## 参数书写规则

- 带值的长参数支持 `--flag value` 和 `--flag=value`。
- `-s` 和 `-p` 只接受分开的值，例如 `-p "..."`。
- `--` 和位置参数会被拒绝。
- 提示词必须来自 `--print`、`--input-file`、`--print0` 之一。
- ap 不会隐式读取 stdin。需要从管道传入时写 `--print0`。

## 常用组合

```sh
# 从文件读提示词
./build/ap --input-file task.md

# 从管道读提示词
cat task.md | ./build/ap --print0

# 恢复会话并输出 JSON
./build/ap -s ses_... --print "继续" --output-format json

# 限制步数，失败就停
./build/ap --max-steps 10 --print "调查这个报错" --output-format json
```

下一章讲终端界面。
