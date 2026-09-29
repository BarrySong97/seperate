# Terminal(libghostty 终端宿主)

## 职责
在 AppKit 里托管 libghostty:一个全局 app 实例 + 每个运行中会话一个 surface(pty + GPU 渲染),负责键盘/IME/语音输入/鼠标/剪贴板与 Ghostty 回调路由。
不管:会话生命周期与布局(`Store` / Layout)、启动哪个 agent 命令(`AgentHooks`)、分栏/Tab 语义(`AppDelegate`)。

## 文件清单与关系
- `Sources/Workbench/Terminal/GhosttyRuntime.swift` — 单例,`ghostty_init` / 配置加载 / `ghostty_app_new`,C 回调分发,剪贴板读写
- `Sources/Workbench/Terminal/TerminalView.swift` — 一个 surface 的 NSView:懒启动、尺寸同步、键鼠事件、`NSTextInputClient`、辅助功能
- 调用关系:`AppDelegate → GhosttyRuntime.start`;`Store → TerminalView(init/destroy)`;`libghostty → GhosttyRuntime 回调 → TerminalView.handle → (未处理) onSurfaceAction → AppDelegate`
- GhosttyKit 来自 `Vendor/GhosttyKit.xcframework`,由 `scripts/setup-ghostty.sh` 从上游 Ghostty 固定 commit 编译

## 数据流
- 配置:用户自己的 Ghostty 配置(默认文件 + recursive)先加载,再叠加 `Theme.ghosttyConfig`(写到临时文件 `workbench-ghostty.conf` 后 load),诊断信息只打 NSLog。
- 输入:`keyDown` → 按 Ghostty 的 translation mods 重建事件 → `interpretKeyEvents`(IME 走 `insertText`/`setMarkedText` 累积)→ `ghostty_surface_key`。非 ⌘ 键同时触发 `onUserInput`。
- 输出事件:Ghostty action(标题、pwd、响铃、OSC 9/777 桌面通知、命令结束、鼠标形状、打开 URL)→ `TerminalView` 的 `onTitle/onPwd/onAttention/onNotify/onCommandFinished` 回调 → `Store`。
- 关闭:Ghostty `close_surface_cb` → `surfaceRequestedClose` 异步 → `onClose(processAlive)` → `Store` 决定后调用 `destroy()`。
- 粘贴:`pasteText` 把 Finder 文件变成转义路径、无文本的图片存为 PNG(`~/Library/Caches/Seperate/pastes/`)再粘贴路径,供 Claude Code / Codex 当附件。
- 拖放:`TerminalView` 只注册 `.fileURL/.png/.tiff`,从外部拖进来的文件 / 图片走同一个 `pasteText` 变成转义路径(末尾补空格),经 `ghostty_surface_text` 以粘贴方式送入;Tab / 分栏拖拽是纯字符串,不被终端截获,仍由后面的 `PaneView` 处理。

## 对外接口
- `GhosttyRuntime.shared`:`start()`、`app`、`onSurfaceAction`、`tick()`;静态 `pasteText(_:)`、`shellEscape(_:)`
- `TerminalView(sessionID:cwd:initialInput:env:)`、`destroy()`、`requestClose()`、`hasSelection`、`needsConfirmClose`(Ghostty 判断关掉会不会杀掉在跑的进程,批量关 Tab 用)、`copy/paste/selectAll`,以及上面列出的各 `on*` 回调和 `contextMenu`
- `GhosttyRuntime.extraConfig`:最后叠加的额外配置行(仅截图模式用来放大字号),非空时写到 `workbench-ghostty-shots.conf`,不覆盖正常运行时的配置文件
- 截图用(`ShotRenderer`):`visibleText()`(读屏幕文字,不产生选区)、`pressKey(_:text:)`(直接发给 Ghostty 的按键)、`renderedImage()`(Ghostty 最后一帧的 IOSurface)
- 环境变量:默认给 shell 注入 `WORKBENCH_SESSION=<sessionID>`(传入自定义 env 时以传入为准)

## 注意事项
- **线程**:所有 `ghostty_*` 调用必须在主线程;只有 `wakeup_cb` 在后台到达,它只做 `DispatchQueue.main.async { tick() }`。其余回调用 `MainActor.assumeIsolated`,依赖 Ghostty 在主线程(tick 内)回调。
- **userdata 是 unretained 指针**:surface 的 userdata 和 macOS nsview 都是 `Unmanaged.passUnretained(self)`。`TerminalView` 释放前必须先 `destroy()`(`ghostty_surface_free`),否则回调会拿到悬垂指针。
- **不能在 Ghostty 回调里释放 surface**:`surfaceRequestedClose` 故意 `DispatchQueue.main.async` 再通知 `onClose`。
- **懒启动**:surface 只有在 view 进入窗口且尺寸 ≥ 40×40 后才创建;离屏启动会让 agent 首屏(Claude 欢迎框等)按占位宽度排版并永久挤在回滚区里。离屏时 `convertToBacking` 没有显示器缩放,`syncSize` 会跳过。
- **view 会被重新挂载**:同一个 `TerminalView` 在布局变化时 re-parent,不重建;`viewDidMoveToWindow` 负责 occlusion 与缩放同步。
- **C 字符串生命周期**:env / cwd / initial_input 用 `strdup` + `withCString` 包住 `ghostty_surface_new`,调用结束即释放;`ghostty_surface_read_selection` 的结果必须 `ghostty_surface_free_text`。
- **剪贴板策略**:多行等 Ghostty 标记为"不安全"的粘贴直接放行(agent 提示词本来就多行);程序通过 OSC 52 / Kitty 读剪贴板一律拒绝,需确认的写入直接跳过、不弹窗;selection clipboard 关闭。
- **快捷键优先级**:`performKeyEquivalent` 让终端绑定和所有 Ctrl 组合先于菜单栏,但 ⌘K / ⌘P 例外留给命令面板。右键默认弹 Seperate 菜单,⇧+右键才交给终端程序。
- **IME / 语音输入**:`selectedRange` 永远不能返回 `NSNotFound`(豆包语音、听写会丢字);零长度 range 时 `firstRect` 返回插入符而非方框(Ghostty #8493)。非按键期间提交的文本以"按键带文本"发送而非粘贴,TUI 才会当作输入。辅助功能角色设为 `textArea` 也是为语音工具。
- **libghostty 版本**:上游 Ghostty 固定到某个 commit(v1.3.x 需要的 Zig 0.15 无法链接 macOS 26 SDK),升级需同步检查 C API 变化。
