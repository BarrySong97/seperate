# 0006. 中英双语界面:内联 `tr("中文", "English")`,重启生效

- 状态:已采纳
- 日期:2026-09-29

## 背景
Seperate 原来只有简体中文界面。要支持英文用户,且明确只支持两种语言(`en`、`zh-Hans`)。app 由 `scripts/build-app.sh` 手工组装,没有 Xcode 工程;界面文案约 335 条,散在 22 个 Swift 文件里,另有安装器和 `seperate-hook` 两个独立 target。

## 决策
- 每条界面文案在调用处写成一对:`tr("关闭 Tab", "Close Tab")`(`Sources/Workbench/App/L10n.swift`)。英文复数用 `plural(n, "tab")`。
- 语言启动时定一次:首选语言以 `zh` 开头 → 中文,否则英文。菜单「语言」可选 跟随系统 / 中文 / English,写入 app 自己域的 `AppleLanguages`,**重启后生效**(切换时提示重启)。
- `Info.plist` 声明 `CFBundleLocalizations = [en, zh-Hans]` 并放 `en.lproj` / `zh-Hans.lproj`,让 AppKit 和 Sparkle 自带的文字跟着 app 的语言走。
- 安装器跟随系统语言;DMG 里的文件名改为 `Install Seperate.app`,中文系统通过 `LSHasLocalizedDisplayName` 显示「安装 Seperate」。DMG 背景只有一张,文字中英双行。
- `seperate-hook` 读 `dev.workbench.app` 域的 `AppleLanguages`(没有就用系统语言),让通知正文和 app 同一种语言。
- Rust core 不产出界面文案:没有标题的会话返回空串,由 Swift 按语言补「Codex 会话 / Codex session」。
- 用户数据(Workspace 名、会话标题、worktree 别名)不翻译;只有新建时的默认值按语言。

## 理由
- 不用 `.xcstrings` / `Localizable.strings`:需要额外的编译和资源 bundle 拷贝步骤,而构建链是手写脚本;只有两种语言时,内联一对**不会漏译**(少一个参数编译不过),改文案时两种语言在同一行,review 一目了然。
- 不做即时切换:AppKit 视图和菜单大多只建一次,即时刷新要改遍每个视图,风险大;语言很少切换,重启一次可以接受。
- 用 `AppleLanguages` 而不是自定义键:这是 macOS 的标准机制,系统框架(Sparkle 更新窗口、文本菜单)会一起切换。

## 后果
- `L10nTests` 扫描 `Sources/`:不在 `tr(...)` 里的中文字符串字面量、`tr` 英文参数里的中文都会让测试失败。确实不该翻译的(语言自称、演示数据)在行尾标 `// l10n: <原因>`;按 `L10n.isChinese` 分支的中文专用格式(如日期)所在行豁免。
- 要加第三种语言时,得改成表驱动(`tr` 的调用点可以机械替换)。
- 官网的双语(英文在 `/`、中文在 `/zh`)见 `website/README.md`;官网 mock 里的英文界面文字要和 app 里的 `tr` 英文一致。
