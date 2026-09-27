# 0002. Rust core 经 C ABI 暴露,结果用 JSON 字符串

- 状态:已采纳
- 日期:2026-09-25(回填)

## 背景
git worktree 操作、会话历史扫描、SQLite 持久化、图标处理等逻辑适合放在 Swift 之外,且希望能独立测试。

## 决策
`core/` 是 Rust crate,编成 `Vendor/WorkbenchCore.xcframework`;对外只暴露 `wb_*` C 函数(`core/include/workbench_core.h`),返回 Rust 拥有的 JSON 字符串,Swift 解码后调用 `wb_free` 释放。Swift 侧只有 `Core/Core.swift` 调用它。

## 理由
JSON 边界简单、稳定,避免在 FFI 上传结构体;Swift 用 Codable 解码即可。

## 后果
- 改 FFI 签名时要同时改 `ffi.rs`、`workbench_core.h`、`Core.swift`,并重跑 `scripts/build-core.sh`。
- 漏掉 `wb_free` 会泄漏;返回 `NULL` 表示失败/无结果。
