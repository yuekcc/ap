# TigerStyle 代码评审（2026-11）

按 [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md) 的 C/Odin 适配版评审全仓 Odin 生产代码，记录发现的问题与修改建议。本文是维护记录，不是规格：修完或决定不修之后，同步更新或删除对应条目。

评审对象是 169 个 `.odin` 文件、约 22.6k 行生产代码（不含 `*_test.odin`、`testdata/`、`ap-web/dist/`），分五个面：`ap-core/engine`、`ap-core/{platform,protocol,tool,client,sdk}`、`ap-cli`、`ap-web`、`lineedit`+`ap-tui`+`magi`。

## 总体结论

骨架健康：错误是值、退出码集中映射、进程启动与清理收在 `run_child` 一处，事务纪律（transcript 只追加、`context_build` 纯函数、blob 先写后引用）都守住了。

问题集中在三类系统性缺口：

1. **不可信输入缺少硬上限**——子进程输出、SSE、stdin、HTTP 请求都能驱动无界增长或无界等待。
2. **静默吞错**——全仓 45 处 `_ = fallible_call()`，其中一部分是真实错误被当成成功。
3. **零 `assert` / `#assert`**——编程错误全靠“下一个人别写错”，没有正负空间双向断言。

严重度定义：**P0** 产出错误结果、挂死或损坏无关资源；**P1** 资源泄漏、DoS 面、可观测性缺口；**P2** 风格与可维护性。

## 修复状态

以下条目已修复并补了回归测试（或同步更新了规格）：

- P0-1：web 每请求一个 arena；`turn_run` 自带 arena 并恢复调用方的 `context.temp_allocator`。见 [web.md](web.md)「请求级内存所有权」。
- P0-2：`Retry-After` 钳到 16 秒上限，退避按 100ms 分片检查取消；新增 `loop_test` 回归。
- P0-3：`run_child` 拒绝非正超时；`task` 使用新配置 `task_timeout_ms`（默认 30 分钟）。
- P0-4：`release_job` 只关闭注册表里的句柄；仍有后台进程时保留登记，`cleanup_jobs` 后拒绝新登记，避免句柄值复用导致的二次关闭。
- P0-5：`ap-tui` 安装 SIGINT/SIGTERM（Windows 为 Ctrl+C/Break），Ctrl+C 取消当前 turn；`run` 退出时 `cleanup_jobs`；Job 设置 `KILL_ON_JOB_CLOSE`。
- P0-6 / P1-10：`loop_finish_turn` / `loop_try_write_turn_end` 统一收尾；可报告路径的 `turn_end` 写失败变成 `fatal_error`，取消路径记日志；所有退出点都填 `usage` 与 `session_usage`。
- P1-1：请求总期限 15 秒（超时 408）；并发连接上限 256，超限直接关闭。
- P1-2：`/api/history` 增加 `since_seq` / `limit` / `truncated`，默认返回最新 1000 条、上限 5000 条或 8 MiB；session 摘要按 transcript mtime/size 缓存。
- P1-3：`Content_Block` 数组、tool call `input` 树、canonical JSON 中间量、Job 句柄都已回收。
- P1-4：新增 `MAX_EVENT_LINE_BYTES`、`SSE_MAX_EVENT_BYTES`、`MAX_PIPE_LINE_BYTES`、`MAX_PROMPT_BYTES`（均 8 MiB）与对应错误路径。
- P1-5：stdout 写失败映射成退出码 1；JSON 编码失败记日志并置 fatal；`session_close` 失败不再静默；Windows 路径长度按返回值校验；raw mode 恢复失败会诊断；`ap-tui` 写失败不再更新渲染器状态。
- P1-6 / P1-9：心跳线程检查创建结果并在关停时 join；目录选择线程 join 后销毁。
- P1-7：需要值的参数拒绝以 `-` 开头的下一个 argv；重复参数报用法错误。
- P1-8：stdin 临时文件只落平台临时目录，`.Excl` 创建，失败即报错。
- P2-1 / P2-4 / P2-5：补了关键断言与 envelope 字段顺序的编译期断言；常量与字段统一单位后缀；blob 判定收敛到 `content_or_blob`。

