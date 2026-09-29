# UI

## 职责
主窗口里除终端本身之外的全部界面：侧栏、顶栏、分栏/Tab 工作区、命令面板、导入面板、收件箱、右键菜单与各种 sheet/对话框。纯 AppKit（无 SwiftUI、无 Auto Layout，全部手写 frame 布局），界面固定深色。
不管：数据与持久化（`Sources/Workbench/Model/`）、布局树算法（`Sources/Workbench/Layout/`）、终端渲染与按键（`Sources/Workbench/Terminal/`）、菜单栏快捷键表（`Sources/Workbench/App/AppDelegate.swift`）。

设计 token、组件、交互与文案规范见 [design.md](../../../design.md)。

## 文件清单与关系
- `Sources/Workbench/UI/MainWindow.swift` — `MainWindowController` + `RootView`：侧栏 | (顶栏 / 工作区) 的框架布局，侧栏隐藏、贴边 peek、拖拽改宽；承载命令面板与导入面板浮层
- `Sources/Workbench/UI/SidebarView.swift` — 项目 → Worktree → 会话的 NSOutlineView、底部「添加项目」+ 收件箱铃铛、Arc 式 Workspace 切换条（详见 [sidebar.md](./sidebar.md)）
- `Sources/Workbench/UI/TopBarView.swift` — 顶栏：侧栏开关、Workspace 名、「N 栏 · N 个 Tab …」摘要、布局预设按钮、新版本提示
- `Sources/Workbench/UI/WorkspaceView.swift` — 把 `store.layout` 渲染成嵌套 `SplitContainerView` / `PaneView`；分隔条拖动、拖放落点（边缘分屏 / 中间加 Tab）、空栏选择器
- `Sources/Workbench/UI/PaneHeaderView.swift` — 每栏顶部：Tab 条（`TabView`，可拖，右键出关闭菜单）+ 来源行（项目/Worktree、状态、会话 id、Finder / 编辑器 / 复制路径 / ··· 操作）
- `Sources/Workbench/UI/CommandPalette.swift` — ⌘K / ⌘P 窗口内浮层面板（NSTableView）
- `Sources/Workbench/UI/PaletteSearch.swift` — 面板的数据模型：scope、entry、分组与排序（无 UI）
- `Sources/Workbench/UI/Fuzzy.swift` — 子序列模糊匹配 + 拼音（首字母 / 全拼）匹配（无 UI，有单测 `Tests/WorkbenchTests/FuzzyTests.swift`）
- `Sources/Workbench/UI/ImportPanel.swift` — 「从 Agent 使用过的项目导入」浮层，多选后加入指定 Workspace
- `Sources/Workbench/UI/InboxPopover.swift` — 铃铛弹出的收件箱：需要你 / 待查看 / 运行中
- `Sources/Workbench/UI/Menus.swift` — 所有右键菜单与「+」菜单（项目、Worktree、会话、Tab、Workspace、终端、用其他应用打开），外加 `WorkspaceColorPicker`
- `Sources/Workbench/UI/NewProjectSheet.swift` — 「新建项目」sheet（名称、父目录、是否 git init）
- `Sources/Workbench/UI/WorktreeDialogs.swift` — 移除 / 从磁盘删除 Worktree 的确认框、已隐藏 Worktree 菜单、`NewWorktreeSheet`
- `Sources/Workbench/UI/Widgets.swift` — 共享小组件：`Icons`、`IconButton`、`DotView`、`ChipView`、`ActionItem`、`ThinScroller`/`HoverScrollView`、`RelativeTime`、`NSTextField.label`、`layoutRow`
- `Sources/Workbench/UI/Theme.swift` — 「Bone」配色、字体 token、叠加到 Ghostty 的终端配色
- 调用关系：
  - `AppDelegate → MainWindowController → RootView → { SidebarView, TopBarView, WorkspaceView }`
  - `WorkspaceView → SplitContainerView / PaneView → PaneHeaderView(TabView) + Store 持有的 TerminalView`
  - `SidebarView → InboxPopover, WorkspaceSwitcher, Menus`；`PaneHeaderView / TerminalView 右键 → Menus → WorktreeDialogs`
  - `Store.showPalette / showImport → RootView.showPalette / showImport → CommandPalette(PaletteSearch → Fuzzy) / ImportPanel(Core.agentProjects)`
  - `Store.promptNewProject / promptNewWorktree → NewProjectSheet / NewWorktreeSheet`

## 数据流
- **订阅**：视图在 init 里 `store.observe { change in … }` 拿到 token，按 `Store.Change` 分派：
  - `.projects` → 侧栏 `reload()`（保留展开）、工作区 `refreshAll()`、顶栏 `refresh()`
  - `.session(id)` → 只刷新那一行 / 那一个 Tab（`reloadItem` / `header.refreshTab`）
  - `.layout(structure:)` → `WorkspaceView.sync`：`structure == true` 才重建 split 容器，否则原地推送 tabs/active/sizes/focus
  - `.workspace` → 侧栏横向滑动切换、工作区淡出-重建-淡入、顶栏刷新
  - `.reveal(id)` → 侧栏展开并滚到新会话；`.sidebar` → `RootView.setSidebarHidden`
- **回流**：用户操作一律调用 Store 的方法（`open` / `addTab` / `move` / `movePane` / `setSizes` / `apply(preset)` / `switchWorkspace` / `reorder*` …），由 Store 改模型后再 `notify`，视图不自己改模型状态。菜单项是 `ActionItem` 闭包，直接调 Store。
- **反向钩子**：Store 需要弹 UI 时走窗口注册的闭包：`paletteHandler`、`importHandler`（MainWindow 注册）、`inboxHandler`（SidebarView 注册）。
- **短生命周期订阅**：`InboxPopover` 只在打开期间 observe，关闭时 `unobserve`。
- **异步**：`ImportPanel` 在后台 Task 调 `Core.agentProjects`（首次约 0.4s），用 generation 丢弃过期结果后回主线程。

