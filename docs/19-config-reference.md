# 19. 配置项速查

配置文件是：

```text
$AP_CONFIG/settings.json
```

或：

```text
$AP_CONFIG/settings.jsonc
```

`$AP_CONFIG` 默认是 `~/.ap`。两个文件同时存在时只读 `.jsonc`。内容按 JSON5 解析，支持 `//` 注释、尾逗号和单引号字符串。

## 全部字段

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `model` | 无，必填 | 模型 id |
| `base_url` | 官方地址 | 兼容 OpenAI chat completions 的接口地址 |
| `api_key` | 无 | API key；可由 `AP_API_KEY` 覆盖 |
| `max_steps` | `100` | 单个 turn 的最大 step 数 |
| `max_agent_depth` | `1` | 子代理最大嵌套深度 |
| `max_tokens` | `65536` | 单次响应的输出上限 |
| `tool_timeout_ms` | `120000` | `bash` 默认超时 |
| `llm_timeout_ms` | `600000` | 单次 LLM 请求总超时 |
| `blob_threshold_bytes` | `102400` | 超过此字节数写 blob |
| `max_capture_bytes` | `67108864` | 单次工具输出硬上限，默认 64 MiB |
| `image_input` | `false` | `read_file` 是否返回图片附件 |
| `image_max_bytes` | `5242880` | 单张图片上限，默认 5 MiB |
| `stream_include_usage` | `true` | 是否请求流式 usage |
| `context_window_tokens` | `1048576` | 模型上下文窗口；`0` 关闭预算 |
| `context_reserve_percent` | `5` | 余量占窗口的百分比，取值 0 到 100 |
| `handoff_max_tokens` | `16384` | 生成交接文档那次调用的输出上限 |

## 规则

1. `model` 必填。即使命令行传了 `--model`，配置文件里仍要有 `model`。
2. `api_key` 可以由 `AP_API_KEY` 覆盖。两处都没有时退出 2，`--print-system-prompt` 除外。
3. `base_url` 缺省为官方地址。末尾斜杠会被去掉，空值报错。
4. 未知字段忽略并 warning。类型错误或非法取值退出 2。显式 `null` 按缺失处理。
5. 整数字段接受整数值的浮点数，例如 `100.0`。
6. `max_steps`、`max_tokens`、两个超时和三个尺寸上限必须为正。
7. `max_agent_depth` 必须非负。
8. `context_window_tokens` 必须非负。`0` 表示不设预算。
9. 非零窗口必须大于 `max_tokens` 和 `handoff_max_tokens`，并且 `max_tokens + reserve` 必须小于窗口。

`reserve` 的计算方式是：

```text
reserve = context_window_tokens * context_reserve_percent / 100
```

默认值下：

```text
reserve = 1048576 * 5 / 100 = 52428
target  = 1048576 - 65536 - 52428 = 930412
```

`target` 是输入侧预算。接近它时 ap 开始省略较早的工具结果。

## 上下文相关字段怎么配合

- `max_tokens` 是单次响应的天花板，不是整个 turn 的总量。
- `context_window_tokens` 是模型能力声明，也是预算计算的输入。
- `context_reserve_percent` 是给本地 token 估算误差留的余量。设为 `0` 表示不留。
- `handoff_max_tokens` 是生成交接文档那次调用的上限，和 `--max-tokens` 无关。
- `context_window_tokens = 0` 时，另外两个上下文字段不参与计算。

窄窗口模型可以这样配：

```json
{
  "model": "your-model",
  "max_tokens": 4096,
  "context_window_tokens": 32768,
  "context_reserve_percent": 5,
  "handoff_max_tokens": 4096
}
```

## 图片

```json
{
  "image_input": true,
  "image_max_bytes": 5242880
}
```

开启后，`read_file` 才会把 PNG、JPEG、GIF、WebP 作为图片附件交给模型。文本模型保持关闭，避免请求被拒绝。ap 不缩放、不转码，只做原样透传。

## 超时与尺寸

- `tool_timeout_ms` 是 `bash` 的默认超时。单次调用可以用参数覆盖，上限 600000 毫秒。
- `llm_timeout_ms` 是单次 LLM 请求的总超时。
- `blob_threshold_bytes` 决定多大的工具结果写 blob。
- `max_capture_bytes` 是单次工具输出的硬上限。超过时工具失败，不做静默截断。

## 示例文件

仓库根目录的 [settings.example.json](../settings.example.json) 列出了全部字段和默认值。可以复制它再修改。

修改后检查：

```sh
./build/ap --print-system-prompt --no-agents-md --no-skills
```

这条命令不调用模型，但会读取配置和模型字段。确认没有配置错误后，再发一条真实请求。
