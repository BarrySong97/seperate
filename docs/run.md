# 运行手册

所有命令在仓库根目录执行。构建/发布细节见 [构建与发布](modules/release/README.md),安装器见 [安装器](modules/installer/README.md)。

## 环境要求
- Apple Silicon(`setup-ghostty.sh` 只支持 arm64),macOS 14+(`LSMinimumSystemVersion`)
- Xcode 26(CI 用 `macos-26` runner;Swift tools 6.0)
- Rust(`rustup`;`build-core.sh` 会把 `~/.cargo/bin` 加进 PATH)
- Zig 不用自己装:`setup-ghostty.sh` 会下载固定版本到 `.deps/`
- 打包 DMG 需要 `python3`(自动建 `.deps/dmgbuild` venv);发布/签名需要 `gh`

## 安装 / 首次准备
```sh
scripts/setup-ghostty.sh     # 一次:构建 GhosttyKit 到 Vendor/(首次几分钟)
scripts/build-core.sh        # 构建 Rust core 到 Vendor/WorkbenchCore.xcframework
```
`Vendor/`、`.deps/`、`build/` 都是 gitignored,新 clone 必须先跑这两步,否则 `swift build` 找不到 binaryTarget。

## 本地构建与运行
Debug 构建(产物 `build/Seperate.app`):
```sh
scripts/build-app.sh debug
```
- `scripts/build-app.sh debug --open` 会顺带启动它。**用户在已安装的 Seperate 里跑着 agent,不要启动 / 退出 / 重启已安装的 app,也不要随手 `--open`**;需要看运行效果先问用户。

本地安装(用户要求把改动装到本机时):构建 release,原地替换 `/Applications/Seperate.app`,由用户自己重启。
```sh
scripts/build-app.sh release
mv /Applications/Seperate.app ~/.Trash/Seperate-$(date +%Y%m%d-%H%M%S).app
mv build/Seperate.app /Applications/Seperate.app
```
- 不要 `killall`/`open` 这个 app;正在运行的旧进程不受影响,用户下次重启即是新版本。
- 不要用安装器(`Install Seperate.app`)做本地安装:它会主动让运行中的 Seperate 退出。

## 测试
```sh
scripts/build-core.sh && swift test
swift test --filter LayoutModelTests                 # 单个测试类
swift test --filter LayoutModelTests/testMoveToEdgeSplitsTarget   # 单个测试方法
```
测试在 `Tests/WorkbenchTests/`。CI(`ci.yml`)跑的就是第一行。

## Lint / 格式化
- 目前**没有强制的 formatter / linter**(仓库里没有 `.swift-format`、`rustfmt.toml`,CI 也不检查)。
- `cargo fmt` 或 swift-format 会重排大量现有文件,**不要在全仓库运行**;只按周边代码风格手写。

## 打包 DMG
```sh
scripts/package-dmg.sh       # 产出 build/Seperate-<ver>.dmg 和 build/Seperate-<ver>.zip
VERSION=0.2.0 scripts/package-dmg.sh
swift scripts/make-installer-assets.swift   # 仅在改了 DMG 背景 / 安装器图标设计后
```
未设置 `CODESIGN_IDENTITY` 时为 ad-hoc 签名,DMG 用带 Gatekeeper 提示的背景。

## 发布
**只在用户明确要求时发布。**
```sh
scripts/release.sh 0.2.0     # 工作区必须干净;push HEAD、打 tag v0.2.0 并推送
gh run watch                 # 看 release.yml 构建
```
- 版本号必须是 `X.Y.Z`,且 tag 不能已存在。
- 本机演练整条发布流水线(不打 tag、不上传):`scripts/release-local.sh 0.2.0`(需要 `.secrets`,由 `scripts/setup-signing.sh` 生成;不要读取或打印它)。

## 文档同步检查
```sh
node scripts/check-docs.mjs
```
检查源文件 AI 文件头(`@purpose`)、文档失效引用、代码改动但模块文档未更新。

## 常用脚本
| 命令 | 作用 |
| --- | --- |
| `scripts/setup-ghostty.sh` | 构建 GhosttyKit 到 `Vendor/`(一次) |
| `scripts/build-core.sh` | 构建 Rust core xcframework |
| `scripts/build-app.sh debug\|release [--open]` | 组装 `build/Seperate.app` |
| `scripts/build-installer.sh` | 组装 `build/Install Seperate.app`(需先 release 构建) |
| `scripts/package-dmg.sh` | 出 DMG + Sparkle zip |
| `scripts/make-appcast.sh <ver> <zip> <key> [notes]` | 签名 zip 并写 `build/appcast.xml`(发布流程内部用) |
| `scripts/release.sh <ver>` | 打 tag 触发 GitHub 发布 |
| `scripts/release-local.sh [ver]` | 本机演练发布流程 |
| `scripts/setup-signing.sh` | 一次性配置签名/公证 secrets |
| `scripts/sparkle-keys.sh` | 一次性配置 Sparkle 密钥(已完成) |
| `swift scripts/make-installer-assets.swift` | 重新生成 DMG 背景和安装器图标 |
| `node scripts/check-docs.mjs` | 文档同步检查 |
| `scripts/render-shots.sh [目录]` | 用真实界面渲染官网截图(默认 `build/shots/`),见下 |

## 官网截图
```sh
scripts/render-shots.sh            # 输出 build/shots/{import,hero,inbox,panes,worktree,palette}.png(2x)
SHOTS_PALETTE_QUERY=lm scripts/render-shots.sh   # 换命令面板的搜索词(默认 asms)
```
需要 `~/SeperateDemo` 下的演示项目(lumen-notes、lumen-notes.worktrees/暗色模式、pixel-api、atlas-cli),里面各有真实跑过的 Claude Code / Codex 会话;截图只读这个目录下的会话,用户其它项目不会进图。不启动、不影响已安装的 Seperate,也不弹任何权限。

## 官网(website/)
`website/` 是独立的 Next.js 站点,用 pnpm 管理,有自己的 `website/AGENTS.md`,改它之前先读那份。脚本见 `website/package.json`:
```sh
cd website && pnpm install
pnpm dev      # next dev
pnpm build    # next build
pnpm lint     # eslint
pnpm upload   # node scripts/upload-media.mjs
```
部署在 Vercel:项目的 Root Directory 设为 `website`,其余由 `website/vercel.json` 决定(pnpm 安装、`pnpm build`、发布 `out/`)。详见 `website/README.md` 的 Deploying 一节。