暂不处理（记为后续工作）：

- P2-2 行宽：尚未引入 100 列检查，schema 字面量也没有手工折行。
- P2-3 `_ =` 收敛：仍保留 26 处；本轮只处理了 turn 收尾、输出通道和 `session_close` 这些会改变结果的点。
- P2-6 拆分 `loop_run_turn`：退出点已统一，但函数体尚未拆成 `loop_step`。

## P0：会产出错误结果或挂死

### P0-1 请求级 temp arena 被 turn 泵重置

- 位置：`ap-web/server.odin:577-580`、`ap-web/api.odin:805-812`、`ap-web/runner.odin:790`、`ap-core/client/turn.odin:102/119/128`
- 问题：`serve_connection` 用 `context.temp_allocator` 分配 `response.headers` 和请求字段；`/api/session/title` 在同一个连接线程里同步跑 `client.turn_run`，而 turn 泵每读一行就 `free_all(context.temp_allocator)`。handler 返回后，`api_json` 在同一 arena 上重新分配并可能复用这块内存，`response_set_header` 随后读写的是已释放的 `Http_Header`，响应头会被 JSON body 的碎片覆盖。
- 建议：`serve_connection` 每请求建一个 `runtime.Arena`，把 `arena.allocator` 显式传给 handler，响应写完后 `arena_destroy`；`response.headers`、请求解析结果都从该 arena 分配。turn 泵只重置自己持有的 arena。在 [web.md](web.md) 增一节「请求级内存所有权」，写明「handler 内调用的库不得 `free_all(context.temp_allocator)`」。

### P0-2 `Retry-After` 绕过退避上限，且 sleep 不可取消

- 位置：`ap-core/engine/loop.odin:879-891`（`retry_after_ms` 来自 `ap-core/engine/provider.odin`）
- 问题：`delay` 先钳到 16000ms，随后 `if retry_ms > 0 { delay = retry_ms }` 直接覆盖；`l.sleep_fn(delay)` 默认是 `time.sleep`。服务端回 `Retry-After: 3600` 就让 turn 静默假死一小时，取消键无效，同时违反「取消必须及时」与「不可信输入必须有硬上限」。
- 建议：`delay = min(delay, RETRY_DELAY_MS_MAX)`；把 `sleep_fn` 换成按 100ms 分片的 `loop_sleep_cancellable`，每片检查 `cancel_token_cancelled`，命中后走既有 cancelled 分支。补回归测试：假 provider 返回 `Retry-After: 3600`，取消令牌在 100ms 内置位，断言 turn 在 1s 内返回且 `stop_reason == cancelled`。

### P0-3 `task` 子代理没有墙钟上限

- 位置：`ap-cli/tools/tool_task.odin:261`、`ap-cli/tools/process.odin:233/258`
- 问题：`task` 传 `timeout_ms = 0`，而 `run_child` 的超时判断是 `opts.timeout_ms > 0 && ...`，0 等价于无限。主循环唯一出口是子进程退出、取消或输出超限，子代理卡住时整个 turn 静默挂死。
- 建议：`run_child` 对 `timeout_ms <= 0` 直接返回错误（0 不再表示“无界”）；`task` 的墙钟上限从 settings 读（如 `task_timeout_ms`，默认 30 分钟），超时按工具失败返回。新参数要同步 `settings.example.json`、[tools.md](tools.md)、[cli-and-config.md](cli-and-config.md)。

### P0-4 `release_job` 会二次 `CloseHandle`

- 位置：`ap-core/platform/process_windows.odin:63-77`、`:79-87`
- 问题：`release_job` 无论 job 是否还在 `running_jobs` 里都执行 `CloseHandle`，而 `cleanup_jobs` 已经关闭并 `clear` 了同一批句柄。ap-web 关停超时后 `ap-web/main.odin:313` 仍会调 `cleanup_jobs`，随后 turn 线程的 `defer release_job` 会关掉一个已被回收的 HANDLE——可能命中同一进程里别人的 socket、文件或管道。
- 建议：句柄所有权只归注册表。`release_job` 命中列表才移除并 `CloseHandle`，未命中直接返回；`cleanup_jobs` 清列表时置位“已回收”标记。`process_unix.odin` 的对应实现同步检查一遍。

