# 构建与发布(scripts/ + CI)

## 职责
把源码变成可分发的产物并发布:准备依赖(GhosttyKit、Rust core)→ 组装 `Seperate.app` → 打包 DMG(内含双击安装器)与 Sparkle 更新 zip → 签名/公证(可选)→ 生成 `appcast.xml` → 发布 GitHub Release。
不管 app 运行时逻辑,也不管安装器 UI(见 [安装器](../installer/README.md))。日常命令见 [运行手册](../../run.md)。

## 文件清单与关系
脚本(`scripts/`):
- `setup-ghostty.sh` — 下载固定版本 Zig 到 `.deps/`,拉固定 commit 的 Ghostty,构建 `Vendor/GhosttyKit.xcframework` + `Vendor/ghostty-resources/`。
- `build-core.sh` — `cargo build --release` 编 `core/`,包成 `Vendor/WorkbenchCore.xcframework`。
- `build-app.sh [debug|release] [--open]` — 调 `build-core.sh` + `swift build`,组装 `build/Seperate.app`(含 Sparkle.framework、`seperate-hook`、ghostty 资源),写 `Info.plist`,codesign。
- `build-installer.sh` — 把 `build/Seperate.app` 装进 `build/安装 Seperate.app`。
- `package-dmg.sh` — 出 `build/Seperate-<ver>.zip`(Sparkle 用)和 `build/Seperate-<ver>.dmg`(dmgbuild,venv 在 `.deps/dmgbuild`)。
- `dmg-settings.py` — dmgbuild 配置(窗口、图标位置),由 `package-dmg.sh` 传入。
- `make-installer-assets.swift` — 手动运行,生成 `Resources/Installer/` 下 DMG 背景和安装器图标(产物入库)。
- `make-appcast.sh` — 用 Sparkle `sign_update` 给 zip 签 EdDSA,写 `build/appcast.xml`。
- `release.sh <ver>` — push HEAD + 打 tag `v<ver>` 并推送,触发 `release.yml`。
- `release-local.sh [ver]` — 本机按 `release.yml` 同样步骤演练,读 `.secrets`,不打 tag、不上传。
- `setup-signing.sh` — 一次性:交互式校验证书/公证账号,写 `.secrets`,并(默认)上传为 GitHub Actions secrets。
- `sparkle-keys.sh` — 一次性:在登录钥匙串生成/复用 Sparkle 密钥对,私钥存为 secret `SPARKLE_PRIVATE_KEY`(本仓库已做过)。

CI(`.github/`):
- `workflows/ci.yml` — push main / PR / 手动:`deps` → `scripts/build-core.sh && swift test` → `scripts/package-dmg.sh` → 上传 DMG artifact(保留 14 天)。
- `workflows/release.yml` — push tag `v*.*.*`:版本 → 导入证书(可选)→ `build-app.sh release` → 公证 app(可选)→ `PACKAGE_ONLY=1 package-dmg.sh` → 公证 DMG(可选)→ 建 draft release → 签 zip 写 appcast 并上传 → 发布为 latest。
- `actions/deps/action.yml` — 复合 action:按 `setup-ghostty.sh` 去掉注释和空行后的哈希缓存 GhosttyKit(只改注释不会让缓存失效),未命中才跑该脚本;`rust-cache` 缓存 `core`。

`Package.swift` targets:
- `GhosttyKit`、`WorkbenchCore` — binaryTarget,指向 `Vendor/*.xcframework`(由上面两个 setup/build 脚本生成)。
- `Workbench` — 主 app(产品名显示为 Seperate),依赖上面两者 + Sparkle(SPM,`from: 2.10.0`)。
- `SeperateHook` — agent hook 转发器,打进 app 为 `Contents/MacOS/seperate-hook`。
- `SeperateInstaller` — 双击安装器。
- `WorkbenchTests` — 测试。

## 数据流
```
core/ (Rust) ──build-core.sh──▶ Vendor/WorkbenchCore.xcframework ─┐
Ghostty@pinned ──setup-ghostty.sh──▶ Vendor/GhosttyKit.xcframework ┤
                                                                    ▼
Sources/ ──build-app.sh (swift build + 组装 + codesign)──▶ build/Seperate.app
   ──[release.yml: notarytool + stapler]──▶
   ──package-dmg.sh──▶ build/Seperate-<ver>.zip
                    └─ build-installer.sh ▶ build/安装 Seperate.app ─dmgbuild▶ build/Seperate-<ver>.dmg
   ──[公证 DMG]──▶ gh release create --draft (dmg + zip)
   ──make-appcast.sh (sign_update + SPARKLE_PRIVATE_KEY)──▶ build/appcast.xml ──gh release upload──▶ 发布 latest
已安装 app ◀── SUFeedURL = releases/latest/download/appcast.xml ── Sparkle 校验 EdDSA 后更新
```

