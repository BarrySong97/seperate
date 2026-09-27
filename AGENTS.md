# Seperate — Agent 指南

**是什么**:macOS 工作台,把 Claude Code / Codex 与 shell 会话按项目和 git worktree 并排跑在分屏终端里(基于 libghostty)。
**架构**:原生 macOS App · Swift 6 / AppKit(SwiftPM)+ Rust core(C ABI + JSON,SQLite)+ GhosttyKit · Sparkle 更新 · DMG 双击安装器 · 运行见 [docs/run.md](docs/run.md)
`website/` 是独立的 Next.js 官网,有自己的 AGENTS.md,不受本文件约束。

## 🚨 红线(不可逾越)
- **不启动 / 退出 / 重启已安装的 Seperate**,不截图、不模拟鼠标、不做 AX 查询(会触发权限弹窗,授权后 App 重启)。用户正在里面跑 agent(包括你)— 见 [ADR-0005](docs/decisions/0005-local-install-until-release.md),由 `scripts/hooks/guard.mjs` 拦截
- **本地安装 ≠ 发版**:改完用 `scripts/build-app.sh release` 构建,把 `/Applications/Seperate.app` 原地替换(旧包移到 `~/.Trash`),让用户自己重启。只有用户明确说「发版」才跑 `scripts/release.sh`(会推 tag、公开发布)/ `release-local.sh` / `setup-signing.sh` / `sparkle-keys.sh` — [ADR-0005](docs/decisions/0005-local-install-until-release.md)
- **不读、不打印、不提交 `.secrets`**;secret 只按名字提(`APPLE_*`、`SPARKLE_PRIVATE_KEY`)。Sparkle 公钥写死在 `scripts/build-app.sh`,换密钥对会让所有已装副本无法更新
- **不改用户的 `~/.claude` / `~/.codex` 配置**:hook 只通过 `<dataDir>/bin` 包装脚本按次注入 — 见 [agent-hooks](docs/topics/agent-hooks.md)
- **`seperate-hook` 不得向 stdout 输出、必须 exit 0**;通知名 `dev.seperate.agent-event` 及 userInfo 键与 `Store.agentEvent` 是跨 target 契约,两边同改并跑 `AgentHooksTests`
- **FFI 三处同改**:`core/src/ffi.rs` + `core/include/workbench_core.h` + `Sources/Workbench/Core/Core.swift`,然后重跑 `scripts/build-core.sh`;返回的 `char*` 只能用 `wb_free` 释放 — [ADR-0002](docs/decisions/0002-rust-core-c-abi-json.md)
- **DB 迁移只追加**:`core/src/db.rs` 的 `MIGRATIONS` 按 `PRAGMA user_version`,已发布的条目不得修改/重排;持久化的 Codable 字段名、枚举 raw value 不得随意改名(会丢用户数据)
- **`Store` 只在主线程改,且每次改动都要 `notify(<最窄的 Change>)`**(保存由 notify 触发);布局只经 `store.mutateLayout {}` 修改 — 见 [model](docs/modules/model/README.md)
- **libghostty 调用全在主线程**;不在 Ghostty 回调里释放 surface;surface 等视图进窗口且 ≥40×40 再创建 — 见 [terminal](docs/modules/terminal/README.md)
- **UI**:纯 AppKit、仅深色;颜色/字体只用 `Theme.*`(改主色同步 `Theme.ghosttyConfig`);`TerminalView` 归 `Store` 所有,UI 只挪不建;新全局快捷键若与终端冲突要在 `TerminalView.performKeyEquivalent` 放行;UI 文案用简体中文 — 见 [ui](docs/modules/ui/README.md)、[design.md](design.md)
- **测试不碰真实用户数据**:`Store()` 之前先 `useTempDataDir()`
- **不做全仓格式化**(`cargo fmt` / swift-format 会重排现有文件);更新检查只在启动时和手动触发 — [ADR-0003](docs/decisions/0003-sparkle-update-checks.md)

## ✅ 工作流(Definition of Done,缺一不算完成)
1. 读相关模块文档 [docs/modules/](docs/modules/)(+ 专题 [docs/topics/](docs/topics/))+ 待改文件的文件头
2. 大改先写 [docs/plans/](docs/plans/) 计划(Plan → Approve → Execute)
3. 改代码,遵循 [docs/conventions.md](docs/conventions.md)
4. 同步:文件头 + 对应 `docs/modules/<module>/`(或 `docs/topics/`);决策性改动补一条 [ADR](docs/decisions/)
5. 按 [docs/testing.md](docs/testing.md) 验证:`scripts/build-core.sh && swift test`(先 `--filter` 跑受影响的)
6. 跑 `node scripts/check-docs.mjs`,清掉 ❌
7. 构建并本地安装,告诉用户「已安装,重启 Seperate 试用」,说清哪些已安装、哪些只构建了
8. 只在用户要求时提交(英文祈使句标题,见 [conventions](docs/conventions.md))

> **Ratchet 棘轮**:agent 犯了错,别只修这一处——固化成一条 test / guard 规则 / ADR,保证同样的错不再犯。

## 📚 导航
- **模块**:[app](docs/modules/app/README.md)(启动/菜单/更新)· [model](docs/modules/model/README.md)(Store/持久化)· [layout](docs/modules/layout/README.md)(分屏树)· [terminal](docs/modules/terminal/README.md)(libghostty)· [ui](docs/modules/ui/README.md)(AppKit 视图)· [core](docs/modules/core/README.md)(Rust + Swift 桥)· [hook](docs/modules/hook/README.md)(seperate-hook)· [installer](docs/modules/installer/README.md)(DMG 安装器)· [release](docs/modules/release/README.md)(构建/打包/发版/CI)
- **专题**:[agent-hooks 事件链路](docs/topics/agent-hooks.md)
- 设计系统 [design.md](design.md) · 运行手册 [docs/run.md](docs/run.md) · 规范&术语 [docs/conventions.md](docs/conventions.md)
- 测试&验证 [docs/testing.md](docs/testing.md) · 需求 [docs/specs/](docs/specs/) · 计划 [docs/plans/](docs/plans/) · 决策 [docs/decisions/](docs/decisions/README.md)
- 文件头规范 [docs/file-headers/](docs/file-headers/README.md) · 文档检查 `node scripts/check-docs.mjs`(`/sync-docs` 自动修复)
