# 0004. DMG 内置双击安装器;签名/公证用 Tauri 同名 secrets

- 状态:已采纳
- 日期:2026-09-25(回填)

## 背景
未公证构建会被 Gatekeeper 拦截,拖拽安装对用户不友好,且替换旧版本容易出错。

## 决策
DMG 里放一个「安装 Seperate」(`SeperateInstaller`),负责复制到 /Applications(替换旧版)并打开。签名与公证使用与 Tauri 相同的 secret 名(`APPLE_CERTIFICATE` 等);未配置时降级为 ad-hoc 签名,DMG 背景附带 Gatekeeper 提示。

## 理由
只需用户在「隐私与安全性」里放行一次安装器;secret 名与已有 Tauri 项目共用,减少配置成本。

## 后果
`release.yml` 的签名步骤按 secret 是否存在分支;本地可用 `scripts/release-local.sh` 跑一次同样流程(读取 `.secrets`,该文件不入库)。
