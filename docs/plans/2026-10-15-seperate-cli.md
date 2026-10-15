# `seperate` 命令行(让 Agent 操控 Seperate)— 实现计划

- 日期:2026-10-15
- 关联 spec:无(需求来自对话:把 Seperate 开放给 AI 操控;外部编排器开的会话在 Seperate 里看不到)
- 状态:已批准并实现(socket 对同一用户全开放;`send` 在栏头显示来源;另加 `close`、`key`)

## 方案概述
新增一个随 App 打包的命令行程序 `seperate`,Agent(以及用户自己的脚本)用它在 Seperate 里**列会话、开新会话、往会话里输入、读屏幕、等它干完**。这样编排器不必自己用 SDK 在外面开会话,开出来的会话就跑在 Seperate 的终端里,带 hook 状态、进 Inbox,用户全程看得见。

- **通信**:App 在数据目录监听 Unix socket `seperate.sock`(权限 0600,`getpeereid` 校验同一用户),一行一个 JSON 的请求/应答。现有的分布式通知是单向的、拿不到返回值,不能复用。备选 XPC / HTTP 端口都更重,且 HTTP 端口对同机其他用户可见。
- **AI 怎么知道有它(已定:a + b)**:
  - (a) Seperate 开的每个终端把 `<dataDir>/cli/` 加到 `PATH` 前面,里面只有 `seperate` 一个链接;`seperate --help` 写成给 AI 看的用法说明(英文、带例子)。
  - (b) Claude 的包装脚本每次启动多加一个 `--append-system-prompt`,内容是几行简短说明(在 Seperate 里、有 `seperate` 命令、先跑 `seperate --help`)。只对这一次启动生效,和现在加 `--settings` 一样,不碰 `~/.claude`。Codex 用等价的 `-c` 配置项(见风险第 3 条)。

## 命令(v1)
所有命令都支持 `--json`;默认输出是给人和模型都好读的短文本。会话可以用 id、id 前缀或标题指定。

| 命令 | 作用 |
|---|---|
| `seperate list [--project P] [--all]` | Workspace → 项目 → Worktree → 会话,带状态(working / needs-input / done / failed / idle)、是否开着 tab |
| `seperate new claude\|codex\|shell [--cwd DIR] [--worktree NAME\|--new-worktree BRANCH] [--prompt TEXT] [--skip-permissions] [--split right\|down] [--focus]` | 在 Seperate 里开新会话,输出新会话 id;`--cwd` 默认取调用者当前目录,要落在已添加的项目里,否则报错并提示 `--add-project` |
| `seperate send <session> TEXT [--no-enter]` | 往会话的终端里输入一段文字并回车 |
| `seperate read <session> [--lines N]` | 读会话终端屏幕 + 回滚的最后 N 行(默认 200) |
| `seperate wait <session> [--until done\|needs-input\|any] [--timeout SEC]` | 阻塞到状态变化,返回状态和 hook 带回的最后一句话(Claude 的回答 / 它在问什么) |
| `seperate status <session>` | 单个会话的状态 + 最后一句话 |
| `seperate open <session> [--split right]` | 在界面里打开(切到它所在 Workspace) |
| `seperate refresh` | 立即重扫会话 |

一个 Claude 用 `new` + `wait` + `read` / `send` 就能在 Seperate 里编排其他 Claude / Codex。

## 涉及文件 / 模块
- `Package.swift` — 新 executable target `SeperateCLI`(产物名 `seperate`),和 `SeperateHook` 一样不依赖 Workbench
- `Sources/SeperateCLI/main.swift` — 解析参数、连 socket、打印结果、`--help`
- `Sources/Workbench/Control/ControlServer.swift`(新)— socket 监听、同用户校验、按行收发 JSON,请求回到主线程
- `Sources/Workbench/Control/ControlCommands.swift`(新)— 把每个命令翻译成 `Store` 调用(只调 Store 方法,不直接改状态)
- `Sources/Workbench/Model/Store.swift` — 补几个给命令用的入口:按路径找 worktree、不抢焦点地开会话、带初始 prompt 的会话、等待阶段变化的观察
- `Sources/Workbench/Model/Models.swift` — `AgentSession` 增加只在内存里的初始 prompt(和 `skipPermissions` 一样不进库),`launchCommand` 拼到命令末尾(shell 转义)
- `Sources/Workbench/Model/AgentHooks.swift` — 建 `<dataDir>/cli/seperate` 链接;`environment` 加 `SEPERATE_SOCKET` 并把 `cli/` 放进 `PATH`;Claude / Codex 包装脚本加系统提示
- `Sources/Workbench/Terminal/TerminalView.swift` — `sendText`(`ghostty_surface_text` + 回车)、`readText(lines:)`(`ghostty_surface_read_text`)
- `Sources/Workbench/App/AppDelegate.swift` — 启动 / 退出时开关 ControlServer
- `scripts/build-app.sh` — 把 `seperate` 拷进 `Contents/MacOS/`
- 文档:新模块 `docs/modules/cli/README.md`、`docs/topics/agent-hooks.md`(PATH 与系统提示)、`AGENTS.md` 导航与红线、新 ADR-0007(socket 协议与"只加 PATH + 单次系统提示"的取舍)
- 测试:`Tests/WorkbenchTests/ControlTests.swift`(新)