### P0-5 `ap-tui` 的取消路径是断的

- 位置：`ap-tui/input.odin:8-12`、`ap-tui/main.odin` 的 `run`、turn 调用点
- 问题：`input.odin` 注释写明「turn 期间恢复 cooked mode，Ctrl+C 仍是内核 SIGINT」，但 `ap-tui` 没装信号处理、没给 `Turn_Options.cancel`、也从不调 `client.cleanup_jobs()`（全仓只有 `ap-cli/run.odin:270`、`ap-web/main.odin:313` 调用）。Ctrl+C 直接用默认动作杀掉 ap-tui，子 `ap` 进程树残留——Windows 的 job 没有 `KILL_ON_JOB_CLOSE`，主进程一死句柄只是关闭，不终止子进程。
- 建议：装 SIGINT/SIGTERM handler，置 `platform.Cancel_Token` 并传给 `Turn_Options.cancel`；`run` 里 `defer client.cleanup_jobs()`；Windows 上给 job 设 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 兜底。同步 [tui.md](tui.md) 的取消语义与 [errors-and-cancellation.md](errors-and-cancellation.md)。

### P0-6 正常终止路径上 `turn_end` 写失败被当成功

- 位置：`ap-core/engine/loop.odin:946`；同类：`:729`、`:1045`、`:1098`，以及取消路径 `:555/556/666/719/900`
- 问题：`_ = loop_write_turn_end(l, stop_reason)` 之后照常返回 result。磁盘满或 IO 错误时 transcript 缺尾行（使用量与上下文快照丢失），调用方认为一切正常，违反「transcript 是唯一事实来源」。
- 建议：二分处理。正常/终止路径改成 `or_return` 到 `result.fatal_error`；确实无法再报告的收尾路径（例如已经在写取消事件时）收敛成 `try_write_*` 包装，函数名和注释写明「失败只能记日志，turn 已在终止」，并真的 `log_error` 一次。

## P1：泄漏、DoS 面与可观测性

### P1-1 `ap-web` 连接与超时没有总账

- 位置：`ap-web/main.odin:499`、`ap-web/server.odin:543-556`
- 问题：每 accept 一个线程、无并发上限；读超时按**每次 recv** 重置（空闲 30s / 请求体 10s）而不是请求总期限，每 9 秒发 1 字节即可长期占住线程与句柄。
- 建议：记录请求起始 tick，设总截止时间（超时即 408 或直接关闭）；连接数用信号量或固定 worker 池，超限回 503 并只读地丢弃连接。

### P1-2 `/api/history` 无分页，侧栏全量解析

- 位置：`ap-web/api.odin:533-571`、`:442`（`session_transcript_summary`，`:487-520`）
- 问题：整份 transcript 读入、逐行 `json.parse_string`、blob 全文（`content`/`text`/`input`）再塞进 temp；`/api/projects` 为每个 session 全量解析 transcript 只为数 turns 和找标题，而前端每轮 turn 后都会拉一次侧栏。
- 建议：`/api/history` 加 `since_seq`/`limit` 与响应字节上限，超限降级为预览并返回 `truncated`；turns 与标题落进 session 元数据缓存，或只读 transcript 尾部窗口。

### P1-3 内存泄漏组

