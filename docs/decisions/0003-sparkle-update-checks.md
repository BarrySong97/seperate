# 0003. Sparkle 更新:仅在启动时和手动时检查

- 状态:已采纳
- 日期:2026-09-25

## 背景
Sparkle 默认按 24h 间隔检查;App 长时间不关时会在用户工作中弹更新,而重新打开 App 又可能因为不满 24h 而不检查。

## 决策
启动时静默检查一次 + 菜单「检查更新…」手动检查;把 Sparkle 定时器推到一年后,使其实际不触发。发现新版本只在顶栏显示「新版本 x.y.z」按钮,不弹窗。菜单开关文案为「启动时检查更新」。

## 理由
用户在 App 里跑 agent,不能被弹窗或自动重启打断。

## 后果
更新包必须带 EdDSA 签名;appcast 从 `releases/latest/download/appcast.xml` 读取。见 `App/Updater.swift` 与 [release 模块](../modules/release/README.md)。
