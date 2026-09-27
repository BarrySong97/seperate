# 0001. 终端用 libghostty(GhosttyKit)

- 状态:已采纳
- 日期:2026-09-25(回填)

## 背景
Seperate 要把多个 Claude Code / Codex / shell 会话并排跑,终端的渲染质量、性能与兼容性是核心体验。

## 决策
嵌入 libghostty:`scripts/setup-ghostty.sh` 编出 `Vendor/GhosttyKit.xcframework`,以 SwiftPM binaryTarget 链接,由 `Terminal/` 模块封装。

## 理由
Metal 渲染、完整的终端兼容性,且作为库可嵌入原生 AppKit 视图;自写终端或用 SwiftTerm 类方案达不到同样质量。

## 后果
- 构建需要 Zig 与一次性的 GhosttyKit 编译;`Vendor/` 不入库。
- libghostty 是 C API,生命周期 / 线程 / 回调需要在 `GhosttyRuntime.swift` 小心处理。
