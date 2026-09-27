# App(应用入口与生命周期)

## 职责
进程入口、`NSApplicationDelegate` 生命周期、主菜单栏、把 Ghostty 快捷键翻译成 Seperate 的分栏/Tab 操作,以及 Sparkle 应用内更新。
不管:业务状态(在 `Store`)、窗口内容与侧栏(UI 模块)、终端渲染(terminal 模块)、磁盘/git/数据库(core 模块)。

## 文件清单与关系
- `Sources/Workbench/App/main.swift` — 进程入口,创建 `NSApplication` + `AppDelegate` 并 `run()`
- `Sources/Workbench/App/AppDelegate.swift` — 启动顺序、菜单栏、菜单项校验、Ghostty 动作 → 布局映射、DEBUG 演示钩子
- `Sources/Workbench/App/ShotRenderer.swift` — 官网截图模式(仅 DEBUG):`--render-shots <目录>` 时由 `main.swift` 进入,不走 `AppDelegate`,用演示项目搭出真实窗口并渲染成 PNG
- `Sources/Workbench/App/Updater.swift` — Sparkle 封装(单例 `Updater.shared`),后台检查结果以顶栏药丸呈现
- 调用关系:`main → AppDelegate → GhosttyRuntime.start / MainWindowController / Store.refresh / Updater.start`;菜单 action → `Store`;`Updater → Sparkle → GitHub Release 上的 appcast.xml`

## 数据流
- 启动:`applicationDidFinishLaunching` 依次 `GhosttyRuntime.shared.start()` → 挂 `onSurfaceAction` → 装菜单 → 显示主窗口并 `workspace.sync(structure: true)` → `store.refresh()` → `Updater.shared.start()`,最后起一个 60 秒的 `store.refresh()` 定时器。
- 快捷键:聚焦的终端先拿到 ⌘D/⌘T/⌘1… → Ghostty 把它变成 action → `GhosttyRuntime` 先给 `TerminalView.handle`,没处理的走 `onSurfaceAction` → `AppDelegate.handleTerminalShortcut` 映射到 `store.splitFocused / newShellInFocusedPane / closeTab / focusPane`。
- 更新:Sparkle 找到更新 → user driver delegate 回调 `setPending(version)` → 发 `Updater.changed` 通知 → `TopBarView` 显示药丸 → 点击调 `Updater.shared.checkForUpdates()` 弹 Sparkle 标准对话框。
- 退出:`applicationWillTerminate` → `store.shutdown()`;关掉最后一个窗口即退出。

## 对外接口
- `Updater.shared`:`start()`、`checkForUpdates()`、`canCheckForUpdates`、`automaticallyChecks`、`automaticallyDownloads`、`pendingVersion`
- 通知 `Updater.changed`(`dev.seperate.updater.changed`),`TopBarView` 订阅
- 菜单 selector(`@objc` 方法)是菜单栏与 `Store` 之间的唯一胶水;编辑菜单直接指向 `TerminalView.copy/paste` 走响应链

## 注意事项
- **单窗口应用**:Ghostty 的 `NEW_WINDOW` / `TOGGLE_FULLSCREEN` / `CLOSE_WINDOW` 被吞掉(返回 true),不要改成交给 Ghostty 处理,否则会冒出 Ghostty 自己的窗口逻辑。`GOTO_TAB` 在这里语义是"聚焦第 N 栏",不是 Tab。
- **快捷键冲突**:⌘K / ⌘P 在菜单里是命令面板;`TerminalView.performKeyEquivalent` 专门放行这两个(Ghostty 默认 ⌘K 是清屏)。新增菜单快捷键时要检查是否被终端绑定抢走。
- **全部 `@MainActor`**:`AppDelegate`、`Updater` 都是主线程类型;Sparkle 的 delegate 回调声明为 `nonisolated`,内部用 `MainActor.assumeIsolated` 回主线程——前提是 Sparkle 在主线程回调,别在这里引入后台队列。
- **Sparkle 配置在打包脚本里**:`SUFeedURL`、`SUPublicEDKey`、`SUEnableAutomaticChecks`、`SUScheduledCheckInterval=31536000` 由 `scripts/build-app.sh` 写进 Info.plist。Sparkle 自带定时器因此实际上关闭;检查只在启动时(静默)和"检查更新…"时发生。
- **`swift run` 无更新**:没有 `SUFeedURL` 时 `isBundled == false`,所有更新入口都是 no-op;DEBUG 构建启动时不自动检查,只有手动"检查更新…"才会 `startUpdater()`。
- **后台检查不抢焦点**:`standardUserDriverShouldHandleShowingScheduledUpdate` 返回 false + `supportsGentleScheduledUpdateReminders`——更新绝不能弹窗盖住正在跑的终端。
- **"自动下载并安装"菜单项**只有在"启动时检查更新"开启时才可用(`validateMenuItem`)。
- **DEBUG 演示钩子**:`WORKBENCH_DEMO` 环境变量下监听分布式通知 `dev.seperate.debug`(`ws:N` / `toggle:` / `rows`)并自动开三栏 shell;演示实例使用独立数据库(见 `Store.dbURL`),仅开发用,Release 不编译。
- **截图模式(`scripts/render-shots.sh`)**:独立进程 + 临时数据目录 + `SEPERATE_SHOTS_ROOT`(`Core` 只返回该目录下的会话和项目),窗口从不上屏(放在最高分辨率的屏幕坐标上以得到 2x)。截图是 App 把自己的视图渲染成位图:AppKit 视图用 `cacheDisplay`,终端读 Ghostty 的 IOSurface(`TerminalView.renderedImage()`),浮层面板另外补画 layer 背景 / 表格行 / 可编辑输入框 / 图片(`cacheDisplay` 不画这些)。不是屏幕截图,所以不会触发屏幕录制权限。agent 首次在演示目录恢复会话时的「信任此目录」提示由渲染器选中 Yes 再回车(Claude 默认选项是 "No, exit")。收件箱状态没有 hook,由 `Store.shotsSetPhase` 摆出。截图模式下 Ghostty 额外叠加 `font-size = 15`(`GhosttyRuntime.extraConfig`,写到单独的配置文件,不影响正在运行的 App),Claude 按次加 `--settings` 关掉状态栏;局部功能图把该部分按 4x 重绘后放大居中,背后是模糊的整窗。官网首页目前改用网页还原的界面卡片(`website/src/components/feature-cards.tsx`),截图模式保留给 OG 图等需要真实界面的地方。计划见 [docs/plans/2026-09-27-render-shots.md](../../plans/2026-09-27-render-shots.md)。
- 调试/开发时不要随意退出或重启正在运行的 Seperate(本仓库约定)。
