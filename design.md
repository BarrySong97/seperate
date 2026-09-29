# 设计系统

Seperate 的界面是纯 AppKit、固定深色（窗口强制 `darkAqua`），配色叫「Bone」：cmux 式的暖橄榄灰底，选中靠明度而不是色相强调色。所有 token 定义在 `Sources/Workbench/UI/Theme.swift`，模块说明见 [docs/modules/ui/README.md](docs/modules/ui/README.md)。

## 设计 token

### 颜色（`Theme.*`）
| token | 值 | 用途 |
|---|---|---|
| `ground` | `#22231E` | 侧栏、顶栏、栏与栏之间的缝隙、窗口背景 |
| `pane` | `#272822` | 栏与终端背景 |
| `panel` | `#2B2C26` | 浮层卡片底色（命令面板、导入面板） |
| `line` | `#34352F` | 分隔线、未聚焦栏边框 |
| `line2` | `#42433C` | 浮层描边（命令面板、导入面板、peek 侧栏） |
| `text` | `#E8E8E2` | 正文；Codex 图标色 |
| `muted` | `#9C9D95` | 次要文字、图标按钮默认色 |
| `faint` | `#6D6E67` | 更弱的文字（时间、会话 id、未选中预设） |
| `selBG` | `#3D3E36` | 选中 / 悬停行背景 |
| `selFG` | `#F5F4EC` | 选中文字 |
| `hover` | 白 5% 透明 | 图标按钮、行的悬停底 |
| `accent` | `#D6D3C3` | 「骨白」：活动 Tab 标线、分隔条高亮、拖放落点、完成状态点 |
| `focus` | `#76776D` | 聚焦栏的边框 |
| `run` | `#9CCF6C` | 运行中（转圈） |
| `wait` | `#E6B450` | 需要你（琥珀）、新版本提示 |
| `danger` | `#F08A80` | 出错 |
| `claude` | `#E8916C` | Claude 图标色 |
| `shell` | `#78C6DE` | Shell 图标色 |

Workspace 可选 tint（`Workspace.tints`，`Sources/Workbench/Model/Models.swift`）：石板蓝 `#8FA7BA`、草绿 `#9CCF6C`、陶土 `#E8916C`、赭石 `#C9A36B`、薰衣草 `#B59AD6`、湖蓝 `#78C6DE`、玫瑰 `#E07A8F`、骨白 `#D6D3C3`，另可自定义；tint 以 10% 混入侧栏顶部渐变。

### 字体
- `uiFont`：系统字体 12.5 — 默认正文（`NSTextField.label` 的默认值）
- `smallFont`：系统字体 11.5 — 来源行、footer 按钮、切换条名字
- `monoFont`：等宽系统字体 10.5 — 会话 id 等
- 其他常见字号直接写在视图里：标题 13 semibold、摘要 12、时间 10.5–11。

### 终端配色
`Theme.ghosttyConfig` 叠加在用户自己的 Ghostty 配置之上：背景 `#272822`、前景 `#e8e8e2`、光标 `#d6d3c3`、选区 `#3d3e36` / `#f5f4ec`，内边距 10×8（balance），关闭确认关闭。改 `pane` / `text` / `accent` / `selBG` / `selFG` 时要同步这里。

### 尺寸与间距
- 侧栏默认宽 244，可拖 180–480（工作区至少留 360）；顶栏高 38；栏头高 60（Tab 条 34 + 来源行 26）；侧栏 footer 34、Workspace 切换条 42。
- 栏与栏间隔 6（`SplitContainerView.gap`）；工作区右、下各留 6。
- 圆角：栏 8、行/按钮悬停 6、peek 浮层 12、更新提示胶囊 11。
- 侧栏行高：项目 30、Worktree 26、会话 28、「显示全部」26；命令面板结果行 34、分组标题 26。

### 动效
- 统一曲线与时长：`SidebarView.motion` = 0.28s，`CAMediaTimingFunction(0.2, 0.8, 0.2, 1)`（Arc 式，快起软落）。用于侧栏收起、peek、Workspace 切换滑动、工作区淡入。
- 命令面板出现 0.16s（淡入 + 0.97→1 缩放）；peek 收回 0.18s；工作区切换先淡出 0.12s。
- 尊重「减少动态效果」：`DotView` 不转圈、不闪烁。

