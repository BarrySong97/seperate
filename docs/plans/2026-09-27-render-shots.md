# 官网截图模式(render-shots) — 实现计划

- 日期:2026-09-27
- 关联:官网首页 5 张功能配图 + OG 图改用 App 真实界面(替换 `website/src/components/mocks.tsx` 的手绘示意)

## 方案概述
给 Workbench 可执行文件加一个截图模式:`Workbench --render-shots <输出目录>`。这个模式不走 `AppDelegate`,在一个独立进程里用临时数据目录搭出真实的窗口与各面板,把演示项目(`~/SeperateDemo`)里**真实跑过的** Claude Code / Codex 会话按 App 平常的方式恢复到终端里,然后把每个界面渲染成 2x PNG 后退出。

- 截图是 App 把自己的视图渲染成位图(AppKit 视图用 `cacheDisplay`,终端读 Ghostty 渲染到的 IOSurface),**不是屏幕截图**,不需要屏幕录制权限。
- 从 `swift build` 产物运行,不是已安装的 Seperate.app:不碰用户正在用的实例(红线 1),`AgentHooks.helper` 为 nil 所以 agent 按原样启动、不注入 hook(红线 4)。
- 备选「在 Ghostty 里回放脚本化输出」已被用户否决:终端内容必须是真实 agent 会话。

## 涉及文件 / 模块
- `Sources/Workbench/App/main.swift` — 有 `--render-shots` 参数时改走 `ShotRenderer`,否则不变
- `Sources/Workbench/App/ShotRenderer.swift`(新)— 搭场景、等终端首屏稳定、逐个渲染、写 PNG、退出
- `Sources/Workbench/Model/Store.swift` — 截图模式开关:不启动 `Notifier`(避免通知授权弹窗);一个仅供截图的 `shotsSetPhase(_:_:need:)` 用来摆出「等你批准 / 已完成 / 运行中」这类收件箱状态(状态本来来自 hook,截图模式没有 hook)
- `Sources/Workbench/Core/Core.swift` — 截图模式下 `scanSessions` / `agentProjects` 只保留 `SEPERATE_SHOTS_ROOT` 之下的结果,用户其它项目和对话不会进图
- `scripts/render-shots.sh`(新)— `swift build` + 带好环境变量运行,输出到 `build/shots/`
- 文档:`docs/modules/app/README.md`、`docs/run.md`(怎么出图)、相关文件头
- 官网(另一步,出图并经用户确认后):上传 R2,首页 5 个功能区换成截图,OG 图换成真实窗口

## 任务拆解
1. [x] 可行性验证:离屏窗口里的 `TerminalView` 能否从 layer 的 IOSurface 读出像素;不行就改用「窗口放在屏幕上、透明度 0」再读
2. [x] Core 过滤 + Store 截图开关 + `shotsSetPhase`
3. [x] `ShotRenderer`:演示 workspace(lumen-notes / pixel-api / atlas-cli)、分栏布局、打开会话
4. [x] 处理 agent 首次进入新目录的「是否信任此目录」提示:渲染器替用户按一次回车(见风险)
5. [x] 出图:`hero`(OG 用,三栏完整窗口)、`panes`、`inbox`、`worktree`、`palette`(拼音搜索)、`import`
6. [x] 替换官网:OG 图用真实窗口截图;首页功能区几轮迭代后改为网页还原的界面卡片(`website/src/components/feature-cards.tsx`),不再用截图
7. [x] 文档、`swift test`、`check-docs`、本地安装

## 风险 / 注意
- **信任提示**:Claude Code / Codex 第一次在某个目录恢复会话会问是否信任。红线不允许我们改 `~/.claude` / `~/.codex`,所以由渲染器在终端里按回车接受;这等于用户在 agent 界面里点了一次「信任」,agent 会自己记下这 3 个演示目录的信任。**需要用户同意**;不同意的话,用户自己在这 3 个目录各开一次 `claude` / `codex` 即可。
- **终端像素**:Ghostty 用 Metal + IOSurface 渲染,`cacheDisplay` 拿不到;若 IOSurface 读取不可行,退路是短暂把截图窗口放到屏幕上(不抢焦点),渲染完即关。
- **会话恢复不花额度**:`claude --resume` / `codex resume` 只显示历史,不发请求;截图模式绝不向终端输入提示词(除第 4 步的回车)。
- 截图里会出现用户自己的 shell 提示符和 Ghostty 配置(真实环境),以及 `~/SeperateDemo/...` 路径。
- 正常启动路径完全不变;`--render-shots` 只在显式传参时生效。

## 实施记录
- 离屏窗口里的终端可以直接读 IOSurface,窗口不需要上屏;2x 靠把窗口放到 Retina 屏幕坐标上。
- `cacheDisplay` 不画:layer 的背景 / 边框 / 阴影、表格的行(只画了浮动的分组行)、正在编辑的输入框、`NSImageView`。浮层面板按「补画 layer 属性 → cacheDisplay → 单独画表格 / 输入框 / 图片」分层合成。
- Claude Code 的信任提示默认选项是 "No, exit":渲染器先把选择移到 Yes 再回车,并通过读屏确认。
- 渲染进程用干净环境启动(`env -i`),否则调用方的 `CODEX_API_KEY`、`CLAUDE_CODE_*` 会漏进被恢复的 agent。
- 收件箱原本是 NSPopover(只在窗口可见时弹出):截图里用真实的 `InboxView` 内容 + 一个仿 popover 的外框。

## 验证方式
- `scripts/render-shots.sh` 生成 6 张 PNG,逐张检查:终端有真实会话内容、无用户其它项目名、无权限弹窗出现
- `swift test` 全过(截图模式不影响现有测试);正常 `swift run` 启动行为不变
- 官网替换后本地 `pnpm build` 通过