- `ap-core/engine/loop.odin:333`、`:498`：`make([dynamic]Content_Block, ...)` 没有对应 `delete`，每条 `message_end` / 取消消息漏一个数组。
- `ap-core/engine/loop.odin:248`：`loop_release_owned` 只释放 `id`/`name`；tool call 的 `input` 是 `json.parse_string` 用 `context.allocator` 建的树，全仓无人 `destroy_value`，泄漏量正比于历史 tool call 数（测试跑在 `ODIN_TEST_TRACK_MEMORY=false` 下看不见）。
- `ap-core/platform/json.odin:196-253`：`json_canonical_string` 每次都漏 `json_marshal_utf8` 的结果、`keys` 数组和 `strings.builder`；`json_arguments_string` 每个 tool call 都走这条路。
- `ap-cli/tools/process.odin:310`：每个子进程 `register_job`，但 `aptools` 从不 `release_job`（全仓只有 `ap-core/client/turn.odin:230` 释放），一次长 session 每个 bash/task 调用泄漏一个 Job 句柄。
- 建议：补 `defer delete(...)`；`input` 在 `loop_release_owned` 里 `json.destroy_value`，`assembler_finish` 的提前返回路径同样处理；`json_canonical_string` 改成写入调用方 builder，或在注释里写明返回值归谁；`run_child` 在关闭管道后对已结束的 job 调 `release_job`。

### P1-4 不可信输入缺少硬上限

- `ap-core/protocol/line_reader.odin:22-52`：只按 `\n` 切分，没有单行上限，子进程吐一条永不换行的输出即可撑满内存。
- `ap-core/engine/sse.odin:79/94`：`SSE_MAX_LINE` 只保护行缓冲，`p.data` 会跨行累加，只发 `data:` 行、从不发空行的流可以无限增长。
- `lineedit/line_editor.odin:637`：`read_pipe_line` 的 `pipe_buf` 无上限，管道输入不出现换行时无限增长。
- `ap-cli/options.odin:431`、`ap-web` 与 `magi/options.odin:212`：三份 `read_all_stdin` 都是无上限 `[dynamic]byte`；`--input-file` 走 `read_entire_file`，同样无上限。
- 建议：分别引入 `MAX_EVENT_LINE_BYTES`（8 MiB）、`SSE_MAX_EVENT_BYTES`、`max_input` 与 `MAX_PROMPT_BYTES`，超限返回显式错误而不是继续追加。上限值写进 [integration.md](integration.md) 和 [tools.md](tools.md)。

### P1-5 静默吞错组

- `ap-cli/output.odin:20-22/208-213/245-250`：`json_marshal_utf8` 失败直接 `return`，stdout 少一整条事件，退出码仍为 0。同时 `output_text_delta`/`output_reasoning_delta`（`:46`、`:54`）漏了 `output_tool_update`（`:137`）有的 `sanitize_utf8`。
- `ap-cli/app.odin:45`：`write_stdout` 返回 `bool`，调用点全在忽略（`run.odin:230/260/290/317`、`output.odin:24-25`、`app.odin:119`）。stdout 关闭时 ap 仍返回 0。
- `ap-cli/run.odin:258/359/470`：`session_close` 的错误用 `_` 丢弃且无注释；失败时 `stream-json` 没有 `session_end`，恢复侧会当成异常退出。
- `ap-core/platform/platform_windows.odin:37-40`：第二次 `GetFinalPathNameByHandleW` 失败时返回的是所需缓冲区长度，代码只判 `n == 0`，随后 `buf[:n]` 可能越界 panic。
- `lineedit/term_windows.odin:116-127`：`leave_raw` 丢弃 `SetConsoleMode` 的返回值，恢复失败时终端留在 raw 模式且无人知道；`line_editor_leave_raw` 仍然把 `le.raw` 置 false，之后不会再重试。
- `ap-tui/render.odin:37/45`：`_ = client.write_all(...)` 吞掉写失败，且无论成功与否都更新 `at_line_start`，渲染器状态与真实输出永久分叉。
- 建议：机器通道上的失败必须变成非零退出码（置 fatal 标记，退出前映射成 `Exit_Code.Internal`）；确有“尽力而为”语义的忽略，统一加注释写理由；`buf[:n]` 前加长度判断；raw mode 恢复失败至少写一条 stderr 诊断，并且只在成功时清 `le.raw`。

### P1-6 `ap-web` 心跳线程持有栈上的状态