## 任务拆解
1. [ ] ADR-0007 + 协议定义:请求 `{v:1, cmd, args, caller}`(`caller` = 调用者的 `SEPERATE_SESSION_ID`,可空)→ 应答 `{ok, data}` / `{ok:false, error}`
2. [ ] `ControlServer`:socket 建在数据目录,启动时清掉残留的 sock 文件,0600 + `getpeereid`;每个连接一个请求,`wait` 可以挂着连接
3. [ ] `SeperateCLI`:参数解析、`--help`(给 AI 的完整说明)、`--json`;App 没在运行时明确报错并 exit 1
4. [ ] 只读命令:`list` / `status` / `refresh`
5. [ ] `new`:定位 worktree(`--new-worktree` 走 `Store.createWorktree`)、初始 prompt、开在哪一栏;默认**不抢键盘焦点**,`--focus` 才抢
6. [ ] `send` / `read`:TerminalView 两个新方法;禁止 `send` 给调用者自己的会话
7. [ ] `wait`:观察 `setPhase`,到达目标状态或超时就回应;连接断开时取消观察
8. [ ] `open`;包装脚本加系统提示;`PATH` 注入 `cli/`
9. [ ] 测试、文档、check-docs、构建并本地安装

## 风险 / 注意
1. **后台 tab 里的终端不会启动**:surface 要等视图进了窗口且 ≥40×40 才创建(终端红线),开在非活动 tab 里的 Agent 根本没启动,`send` / `read` / `wait` 都会落空。v1 让 `new` 把会话放成某一栏的**活动 tab**(默认:调用者所在栏右侧新分一栏;没有调用者就放在当前聚焦栏),只是不抢键盘焦点。离屏启动以后再说。
2. **PATH 不能带上 `claude` / `codex` 包装脚本**:`$SEPERATE_BIN` 里的包装脚本会让 Agent 自己再起的 `claude` 带上父会话的 `SEPERATE_SESSION_ID` 发 hook,状态会串到父会话上。所以 `seperate` 单独放在 `<dataDir>/cli/`,只把这个目录加进 PATH。
3. **Codex 的系统提示参数要先验证**:计划用 `-c developer_instructions=…`,实现前用当前 Codex 版本确认这个键存在;不存在的话 Codex 只做 (a)。
4. **`send` 的输入方式**:多行文本经 `ghostty_surface_text` 可能被当成粘贴,回车要单独发;要在 Claude Code 和 Codex 的 TUI 里各实测一次。
5. **socket 对同一用户的所有进程开放**:这样 Seperate 外面的编排器(比如 cc-control)也能用 `/Applications/Seperate.app/Contents/MacOS/seperate`。如果只想让 Seperate 自己的终端用,可以要求请求带上一个已知的 `caller`,但同一用户的进程本来就能读环境变量,挡不住,只是"约定"。**待你确认**:默认全开放。
6. **`send` 给别的 Agent 打字是否要确认**:v1 不弹确认,但在会话行 / tab 上显示"由 xxx 输入"一类的提示?**待你确认**,不做也不影响其他命令。
7. 新会话由 CLI 开出来,依然走 `makeSession` → `.reveal`,侧栏会自动展开到它;resume id 的认领仍按现有的 `adoptAgentIDs`(配合本次加的 `SessionWatcher`,约 1 秒内认领)。
8. **不改用户配置**:不往 `~/.claude` 写 skill、不改 `~/.codex/config.toml`;系统提示只在包装脚本里按次追加。

## 验证方式
- `ControlTests`:用临时数据目录起 `Store` + `ControlServer`,通过真实 socket 跑 `list` / `new shell` / `status`,并检查非同一用户、坏 JSON、App 不在运行时的报错
- `AgentHooksTests` 扩展:包装脚本含系统提示参数;`environment` 的 `PATH` 只多出 `cli/`,不含 `bin/`
- `seperate --help` 的输出快照测试(AI 靠它学会用法,改动要显式)
- 本地安装后由用户在 Seperate 里的 Claude 会话中让它"新开一个 Codex 修 X,等它完成后读结果",确认:新 tab 出现、状态点正确、`wait` 返回 Codex 的最后一句话
