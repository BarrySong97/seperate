# 编码规范

## 命名
- Swift:类型 `PascalCase`,函数/变量 `camelCase`;文件名 = 主类型名(`SidebarView.swift`)。
- Rust:模块/函数 `snake_case`;C ABI 导出函数统一 `wb_` 前缀(见 `core/src/ffi.rs` / `core/include/workbench_core.h`)。
- 脚本:`scripts/<动词>-<对象>.sh`(`build-app.sh`、`package-dmg.sh`)。
- UI 文案中英双语:每条写成 `tr("中文", "English")`(英文复数用 `plural(n, "tab")`),见 [ADR-0006](decisions/0006-bilingual-ui.md);代码、注释、提交信息用英文。

## 目录与文件结构
- `Sources/Workbench/<层>/`:`App`(启动/更新)· `Model`(状态与持久化)· `Layout`(分屏树)· `Terminal`(libghostty)· `UI`(AppKit 视图)· `Core`(Rust 桥接)。
- `core/`:Rust crate,编译成 `Vendor/WorkbenchCore.xcframework`,Swift 只经 `Core.swift` 调用。
- 一个文件一件事;文件过大(> ~500 行)优先按职责拆分,而不是继续堆。
- 每个源文件(`.swift` / `.rs` / `scripts/*.sh|py|mjs`)顶部必须有 AI 文件头(`@purpose/@role/@deps/@gotcha`),见 [file-headers/README.md](file-headers/README.md)。

## 架构边界
- 依赖方向:`UI → Model(Store) → Core(Swift 桥)→ Rust core`;`Layout` 是纯数据模型,不依赖 UI。
- Rust 只通过 C ABI 暴露,结果是 Rust 拥有的 JSON 字符串,Swift 读完必须 `wb_free`。
- `Store` 是唯一状态源,`@MainActor`;视图按 `Store.Change` 精准订阅,不做整窗重绘。
- 新增边界约束时,优先写成测试(`Tests/WorkbenchTests/`)再配一条 [ADR](decisions/)。

## Ratchet(棘轮原则)
- agent 犯了错,别只修这一处:**固化成一条 test / 检查脚本规则 / ADR**,保证同样的错不再犯。
- 能用确定性工具强制的,就别只写进文档。

## 错误处理
- 外部命令 / FFI 失败:Rust 侧返回 `NULL` 或 `{ok:false,error}` JSON;Swift 侧转成可展示的错误或安静降级(`try?`),不崩溃。
- 用户可见的失败用中文提示;不要把原始 stderr 直接弹给用户,除非是 git 报错这类用户能看懂的信息。

## 日志
- 用 `os.Logger(subsystem: "dev.seperate", category: …)`;不要留 `print`。不记录用户路径以外的敏感信息。

## 提交规范
- 英文祈使句标题,描述用户可见的变化(例:`Project context menu: copy the project's path`),不加 `feat:` 前缀。
- 正文说明「为什么」;一次提交一件事。
- 只在用户要求时提交 / 推送;发版(打 tag)只在用户明确说「发版」时做。

---

# 术语表
| 术语 | 标识符 | 含义 |
|---|---|---|
| 工作区 | `Workspace` | 一组项目 + 一个分屏布局;可切换 |
| 项目 | `Project` | 一个文件夹或 git 仓库根 |
| 工作树 | `Worktree` | git worktree;侧边栏按项目分组展示 |
| 会话 | `AgentSession` | 一个 agent(Claude Code / Codex)或 shell 会话 |
| 窗格 / 标签 | pane / tab | 布局树中的叶子与其中的终端标签 |
| 收件箱 | `InboxItem` | agent 通过 hook 上报、需要用户关注的事件 |
| 核心库 | WorkbenchCore / `core/` | Rust:git、会话扫描、SQLite、图标、文本工具 |

---

# 评审自查清单(收尾前对照)
- [ ] 改动小而内聚,没有夹带无关重构或整文件格式化
- [ ] 命名、风格与周边代码一致
- [ ] 没有违反 AGENTS.md 的红线
- [ ] 涉及文件的 AI 文件头已更新
- [ ] 对应 `docs/modules/<module>/`(或 `docs/topics/`)已同步;决策性改动已补 ADR
- [ ] `scripts/build-core.sh && swift test` 通过(或说明为何未跑)
- [ ] `node scripts/check-docs.mjs` 无 ❌
