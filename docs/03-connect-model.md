# 3. 连接模型

ap 通过 OpenAI chat completions 兼容接口调用模型。你需要一个模型 id、一个接口地址和一个 API key。

## 配置文件放在哪

默认位置是：

```text
~/.ap/settings.json
```

也可以使用 `~/.ap/settings.jsonc`。`$AP_CONFIG` 可以改配置根目录，`--config-dir` 的优先级更高。

两个文件同时存在时，ap 只读 `.jsonc`，另一个既不合并也不校验。想保留注释就用 `.jsonc`。

## 最小配置

复制仓库里的示例：

```sh
mkdir -p ~/.ap
cp settings.example.json ~/.ap/settings.json
```

然后编辑这三项：

```json
{
  "model": "your-model",
  "base_url": "https://api.openai.com/v1",
  "api_key": "sk-your-key"
}
```

- `model` 必填。即使命令行传了 `--model`，配置文件里仍然要有 `model`。
- `base_url` 指向兼容 OpenAI chat completions 的地址。不写时使用官方地址。
- `api_key` 可以写在文件里，也可以由环境变量 `AP_API_KEY` 提供。环境变量优先。

配置文件按 JSON5 解析，所以 `//` 注释和尾逗号合法。它只用于读取，ap 不会回写。

## 用环境变量提供密钥

不想把 key 写进文件时：

```sh
export AP_API_KEY="sk-your-key"
```

ap 会用它覆盖 `settings.json` 里的 `api_key`。`bash` 工具执行命令前会剔除这个变量，避免把密钥交给模型可控的命令。

## 检查配置

先检查配置能否加载：

```sh
./build/ap --print-system-prompt --no-agents-md --no-skills
```

这条命令会打印本次使用的 system prompt，然后退出。它需要 `model`，但不需要 API key，也不会调用模型。看到完整提示词就说明配置文件和模型字段能被读取。

再做一次真实请求：

```sh
./build/ap --print "只回答 OK"
```

如果能返回 `OK`，说明地址、密钥和模型都通了。

## 模型需要什么能力

ap 依赖模型返回结构化的工具调用。选择模型时确认它支持 OpenAI 风格的 tool calls。只支持纯文本补全的模型无法可靠执行工具。

需要读取图片时，还要同时满足：

- 模型支持视觉输入。
- `settings.json` 中 `image_input` 设为 `true`。
- 图片是 PNG、JPEG、GIF 或 WebP，且不超过 `image_max_bytes`，默认 5 MiB。

## 常见配置错误

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 启动时提示模型未配置 | `model` 缺失或为空 | 在配置文件中补上 `model` |
| 启动时提示 API key 缺失 | 文件和 `AP_API_KEY` 都没有 | 补 `api_key` 或设置环境变量 |
| 401 或 403 | key 无效、过期或无权限 | 换 key，确认它属于当前接口 |
| 404 或模型不存在 | `base_url` 多了或少了路径，模型 id 不对 | 对照服务商文档检查地址和模型名 |
| 请求一直超时 | 网络、代理或接口不可达 | 检查网络；必要时调大 `llm_timeout_ms` |
| 模型不调用工具 | 模型不支持 tool calls | 换支持工具调用的模型 |

配置通过后，读 [第 4 章](04-first-run.md) 做第一次对话。
