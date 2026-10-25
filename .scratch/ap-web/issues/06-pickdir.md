# 06: Windows 目录选择对话框（IFileDialog COM）

**What to build:** Windows 上点击 UI「选择目录」弹原生目录选择框：`pickdir.odin` 手写最小 COM 绑定（CLSID FileOpenDialog，IFileDialog 只用 SetOptions/Show/GetResult/GetPath/Release 五个 vtable 方法，FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM），COM 在专用 STA 线程初始化（CoInitializeEx COINIT_APARTMENTTHREADED），Show(NULL) 阻塞到用户关闭，不占 HTTP 连接线程。用户确认 → GetResult→GetPath 拿绝对路径，ap-web `os.set_cwd` 更新并返回 200 {cwd}，下一次 turn 的 ap 子进程在新目录启动；运行中 turn 不受影响，运行中调 pick 返回 409 turn_running；用户取消 → 409 {error:{code:"cancelled"}}；同一时刻只允许一个 pick（409 picker_busy）；COM 失败返回 500 提示手输路径。Unix 保持 501。构建脚本与 build.ps1/build.sh 同步更新：探测 npx 有则先 npm --prefix ap-web run build 刷新 dist，无则用已提交 dist；`odin build ../ap-web -out:ap-web -vet` 加入全量构建，产物 bin/ap-web.exe；.gitignore 加 ap-web/node_modules/。

参考：docs/web.md「工作目录选择」「风险与对策（COM）」；笔记 internal-notes.md、build-notes.md；spec 明确平台文件 platform_windows.odin 存放平台差异代码。

**Blocked by:** 04（pick 路由与并发约束已定义）

**Status:** ready-for-agent
