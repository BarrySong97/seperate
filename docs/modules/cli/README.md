# CLI(`seperate` 命令 + App 内的控制 socket)

## 职责
让 Agent(以及用户自己的脚本)操控 Seperate:列会话、在 Seperate 里开新的 Claude / Codex / Shell 会话、往会话里输入或按键、读终端内容、等 Agent 一轮结束、打开 / 关闭会话。开出来的会话就是普通的 Seperate 会话(有 hook 状态、进 Inbox、用户看得见)。
不管:会话 / 布局状态本身(全部经 `Store` 的方法改)、hook 事件链路([agent-hooks](../../topics/agent-hooks.md))、终端渲染。

## 文件清单与关系
- `Sources/SeperateCLI/main.swift` — `seperate` 命令:解析参数、`--help`(写给模型看的用法)、连 socket 发一行 JSON、打印回复;独立 target,不链接 App 代码
- `Sources/Workbench/Control/ControlServer.swift` — 数据目录下的 Unix socket `seperate.sock`:0600、`getpeereid` 只收同一用户;每个连接一个请求,交给 handler 后写回一行 JSON
- `Sources/Workbench/Control/ControlCommands.swift` — 每个命令的实现(list / status / new / send / key / read / wait / open / close / refresh),只调 `Store` 的方法
- 相关:`Store`(`startSession` / `remoteType` / `remoteKey` / `reports` / `remoteNotes`)、`TerminalView`(`typeText` / `pressKey(modifiers:)` / `recentText`)、`AgentHooks`(PATH 与 Agent 系统提示)、`PaneHeaderView`(「由 X 打开 / X 输入」)
- 打包:`scripts/build-app.sh` 把 `SeperateCLI` 拷成 `Contents/MacOS/seperate-cli`;`AgentHooks.install` 在 `<dataDir>/cli/seperate` 建指向它的链接
- 调用关系:`Agent → seperate(PATH 上的链接)→ seperate.sock → ControlServer → ControlCommands(主线程)→ Store → TerminalView / 布局 / 侧栏`

## 数据流
1. **发现**:Seperate 开的每个终端,`AgentHooks.environment` 把 `<dataDir>/cli` 放在 `PATH` 最前,并设 `SEPERATE_SOCKET`、`SEPERATE_CLI_DIR`、`SEPERATE_AGENT_PROMPT`;包装脚本再 `export PATH` 一次(防止用户 shell 配置重写 PATH)。Claude 每次启动加 `--append-system-prompt-file <dataDir>/agent-prompt.md`;Codex 加 `-c developer_instructions=…`(用户自己在 `~/.codex/config.toml` 顶层设了就不加)。只对这一次启动生效,不改用户配置。
2. **请求**:`seperate` 发 `{"v":1,"cmd","args","caller","cwd","origin"}` 一行。`caller` 取 `SEPERATE_SESSION_ID`(从 Seperate 终端里调用时有);`origin` 是最近的非 shell 祖先进程名,用于界面上显示"谁输入的"。
3. **处理**:`ControlServer` 在后台线程读一行,交给主线程的 `ControlCommands.handle`;回复 `{"ok":true,"data":{…},"text":"…"}` 或 `{"ok":false,"error":"…"}`。CLI 默认打印 `text`,`--json` 打印 `data`。
4. **开会话**(`new`):按 `--cwd`(默认调用者当前目录,两边都按真实路径比较)找所在 Worktree,`--worktree` / `--new-worktree` 可改;`Store.startSession` 把会话放在调用者所在栏右侧的新栏(`--down` 下方、`--tab` 同栏 Tab),**键盘焦点不动**(`--focus` 才抢)。`--prompt` 写进 `<dataDir>/prompts/<id>.txt`,启动命令是 `claude -- "$(cat '<file>')"`(Shell 是 `eval "$(cat …)"`),只在第一次启动用,会话结束时删除,App 启动时整个目录清空。
5. **等待**(`wait`):`Store.setPhase` 每次阶段变化都追加一条带全局序号的 `AgentReport`(每会话留最近 20 条,即使界面已把"完成"标记为已读也在)。`wait` 从该会话最后一次 `new` / `send` / `key` 时的序号往后找第一条 done / failed / exited / needs-input(`--until done` 跳过 needs-input),找不到就挂着连接观察 Store,直到命中、会话被关闭或超时(默认 110 秒,CLI 退出码 2)。
6. **输入**(`send` / `key`):`ghostty_surface_text` 送文字(程序开了 bracketed paste 时是一次粘贴,多行仍是一条消息),0.15 秒后再按回车;记 `remoteNotes[id]`,栏头显示「由 X 打开 / X 输入 · 时间」,用户在该终端里打字即消失。

## 对外接口
- 命令行:见 `seperate --help`(唯一权威用法;`ControlTests.testCLIBinaryEndToEnd` 检查各命令都写在帮助里)。退出码:0 成功、1 错误、2 `wait` 超时、3 Seperate 没在运行。
- 会话引用:完整 id、Agent 会话 id、它们或 8 位短 handle 的唯一前缀,`self` 表示调用者自己。
- 协议版本 `ControlCommands.protocolVersion = 1`;CLI 与 App 不匹配时提示重启 Seperate。

## 注意事项
- **CLI ↔ ControlCommands 是隐式协议**(请求键 `v/cmd/args/caller/cwd/origin`、每个命令的 args 键、回复 `ok/data/text/error`、`data.timedOut`)。两边分属不同 target,改一边要同步另一边并跑 `ControlTests`。
- **新会话必须是某栏当前显示的 Tab**:终端只在视图进了窗口且 ≥40×40 时才启动(terminal 模块红线),放在后台 Tab 里 Agent 根本不会跑,`send` / `read` / `wait` 都会落空。
- **PATH 里只能有 `cli/`,不能有 `bin/`**:`bin/` 里是 claude / codex 包装脚本,Agent 自己再起的 `claude` 会带着父会话的 `SEPERATE_SESSION_ID` 发 hook,状态会串到父会话上(`AgentHooksTests.testCLIOnPathAndAgentPrompt` 断言)。
- **包内文件名不能叫 `seperate`**:磁盘大小写不敏感,会覆盖主程序 `Contents/MacOS/Seperate`;所以叫 `seperate-cli`,PATH 上的链接才叫 `seperate`。
- **socket 对同一用户的所有进程开放**(用户确认):Seperate 外面的编排器也能用 `/Applications/Seperate.app/Contents/MacOS/seperate-cli`。另一个活着的 Seperate(比如 demo)已占着 socket 时不抢。
- **不允许对自己**:`send` / `key` / `wait` 拒绝调用者自己的会话;`close` 自己要 `--force`。
- 测试里 `NSApp` 为 nil,涉及 Agent 阶段的测试要先 `_ = NSApplication.shared`;socket 路径要短(`sun_path` 约 104 字节),测试用 `sp-<8位>.sock`。
- 设计取舍见 [ADR-0007](../../decisions/0007-seperate-cli-socket.md),实现计划见 [docs/plans/2026-10-15-seperate-cli.md](../../plans/2026-10-15-seperate-cli.md)。