- 位置：`ap-web/runner.odin:810-844`、`ap-web/main.odin:370`
- 问题：`Heartbeat_State` 在 `run()` 的栈上，`heartbeat_stop` 只置标志不 join；线程在 sleep 期间仍会读这块栈。`thread.create_and_start*` 的返回值也被 `_ =` 吞掉，创建失败则 Ctrl+C 关停路径失效。
- 建议：检查创建返回值并在失败时报错退出；保存句柄，在关停时 join 之后再让栈帧返回。

### P1-7 `ap-cli` 参数解析的负空间

- 位置：`ap-cli/options.odin:415-429`、`:181`
- 问题：`option_value` 无条件取下一个 argv，`ap --model --debug` 会把 `--debug` 当 model 值吞掉；重复参数（`-s a -s b`）后者静默覆盖；`--handoff` 已经按 `-` 前缀判断，两处策略不一致。
- 建议：需要值的选项遇到以 `-` 开头的下一个 argv 时报 Usage 错误；对已设置的 `Maybe` 字段拒绝重复并给出明确提示。

### P1-8 stdin 临时文件落在 cwd

- 位置：`ap-cli/tools/process.odin:96-105`
- 问题：`TEMP` 缺失时回落到 cwd，把 `.ap-stdin-*` 写进正在被 agent 编辑的仓库；文件名可预测且 `write_entire_file_from_bytes` 无 `.Excl`，会静默截断同名文件；子代理 prompt 全量明文落盘。
- 建议：只使用平台临时目录，创建用 `.Excl`，失败即报错，不回落 cwd；用完在 `close_child_pipes` 同一作用域删除。

### P1-9 线程句柄未销毁

- 位置：`ap-web/pickdir.odin:81-85`
- 问题：非 `self_cleanup` 的 `dir-picker` 线程 `join` 后没有 `thread.destroy(handle)`，每次选目录泄漏一个 `^Thread` 与平台线程句柄。
- 建议：`defer thread.destroy(handle)`（对照 `ap-web/runner.odin:107-108` 的正确写法）。

### P1-10 退出路径上 `usage` 与 `turn_end` 不一致

- 位置：`ap-core/engine/loop.odin:928-934`、`ap-cli/output.odin:242`
- 问题：取消分支只填 `session_usage`，漏了 `result.usage`，而 `output_final` 直接输出 `result.usage`。被取消的 turn 在 `stream-json` 里报 0 用量，与 transcript 的 `turn_end` 不一致。
- 建议：抽一个 `loop_exit(l, result, stop_reason)` 统一填 `usage`/`num_steps`/`session_usage`，12 个退出点全部走它。

## P2：风格与可维护性

### P2-1 全仓零断言

`assert` 与 `#assert` 都是 0 次（含测试）。建议从三处先加，都是“已经检查过、只差点破”的位置：

- `ap-core/engine/context.odin:383`：`end := results[call.id]` 距 `has_result` 检查 38 行，改成 `end, found := results[call.id]; assert(found)`。
- `ap-cli/tools/definitions.odin:81`：`switch info.name` 没有 `default`，新增第 6 个工具忘加 case 会得到 `execute = nil`，延迟到运行时才炸。改为 `assert(tool.execute != nil)`。
- `lineedit/editor.odin:45-55`：`editor_set_cursor` 静默 clamp 而不对齐 rune 边界，破坏文件头声明的“cursor 始终落在 rune 边界”不变量。

编译期关系也一条没有，例如 `#assert(size_of(Event_Header) ...)`、事件 `v` 常量与 schema 版本的一致性。

### P2-2 行宽

153 处非测试代码超过 100 列。`odin fmt` 不折行，所以现在没人管。最典型的是 `ap-cli/tools/definitions.odin:19-40`（工具 JSON schema，200–330 列）。建议：约定 100 列，schema 字面量手工换行，CI 加一条 `awk 'length > 100'` 检查（放 `tools/`）。

### P2-3 `_ =` 的收敛策略