## 组件
都在 `Sources/Workbench/UI/Widgets.swift`，除特别说明。
- `Icons` — `agent(kind)`：Codex（有打包 logo 用 logo，否则 `>_`）、Claude 星号、Shell 窗口，按 kind 着色并缓存；`symbol(name)`：SF Symbol；`preset(p)`：布局预设小图。
- `IconButton` — 无边框图标按钮，悬停变亮 + `hover` 圆角底，`onClick` 闭包；`intrinsicContentSize` 永远是完整正方形。
- `DotView` — 会话状态：working = 绿色转圈、waiting = 琥珀色脉动圆点、done = 骨白圆点、failed = 红色小方块（不只靠颜色区分）；idle / history 不显示。
- `ChipView` — 项目标识：有项目自己的 favicon / app 图标就用，否则取首字母，色相由名字哈希得出（稳定）。
- `ActionItem` — 用闭包的 `NSMenuItem`，所有菜单都用它，不写 selector。
- `ThinScroller` + `HoverScrollView` — 细覆盖式滚动条，只在鼠标悬停时显示，不占布局宽度，不受系统「显示滚动条」设置影响。
- `RelativeTime` — 短时间：刚刚 / 5分钟 / 3小时 / 昨天 / 4天 / 9月12日 / 2025年9月12日；`full` 用于 tooltip（`yyyy年M月d日 HH:mm`）。
- `NSTextField.label(...)` — 单行、尾部截断的标签工厂，默认 `uiFont` + `text`。
- `NSView.layoutRow(...)` — 水平一行、垂直居中的简易布局，`nil` 宽度的项平分剩余空间。
- `NSWindow.handleTitlebarMouseDown` — 画在透明标题栏上的视图用：拖动移窗，双击按系统设置缩放/最小化。
- 其他文件里的可复用件：`HoverRowView` / `HoverCell` / `ChevronView`（`SidebarView.swift`）、`PickRow` / `DropOverlay`（`WorkspaceView.swift`）、`BellBadge`（`SidebarView.swift`）。

## 交互规范
- **快捷键**（菜单栏定义在 `Sources/Workbench/App/AppDelegate.swift`）：⌘K / ⌘P 命令面板、⌘T 新建终端 Tab、⌘N 新建项目、⌘O 添加项目、⌥⌘O 用默认编辑器打开 Worktree、⌘I 收件箱、⇧⌘R 重新扫描会话、⌘W 关闭 Tab、⌘B 切换侧栏、⌘D 向右分屏、⇧⌘D 向下分屏、⌃⌘1–4 布局预设、⌘1–9 聚焦第 N 栏、⇧⌘N 新建 Workspace、⌃] / ⌃[ 下一个 / 上一个 Workspace、⌃1–9 切到第 N 个 Workspace。
- **命令面板**：窗口内浮层 + 暗化背景（不是独立窗口）。↑↓ 选择、⏎ 打开、⌘⏎ 在新栏打开、⌘1–9 直接选第 N 行、esc 关闭。分组：会话 / Workspace / 新建 / 命令；空查询不显示「新建」组。支持拼音首字母和全拼（「dmtb」→ 代码同步）。关闭后焦点还给原来的终端。
- **菜单**：右键和「+」菜单打开时才构建；危险项（「从磁盘删除…」）用红字；需要进一步输入的项以「…」结尾；当前默认项标「（默认）」或打勾。
- **新建会话**：凡是列出「Codex / Claude Code / 终端」的地方（「+」菜单、项目 / Worktree / 终端右键、命令面板），Claude Code 下面都有一项「Claude Code（跳过权限）」，以 `--dangerously-skip-permissions` 启动。
- **Tab**：右键 Tab 可「关闭 Tab / 关闭其他 Tab / 关闭左侧 Tab / 关闭右侧 Tab / 关闭所有 Tab」，没有可关的项置灰；批量关闭时有进程在跑只确认一次。
- **侧栏**：单击会话打开，⌘/⇧+单击在新栏打开；拖会话到栏的边缘分屏、到中间或 Tab 条加为 Tab；拖项目 / Worktree 行重排；双指横扫切 Workspace；隐藏时鼠标贴左边缘浮出 peek。
- **栏**：拖分隔条调整比例，双击分隔条均分；拖整栏可交换位置；点击栏即聚焦。
- **Tooltip 带快捷键**：如「切换侧栏 ⌘B」「向右分屏 ⌘D」「收件箱 ⌘I」，改快捷键时一并改。

## 文案
- 所有用户可见文案**中英双语**（`tr("中文", "English")`，跟随系统或菜单「语言」）：菜单栏（文件 / 编辑 / 布局 / 窗口 ↔ File / Edit / Layout / Window）、右键菜单、tooltip、对话框、状态（等待确认 / 出错了 / 完成 · 5分钟 ↔ Needs approval / Failed / Done · 5m）。英文菜单项用标题式大小写。
- 产品与领域术语保留英文：Session、Tab、Worktree、Workspace、Git、Codex、Claude、Finder。中英文之间加空格（「新建 Worktree…」「3 个 Tab」），项目名等引用用「」。
- 口吻口语、直接，以用户为主语：「放一个 Session 进来」「从左侧拖进来，或者选一个：」「N 个需要你」。确认框说清会发生什么、保留什么、怎么恢复。
- 代码注释、文件头用英文。