## 对外接口
- 首次准备:`scripts/setup-ghostty.sh`
- 构建:`scripts/build-app.sh debug|release [--open]`、`scripts/build-core.sh`
- 打包:`scripts/package-dmg.sh`(`PACKAGE_ONLY=1` 只打包已有 `build/Seperate.app`)
- 发布:`scripts/release.sh <X.Y.Z>`,然后 `gh run watch`
- 本地演练:`scripts/release-local.sh [X.Y.Z]`
- 一次性配置:`scripts/setup-signing.sh [--local-only] [owner/repo]`、`scripts/sparkle-keys.sh [owner/repo]`
- 素材:`swift scripts/make-installer-assets.swift`
- 环境变量:`VERSION`(默认 `0.1.0`)、`BUILD`(默认 `git rev-list --count HEAD`)、`CODESIGN_IDENTITY`(默认 `-` 即 ad-hoc)、`PACKAGE_ONLY`、`GITHUB_REPOSITORY`

## 注意事项
- **Secrets 只写名字**:`APPLE_CERTIFICATE`、`APPLE_CERTIFICATE_PASSWORD`、`APPLE_ID`、`APPLE_PASSWORD`、`APPLE_TEAM_ID`、`SPARKLE_PRIVATE_KEY`。GitHub 上是 Actions secrets;本地在 `.secrets`(gitignored,`KEY='value'` 行)。永远不要读取、打印或提交 `.secrets`。
- **Sparkle 公钥**写死在 `scripts/build-app.sh` 的 `SPARKLE_PUBLIC_KEY`(进 `Info.plist` 的 `SUPublicEDKey`);私钥在登录钥匙串(account `seperate`)和 secret `SPARKLE_PRIVATE_KEY`。重新生成密钥对而不同步公钥 → 所有已装用户无法验证更新。
- **ad-hoc vs Developer ID**:`CODESIGN_IDENTITY` 未设置即 ad-hoc(`codesign -s -`),DMG 用 `-unsigned` 背景(页脚提示 Gatekeeper 放行)。设了证书 secrets 才用 Developer ID + hardened runtime + timestamp;再有 `APPLE_ID/APPLE_PASSWORD/APPLE_TEAM_ID` 才公证。Sparkle 更新只认 EdDSA 签名,不依赖 Apple 签名。
- **`Vendor/`、`.deps/`、`build/`、`.build/`、`core/target/` 都是 gitignored**,由脚本生成。新 clone 必须先 `setup-ghostty.sh`;`swift build`/`swift test` 前必须先 `build-core.sh`。
- **版本号**:`CFBundleShortVersionString` = `VERSION`(发布时取 tag 去掉 `v`,必须是 `X.Y.Z`);`CFBundleVersion` = git 提交数。Sparkle 和安装器都按 `CFBundleVersion` 比新旧,所以 CI checkout 用 `fetch-depth: 0`,浅克隆会算错 build 号。
- **更新检查频率**:`SUScheduledCheckInterval` 设为一年,实际只在启动时和「检查更新…」时检查(见 `build-app.sh` 注释)。`README.md` 里「每天检查一次」的描述与当前代码不一致。
- **appcast 只有一个 item**(本次版本),下载 URL 固定为 `releases/download/v<ver>/<zip名>`;tag 名和 zip 名要对得上。
- **`release-local.sh` 必须与 `release.yml` 保持同步**;它会临时改钥匙串搜索列表,退出时恢复。
- `setup-ghostty.sh` 只支持 Apple Silicon;Ghostty commit 与 Zig 版本成对固定(Ghostty v1.3.x 的 Zig 0.15 链接不了 macOS 26 SDK);它会 unset 代理变量。改动此脚本的代码(非注释行)会让 CI 的 GhosttyKit 缓存失效并重编(约 8 分钟)。
- Codex 图标取自本机 `/Applications/ChatGPT.app`,不入库;CI 上没有则跳过。
- DMG 图标坐标 `(300, 190)` 同时出现在 `dmg-settings.py` 和 `make-installer-assets.swift`,改一处要改另一处。
- 发布、签名、公证类脚本只在用户明确要求时运行。