45 处，24 处集中在 `loop.odin`。建议二分而不是逐条争论：**尽力而为的收尾**改名为 `try_*` 并写理由注释；**真错误**改成 `or_return`/显式分支。禁令只保留一条：新增代码里出现无注释的 `_ =` 一律 review 拒绝。

### P2-4 命名单位

`SSE_MAX_LINE`（字节）、`ap-web/server.odin` 的 `MAX_HEADERS`（计数）与 `MAX_HEADER_LINE`/`READ_CHUNK`（字节）、`lineedit` 的 `Row.len`（字节）与 `MAX_INPUT`、`history.max_len`（条数）。按“最重要的词在前 + 单位后缀”统一成 `SSE_MAX_LINE_BYTES`、`MAX_HEADER_COUNT`、`READ_CHUNK_BYTES`、`Row.len_bytes`。

### P2-5 重复的大内容转 blob 决策

`loop.odin:315/344/566/636`、`transcript.odin:428`、`handoff.odin:137`、`session.odin:336` 各自手写 `len > blob_threshold_bytes` 加 `ref`/`bytes`/`preview` 三件套，preview 写法已有细微差异。建议收敛成 `content_or_blob(store, bytes) -> (inline, ref, bytes, preview, Error)`，阈值只在 `Blob_Fields` 一处判断。

### P2-6 大函数

`loop_run_turn` 约 265 行、12 个几乎相同的退出点，已经漂移（见 P1-10）。按“push ifs up, fors down”把 step 循环体拆成 `loop_step`，状态仍由 `Loop` 持有。

## 已排除的误报

评审过程中有三条初判经回读代码后不成立，记在这里避免重复讨论：

- `ap-tui/render.odin:209` 的 `tool_end(r, ev.ok, err, ev.duration_ms, ev.exit_code)` 与签名顺序一致，没有传反。
- `ap-core/platform/blob.odin` 的 `.Excl` 并不构成并发竞争：临时文件名含 pid 与 nanotime，不会相撞；内容寻址下 rename 覆盖同一路径也无害。
- `strings.clone(...)` 在单值上下文使用不算吞错：标准库标了 `#optional_allocator_error`，与 `make` 同一设计。

## 建议的修复顺序

1. **第一批（P0-1、P0-2、P0-3）**：唯一会静默产出错误响应内容、唯一能让 turn 假死、唯一能让整轮挂死的三条。
2. **第二批（P0-4、P0-5、P0-6、P1-3）**：句柄所有权与错误传播，顺带把泄漏清掉，避免后面每个 PR 都要重新核对。
3. **第三批（P1-1、P1-2、P1-4、P1-5）**：上限与机器通道的可观测性。
4. **第四批（P1-6 至 P1-10、P2-x）**：生命周期细节、断言、行宽与命名。

每批完成时：

- 跑 `./test.sh` 与 `tools/check-deps.sh`；改过前端再跑 `npm --prefix ap-web test` 和 `npm --prefix ap-web run build`。
- 行为变更补回归用例：P0-2 用假 provider 的 `Retry-After`，P0-1 用带 header 的 `/api/session/title` 请求，P0-3 用启动后不退出也不输出的 fake agent，P1-3 用 `ODIN_TEST_TRACK_MEMORY=true` 跑一遍受影响的测试。
- 触及契约（取消、stdout、transcript、恢复）的条目，同时更新 [README.md](README.md) 的硬约束段与对应分篇。

## 附：统计口径

| 指标 | 数值 | 复现 |
| --- | --- | --- |
| 生产代码行数 | 22626 | `find . -name '*.odin' -not -name '*_test.odin' | xargs wc -l` |
| 非测试行超过 100 列 | 153 | `awk 'length($0) > 100'` |
| `_ =` 丢弃返回值 | 45 | `grep -E '^\s*_ = \w+\('` |
| `assert(` | 0 | `grep -rE '\bassert\('` |
| `#assert` | 0 | `grep -r '#assert'` |
| 非测试 `panic(` | 0 | 24 处全在测试里 |
