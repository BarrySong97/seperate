# Layout(pane 布局模型)

## 职责
描述一个 Workspace 窗口内的 pane 布局:一棵分割树,叶子是 pane,每个 pane 持有若干会话 tab。纯值类型、纯算法,不含任何 AppKit/视图代码。
不管:视图渲染与拖拽交互(UI 模块的 `WorkspaceView` 等)、变更通知(Model 模块的 `Store.mutateLayout`)。

## 文件清单与关系
- `Sources/Workbench/Layout/LayoutModel.swift` — `Pane`、`LayoutNode`(pane / split)、`DropEdge`、`LayoutPreset`、`LayoutModel` 及树操作
- 调用关系:`UI 事件 → Store.mutateLayout { LayoutModel 操作 } → Store.notify(.layout(structure:)) → 视图`
- `LayoutModel.shape(_:)`(判定结构是否变化)定义在 `Sources/Workbench/Model/Store.swift` 的 extension 里

## 数据流
每个 `Workspace` 内嵌一个 `LayoutModel`;Store 通过 `layout` 计算属性读写当前活动工作区的那份。操作在副本上完成,Store 比对前后是否相等、树形 `shape` 是否变化,再决定发 `.layout(structure: true/false)`。保存时整棵树 JSON 编码成字符串写入 SQLite 的 workspaces 行。

## 对外接口
- 查询:`panes`(按树的叶子顺序)、`focusedPane`、`pane(containing:)`、`paneNumber`(⌘数字 用)、`openSessionIDs`。
- tab 操作:`open`、`addTab`、`detach`、`activate`、`move(_:to:edge:)`(edge 为 nil 表示并入为 tab)。
- 分割操作:`split`、`movePane`(edge 为 nil 表示互换)、`closePane`、`setSizes`、`apply(preset)`、`prune(keeping:)`。
- 静态树工具:`leaves`、`map`、`insert`、`remove`、`normalize`、`newID`。

## 注意事项
- **树不变量**:split 的 `sizes` 与 `children` 一一对应;不存在只有一个孩子的 split,也不存在与父同轴的嵌套 split(`insert` 同轴时插为兄弟,`remove` 后必须 `normalize`)。`sizes` 是相对权重,不要求和为 1。
- 一个会话 id 最多出现在一个 pane 里(`addTab` 先 `detach`)。跨 Workspace 的唯一性由 Store 保证(打开时从别的工作区 detach)。
- 永远至少一个 pane:`closePane` 在只剩一个时无效;拖走最后一个 tab 会关闭源 pane(`move`)。空 pane 可以存在(如 preset 补位)。
- `focusedPaneID` 必须指向存在的 pane;split/closePane/apply 都会维护它。
- 任何手动改动(split、setSizes、movePane、closePane)都会把 `preset` 置为 nil;`apply(preset)` 会重建所有 pane id,多出的 tab 组合并进最后一个 pane。
- pane 与项目/worktree 无关,任何会话都能放进任何 pane。
- 布局以 JSON 持久化,`Pane` / `LayoutNode` / `LayoutPreset` 的 Codable 形状与 raw value 改动会导致旧布局解码失败(Store 会回退为空布局)。
- 重启后 Store 用 `prune(keeping:)` 清掉已不存在的会话 tab。
