# 安装器(SeperateInstaller)

## 职责
DMG 里那个双击安装的「安装 Seperate.app」:把随包携带的 `Seperate.app` 装进 `/Applications`(不可写时退到 `~/Applications`),必要时先让正在运行的 Seperate 退出,装完可顺手推出安装盘。
只管**首次安装 / 手动覆盖安装**;装好之后的版本升级走应用内 Sparkle,不经过这里。打包、签名、DMG 布局见 [构建与发布](../release/README.md)。

## 文件清单与关系
- `Sources/SeperateInstaller/main.swift` — 入口:解析 `--install-to` / `--payload` / `--snapshot`,无窗口安装或启动窗口。
- `Sources/SeperateInstaller/Installation.swift` — 安装动作本身(选目标目录、暂存复制、去 quarantine、原子替换),不含 UI。
- `Sources/SeperateInstaller/InstallerWindow.swift` — `InstallerController`:单窗口状态机 + 进度条 + 退出运行中的 app + 推出 DMG + 设计截图。
- 调用关系:`main.swift → InstallerController → Installation.run()`;`--install-to` 时 `main.swift → Installation.run()` 直接执行。
- 打包方:`scripts/build-installer.sh` 把 `build/Seperate.app` 塞进 `build/安装 Seperate.app/Contents/Resources/`,由 `scripts/package-dmg.sh` 调用。

## 数据流
1. 载荷:默认 `Bundle.main.resourceURL/Seperate.app`,或 `--payload <APP>` 指定。
2. 版本判断:读载荷与已装 app 的 `Info.plist`(`CFBundleShortVersionString` 展示、`CFBundleVersion` 比较)。已装 build 号更大 → `newerInstalled` 步骤,不覆盖。
3. 用户点「安装/更新」:若检测到 bundle ID `dev.workbench.app` 在运行 → `quitFirst`,点「退出并安装」后调 `terminate()`(走 app 正常退出流程,有终端会弹确认),轮询最多 30 秒。
4. `Installation.run()`:复制到目标目录下的 `.Seperate-installing-<UUID>.app` → `xattr -dr com.apple.quarantine` → `replaceItemAt`(已存在)或 `moveItem`(首次)。失败时原版本不动,暂存目录由 `defer` 清掉。
5. 进度:后台线程复制,主线程每 0.1s 统计暂存目录大小 / 载荷大小(封顶 0.98)。
6. 完成:可「打开 Seperate」;若运行自 `/Volumes/...` 且勾选「完成后推出安装盘」,退出后 1 秒 `hdiutil detach`。

## 对外接口
- 双击运行:窗口流程 `welcome → quitFirst → installing → done`(另有 `newerInstalled`、`failed`)。
- `SeperateInstaller --install-to <DIR> [--payload <APP>]`:无窗口安装,成功打印目标路径并 exit 0,失败 exit 1。
- `SeperateInstaller --snapshot <DIR> [--payload <APP>]`:把 6 个步骤各渲染成 PNG(设计检查用),不显示窗口。
- 构建:`swift build -c release --product SeperateInstaller`;成品由 `scripts/build-installer.sh` 组装(需先 `scripts/build-app.sh release`)。

## 注意事项
- `Installation.bundleID`(`dev.workbench.app`)必须与 `scripts/build-app.sh` 写入的 `CFBundleIdentifier` 一致,否则检测不到运行中的 app。
- 暂存目录必须和目标在同一目录(同一卷),`replaceItemAt` 才是原子替换;不要改成系统临时目录。
- 去 quarantine 是有意为之:用户已经信任了安装器,装好的 app 不应再被 Gatekeeper 拦第二次。
- 直接 `swift run SeperateInstaller` 时 bundle 里没有载荷,必须带 `--payload build/Seperate.app`。
- **不要在开发机上对真实 `/Applications` 跑安装器**:它会让正在运行的 Seperate 退出(用户在里面跑着 agent)。验证用 `--install-to <临时目录>` 或 `--snapshot`。
- `main.swift` 注释说 `--install-to` 供 CI 和测试使用,但目前 `ci.yml` 与 `Tests/` 都没有调用它。
- UI 文案为中文,配色硬编码为 app 的 Bone 主题(`InstallerController.C`),改主题时两边要一起改。
- 安装器图标与 DMG 背景由 `scripts/make-installer-assets.swift` 生成到 `Resources/Installer/`。
