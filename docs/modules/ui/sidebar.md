# 侧栏（SidebarView）

源文件：`Sources/Workbench/UI/SidebarView.swift`。上级文档：[UI](./README.md)。

## 结构
- 顶部 `topInset`（停靠时 38pt，给红绿灯；peek 浮出时 10pt）充当标题栏。
- 中间：`HoverScrollView` 包 `SidebarOutline`（NSOutlineView 子类，隐藏展开三角，用闭包提供右键菜单），外面再套一层 `slider` 用于切换 Workspace 时的横向滑动裁剪。
- 底部 footer：「添加项目」+ ▾（新建项目 / 选择文件夹 / 从 Agent 导入）+ 收件箱铃铛（`BellBadge`：琥珀色数字 = 需要你，小圆点 = 只有待查看）。
- 最底部 `WorkspaceSwitcher`：每个 Workspace 一个方块按钮（可拖动排序、右键菜单）、当前名字、「+」。
- 背景是一层 `CAGradientLayer`，顶部混入当前 Workspace 的 tint 色（10%）。

## Outline 数据
- 层级：项目 → Worktree → 会话，外加每个 Worktree 下的「显示全部 N 个…」行（`more`）。
- `Item` 是 NSObject，按 key 复用以保证跨 reload 的对象同一性：`p:<projectRoot>`、`w:<worktreePath>`、`s:<sessionID>`、`m:<worktreePath>`。**不要每次 reload 新建 Item**，否则 AppKit 的展开状态和 `reloadItem` 都会失效。
- 每个 Worktree 只列 `sessionLimit = 5` 个会话（顺序由 `store.sessions(in:)` 决定），超出部分里仍在运行的会话总会列出；其余点「显示全部」→ 以该 Worktree 为 scope 打开命令面板。
- 单击：项目/Worktree 行切换展开；会话行打开（按住 ⌘ 或 ⇧ 在新栏打开）。

## 展开状态
- 完全交给 AppKit：`autosaveExpandedItems = true`，`autosaveName = "sidebar-<workspaceID>"`，每个 Workspace 一份（CodeEdit 的做法）。某 Workspace 首次加载时全部展开。
- `expanded` 集合只是为 reload 后恢复而记下的 key：只有**用户显式折叠**才移除（AppKit 在父级折叠时也会给子级发通知，不能据此移除）；AppKit 自己恢复的展开用 `noteVisibleExpansion()` 补记。
- `reload()` = `reloadData()` 后按 key 先展开父再展开子（子项只在父展开后存在）。
- 回归测试：`Tests/WorkbenchTests/SidebarTests.swift`（折叠状态必须跨 reload 保留）。

## 展开 / 折叠动画
AppKit 自带的展开动画会让透明行从父行上方滑过。这里改成手风琴式：父行下方的行滑开/合拢留出空隙，子行在空隙里淡入/淡出；`toggling` 标志防止动画中重入。行 cell 的 chevron 通过 `DisclosureCell.setOpen` 同步旋转。

## 拖拽
- 会话行 → 以 `.string` 写入会话 id，拖到工作区的栏里（边缘分屏 / 中间加 Tab，由 `PaneView` 处理）。
- 项目行 → `.projectID`，只能在顶层项目之间重排（`store.reorderProject`）。
- Worktree 行 → `.worktreePath`，只能在同一项目的 Worktree 之间重排（`store.reorderWorktree`）。
- 落在行上时会换算成该行上方/下方的插入点。

## Workspace 切换
- 触发：切换条按钮、⌃1–9 / ⌃] ⌃[、侧栏上双指横扫（累计 >60pt 触发一次，自然滚动方向：左扫 = 下一个）。
- `.workspace` 变更时若确实换了 Workspace：先对旧列表截图，换新 `autosaveName` 重新加载，再让截图和新列表按方向横向滑动（`SidebarView.motion`）；否则只刷新切换条和 tint。

## 刷新
- `.session(id)` 只 `reloadItem` 那一行；若所在项目是折叠的，也刷新项目行（折叠时项目行只显示内部最紧急的状态：需要你 > 完成 > 运行中）；并更新切换条上其他 Workspace 的提醒标记。
- `.layout` 刷新所有可见会话行（「已打开」等状态）。
- 每 60 秒定时刷新会话行，让「5分钟」之类的相对时间自然变老。
- 每次任何变更都会 `updateBell()`。

## 调试
DEBUG 构建下 `debugToggle(name)` / `debugRows()` 供 AppDelegate 在 `WORKBENCH_DEMO` 模式下通过分布式通知 `dev.seperate.debug` 驱动（无需 UI 脚本权限）。