## 对外接口
- `MainWindowController(store:)`，暴露 `workspace` / `sidebar`（AppDelegate 启动时 `workspace.sync(structure: true)`）
- `WorkspaceView.focusActiveTerminal()` — 把键盘还给当前栏的活动终端
- `Menus.terminal(...)` — 终端右键菜单（TerminalView 调用）
- `Theme.ghosttyConfig` — 被 `Sources/Workbench/Terminal/GhosttyRuntime.swift` 叠加到用户 Ghostty 配置之上
- `NewProjectSheet` / `NewWorktreeSheet` 的 `present(on:)`（由 Store 的 `prompt*` 调用）
- 常量被他处引用：`SidebarView.width` / `motion`、`TopBarView.height`、`PaneHeaderView.height`、`PaneView.panePrefix`
- 仅 DEBUG：`SidebarView.debugToggle` / `debugRows`、`CommandPalette.debugType`，由 AppDelegate 在 `WORKBENCH_DEMO` 环境变量下通过分布式通知驱动

## 注意事项
- **纯 AppKit + 手写 frame**：几乎所有视图 `isFlipped = true`，在 `layout()` 里算 frame；没有约束。加新视图照同样方式写，别混入 Auto Layout / SwiftUI。
- **原地更新，不重建**：Pane、Tab、侧栏行都按 id 复用；只有布局嵌套变化才重建 split 容器。**TerminalView 归 Store 所有，只能 re-parent，绝不能在 UI 里新建或丢弃**（否则终端会话丢失）。
- **焦点与终端**：
  - 布局/聚焦变化后，若当前第一响应者是终端、窗口本身或 nil，`WorkspaceView` 会把焦点还给活动终端；不要在别处抢焦点后不归还。
  - 命令面板打开前记录终端是否有焦点，`onClose` 时异步 `focusActiveTerminal()`。
  - `TerminalView.performKeyEquivalent` 特意放行 ⌘K / ⌘P（Ghostty 默认把 ⌘K 绑成清屏），其余终端绑定和 Ctrl 组合键先给 Ghostty。新增全局快捷键若与终端冲突，要在那里放行。
  - 命令面板用 `NSEvent.addLocalMonitorForEvents` 捕获 ⌘1–9，`close()` 必须移除 monitor。
- **快捷键表在 `AppDelegate.makeMenu()`**：⌘K/⌘P 面板、⌘T 新终端 Tab、⌘N 新建项目、⌘O 添加项目、⌥⌘O 用默认编辑器打开、⌘I 收件箱、⇧⌘R 重扫会话、⌘W 关 Tab、⌘B 侧栏、⌘D / ⇧⌘D 分屏、⌃⌘1–4 布局预设、⌘1–9 聚焦第 N 栏、⇧⌘N 新 Workspace、⌃] / ⌃[ 与 ⌃1–9 切 Workspace。改快捷键时同步 tooltip 文案（如「向右分屏 ⌘D」「收件箱 ⌘I」）。
- **Theme token**：颜色/字体一律取 `Theme.*`，不要写死十六进制；窗口强制 `darkAqua`，没有浅色模式。改 `pane` / `selBG` / `selFG` / `accent` 时同步 `Theme.ghosttyConfig`。选中态靠明度（`selBG`/`selFG`），不用色相强调色。
- **动效**：统一用 `SidebarView.motion`（0.28s，曲线 0.2,0.8,0.2,1）；`DotView` 在「减少动态效果」开启时不转不闪。裸 CALayer 改 frame 会隐式动画，需要时 `CATransaction.setDisableActions(true)`。
- **标题栏区域**：窗口 `fullSizeContentView` + 透明标题栏；顶栏和侧栏顶部 38pt 自己处理 `handleTitlebarMouseDown`（拖动 / 双击按系统设置缩放）。侧栏隐藏时顶栏左侧留 78pt 给红绿灯。
- **中文 UI**：所有用户可见文案（菜单、tooltip、对话框、相对时间）是简体中文；「Session / Tab / Worktree / Workspace」等术语保留英文。代码注释是英文。
- **侧栏展开状态交给 AppKit autosave**（每个 Workspace 一个 `autosaveName`），app 不自己持久化；细节见 [sidebar.md](./sidebar.md)。
- **Sheet 生命周期**：`NewProjectSheet` / `NewWorktreeSheet` 用静态 `current` 引用保活，sheet 结束时清空。
- **批量关 Tab**：Tab 右键「关闭其他 / 左侧 / 右侧 / 所有 Tab」走 `Store.closeTabs`，只要其中有终端还在跑进程（Ghostty 的 `needs_confirm_quit`）就只弹一次确认，不逐个弹；单个「关闭 Tab」仍走 `closeTab`。
- **危险操作**：「从磁盘删除 Worktree」执行 `git worktree remove`，有未提交改动时默认拒绝，只能显式强制；「从 Seperate 移除」只隐藏，不动文件和 git 登记。
- 侧栏宽度存 `UserDefaults["sidebarWidth"]`，范围 180–480，且保证工作区至少留 360pt。

## 子页
- [sidebar.md](./sidebar.md) — 侧栏：outline 结构、展开状态、展开动画、拖拽排序、Workspace 切换
