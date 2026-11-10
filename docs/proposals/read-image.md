# 提案：read_file 图片输入

状态：已实现。正文已并入 [tools.md](../tools.md)、[context-management.md](../context-management.md)、[provider.md](../provider.md)、[react-loop-and-session.md](../react-loop-and-session.md)、[integration.md](../integration.md) 与 [cli-and-config.md](../cli-and-config.md)。

代码入口：`ap-cli/tools/tool_file.odin`、`ap-cli/settings.odin`、`ap-core/tool/tool.odin`、`ap-core/protocol/events.odin`、`ap-core/engine/loop.odin`、`ap-core/engine/context.odin`、`ap-core/engine/provider.odin`、`ap-core/engine/budget.odin`。

## 目标

让 `read_file` 在模型支持视觉输入时读取图片，而不是把图片当二进制文件拒绝。

## 决策

1. **opt-in**：`settings.json` 新增 `image_input`，默认 `false`。文本模型保持关闭，避免 provider 直接返回 400；`image_max_bytes` 限制单张图片，默认 5 MiB。
2. **原样透传**：只识别 PNG、JPEG、GIF、WebP 的魔数。不引入图像库，不缩放、不转码、不处理 EXIF。
3. **先写 blob**：`Tool_Result.images` 携带原始字节，引擎写 blob 后再追加 `tool_execution_end.images`。transcript 不存 base64，恢复和投影都从 blob 读。
4. **合成 user 消息**：OpenAI 兼容接口的 tool 消息通常只接受文本 part。provider 先发正常的 `role=tool` 文本消息，再把图片展开成紧随其后的合成 `role=user` 消息，内容是 text + `image_url` data URL。
5. **投影保持纯函数**：合成消息只在 provider 序列化时展开，`context_build` 仍然只依赖 transcript 与 project。
6. **预算按张估算**：每张图片固定计 `ESTIMATE_IMAGE_TOKENS`，不按 base64 或原始字节估算。省略工具结果时同时清空图片。

## 非目标

- 不处理用户直接粘贴的图片或命令行图片输入。
- 不做 OCR、缩略图、格式转换或视觉模型路由。
- 不新增工具，也不改 `bash` 的图片能力。
- 前端不负责渲染图片；图片字段可选，旧前端忽略即可。

## 被否决的方案

- **图片直接放进 `role=tool` 的 content 数组**：OpenAI 官方 chat completions 的 tool content 只保证文本 part，跨兼容服务不可移植。
- **把 base64 写进 transcript**：体积大、恢复慢，也破坏 blob 去重。
- **默认开启**：文本模型收到图片 part 会直接拒绝请求，错误发生在模型调用层，排查成本高于显式开启。
- **自动缩放**：需要图像库和平台差异处理，与“不新增第三方库”的约束冲突。
