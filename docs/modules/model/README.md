# Model(应用状态)

## 职责
整个 App 的唯一状态源:Workspace(项目集合 + 各自的 pane 布局)、Project/Worktree、Session(App 内新建的 + 从 `~/.codex` / `~/.claude` 扫出来的)、活着的终端、Agent 运行阶段、Inbox、系统通知、持久化。
不管:视图如何绘制(UI 模块)、终端渲染(Terminal 模块)、git/扫描/SQLite 的具体实现(Rust core,经 `Core` FFI 调用)。

## 文件清单与关系
- `Sources/Workbench/Model/Store.swift` — 状态中枢;变更通知、持久化、刷新、Agent 事件处理、Inbox
- `Sources/Workbench/Model/Models.swift` — 纯值类型(Project / Worktree / AgentSession / Workspace / 状态枚举 / InboxItem)
- `Sources/Workbench/Model/AgentHooks.swift` — 安装 claude/codex 包装脚本与 hooks 文件,生成终端环境变量
- `Sources/Workbench/Model/Notifier.swift` — macOS 通知 + Dock 角标
- `Sources/Workbench/Model/ExternalApps.swift` — 可用外部编辑器/终端清单
- 调用关系:`AppDelegate → Store → Core(FFI: git / scan / SQLite) · TerminalView · Notifier · AgentHooks`;`UI 视图 → store.observe / store 方法`

## 数据流
- **启动**:`Store.init` → `AgentHooks.install()` → `load()`(SQLite,失败回退 `state.json`)→ `resolveProjects`(同步读 git)→ `rebuildIndex()` → 注册分布式通知(Agent 事件)与 `didBecomeActive`(markSeen)。
- **刷新**:`refresh()` 由 AppDelegate 启动时、每 60 秒定时器、菜单手动触发;在后台 Task 里 `Core.scanSessions()` + `resolveProjects`,回主线程比对,有变化才 `rebuildIndex()` + `notify(.projects)`。
- **新会话 id 认领**:App 内新建的 Agent 起初没有会话 id,`adoptAgentIDs()` 按 kind + cwd + 时间(创建前 5 秒内起)从扫描结果里认领,之后才能 resume。
- **跳过权限**:`AgentSession.skipPermissions`(只对 Claude)让 `launchCommand` 追加 `--dangerously-skip-permissions`(新开和 resume 都带)。只存在内存里,不进数据库:重启 App 后恢复的会话会重新询问权限。
- **Agent 状态**:hook 事件 / 终端 OSC 通知 / 用户按键 / 命令退出 → `setPhase` → 更新 `phase`、角标、系统通知 → `resort` → `notify`。详见 [agent-hooks 专题](../../topics/agent-hooks.md)。
- **保存**:任何 `notify()` 都会 `scheduleSave()`(0.5 秒防抖)→ `saveNow()` 写 SQLite;退出时 `shutdown()` 立即保存并销毁终端。

## 对外接口
- 观察:`observe(_:) -> UUID` / `unobserve`,回调收到 `Store.Change`:`.projects`、`.session(id)`、`.layout(structure:)`、`.workspace`、`.reveal(id)`、`.sidebar`。
- 查询:`session(_:)`、`status(of:)`、`phaseMessage(of:)`、`sessions(in:)`、`inboxItems()`、`waitingIDs`、`layout`、`visibleProjects` 等。
- 操作:打开/新建/结束会话(`closeTab` 单个,经 Ghostty 确认;`closeTabs` 批量,有进程在跑只弹一次确认)、`mutateLayout`、工作区增删改、项目与 worktree 管理、`markInboxRead`、`openFromInbox`。点收件箱行和系统通知都走 `goTo(id)`:会话开在某个 Workspace 的栏里就切过去并激活那个 Tab;没开着就切到**它项目所在的** Workspace 再打开,而不是开在当前 Workspace。
- 由 UI 安装的回调:`inboxHandler`、`paletteHandler`、`importHandler`。
- 静态:`Store.dataDir`、`dbURL`、`legacyURL`(测试用)。
- 仅截图模式:`shotsSetPhase(_:_:need:)` 直接摆出收件箱状态(平时由 agent hook 驱动)。

## 注意事项
- **默认值按语言,已有数据不翻译**:新 Workspace 的默认名(「默认 / Default」)、通知和对话框文案走 `tr`;数据库里已有的名称、标题、别名是用户数据,原样保留。
- **全部 `@MainActor`**。后台只做 `Core` 调用(`resolveProjects` 是 `nonisolated static`),结果必须回 `MainActor.run` 再写状态。
- **变更通知模型**:没有 SwiftUI/Combine,也不整体重绘。每次改状态后必须调 `notify(<最窄的 Change>)`,否则视图不刷新、也不会保存(保存挂在 `notify` 上)。`.layout(structure: true)` 只在 pane 增删/嵌套变化时发出(用 `LayoutModel.shape` 比对),否则视图会整块重建。
- 改布局一律走 `mutateLayout { }`,它负责比对、发通知、`markSeen()`;不要直接赋值 `layout`。
- 改了 `created` / `discovered` / `worktrees` / `pinned` / 等待集合后要 `rebuildIndex()`,各视图读的是索引(`sessionsByWorktree`、`worktreeOfSession`)。`resort(after:)` 只在排序真的变了才发 `.projects`。
- **持久化**:数据目录 `~/Library/Application Support/Workbench/`(环境变量 `SEPERATE_DATA_DIR` 可覆盖;`WORKBENCH_DEMO` 时用 `seperate-demo.db`)。主存储是 `seperate.db`(SQLite,schema 与迁移在 `core/src/db.rs`,按 `PRAGMA user_version` 顺序执行);旧 `state.json` 首次启动导入一次后改名为 `state.json.bak`;SQLite 打不开时退回写 `state.json`。布局以 JSON 字符串存在 workspaces 表里,颜色存 `#RRGGBB`,时间存毫秒。
- 持久化的 Codable 字段名、`AgentKind` / `ExternalApp` 的 raw value 改了就读不回旧数据。
- 重启后没有任何终端在跑:`load()` 只保留有 agentSessionID 的已创建会话(状态重置为 history),并 prune 掉布局里不存在的 tab。
- 一个项目只属于一个 Workspace(`load()` 会去重,先出现者胜)。隐藏的 worktree 只是从 Seperate 移除,磁盘与 git 记录保留,且跨刷新/重启保持隐藏。
- 未 pin 的已扫描会话不存库;pin 住但本次扫描还没出现的会话靠 `pinnedRows` 保留,避免保存时丢 pin。
- 测试必须先 `useTempDataDir()` 再 `Store()`,否则会读写真实 `seperate.db`。`Notifier` 和 `AgentHooks.helper` 在非 `.app` 环境(测试、`swift run`)下是空操作 —— 这时 Agent 以原始命令启动,没有状态上报。
