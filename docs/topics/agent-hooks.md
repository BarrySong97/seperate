# Agent hooks 事件链路

## 这是什么 / 为什么单独成篇
Seperate 在侧栏、Inbox、Dock 角标和系统通知里显示每个 Agent 会话"在干活 / 需要你 / 完成了 / 出错了"。这些状态来自一条跨进程、跨三个模块的链路:包装脚本给 Agent 临时挂 hook → 独立的 `seperate-hook` 进程 → 分布式通知 → `Store` 状态机 → UI。协议是隐式的(字符串事件名 + userInfo 键),两端分属不同 target,改一边很容易忘另一边,所以单独成篇。

## 涉及模块
- [model](../modules/model/README.md) · `Sources/Workbench/Model/AgentHooks.swift` — 安装包装脚本与 Claude hooks 文件,生成终端环境变量
- [hook](../modules/hook/README.md) · `Sources/SeperateHook/main.swift` — 把 hook/notify 载荷转成分布式通知
- [model](../modules/model/README.md) · `Sources/Workbench/Model/Store.swift` — `agentEvent` / `terminalNotification` / `userTyped` / `agentQuit` → `setPhase`;`inboxItems`
- [model](../modules/model/README.md) · `Sources/Workbench/Model/Notifier.swift` — 系统通知与 Dock 角标
- Terminal · `Sources/Workbench/Terminal/TerminalView.swift` — 提供 OSC 9/777 桌面通知(`onNotify`)、命令结束退出码(`onCommandFinished`)、用户按键(`onUserInput`)、响铃(`onAttention`)
- UI · `Sources/Workbench/UI/InboxPopover.swift`、`SidebarView.swift` — 读 `store.inboxItems()` / `status(of:)` 展示
- core · `core/src/sessions.rs` — 扫描 `~/.codex/sessions`、`~/.claude/projects` 的会话记录;与 hook 无直接关系,但 App 内新建的 Agent 要靠它拿到会话 id(见下文第 6 步)。`core/src/agents.rs` 是"从 Agent 导入项目",与本链路无关。

## 流程
1. **安装**(每次启动,`Store.init` → `AgentHooks.install()`,幂等):在数据目录写
   - `claude-hooks.json`:`UserPromptSubmit`、`PostToolUse`、`PermissionRequest`、`Notification`、`Stop`、`SessionEnd` 全量挂钩,`PreToolUse` 只匹配 `AskUserQuestion|ExitPlanMode`;每个 hook 执行 `"$SEPERATE_HOOK" claude`,超时 5 秒。
   - `bin/claude`:`exec claude --settings "$SEPERATE_CLAUDE_SETTINGS" "$@"`(用户自己的设置依然生效)。
   - `bin/codex`:`exec codex -c notify=["$SEPERATE_HOOK","codex-notify"]`,并强制开启 Codex 终端通知(osc9、always),用来捕获 "Approval requested"。
2. **启动终端**:`Store.terminal(for:)` 用 `AgentHooks.environment` 注入 `SEPERATE_SESSION_ID`(及 `WORKBENCH_SESSION`)、`SEPERATE_HOOK`、`SEPERATE_BIN`、`SEPERATE_CLAUDE_SETTINGS`、`SEPERATE_CODEX_NOTIFY`(从 `~/.codex/config.toml` 顶层读出的用户原 notify);`terminalCommand` 把 `claude …` / `codex …` 改写为 `"$SEPERATE_BIN"/claude …`。Shell 会话不走包装。官网截图模式(`SEPERATE_SHOTS_ROOT` 已设置)下,Claude 的命令末尾会追加一次性的 `--settings`,把状态栏换成空命令,用户自己的配置不变。
3. **Agent 触发**:Claude hook 以 stdin 传 JSON;Codex 在回合结束时以最后一个参数传 JSON。`seperate-hook` 归一化成 `{session, agent, event, kind, message}`,追加 `hook-events.log`,再 `DistributedNotificationCenter` 发 `dev.seperate.agent-event`。
4. **App 接收**:`Store` 在主队列监听该通知 → `agentEvent`,只处理本 App 当前有终端的会话:
   - `UserPromptSubmit` / `PostToolUse` → `working`
   - `PreToolUse`(仅问题/计划)/ `PermissionRequest` → `needsInput`,并记 `NeedKind`(question / plan / permission)
   - `Notification` → `needsInput`(忽略 `idle_prompt` 及"waiting for your input"空闲提醒)
   - `Stop` → `done(最后一句话)`;`SessionEnd` → 清除阶段
5. **其他信号补位**:
   - Codex 的 OSC 终端通知以 "Approval requested" 开头 → `needsInput(permission)`;Claude 的终端通知忽略(hook 更准);Shell 的通知/响铃 → `attention`(bell)。
   - 用户在 `needsInput` 时打字 → 回到 `working`;Codex 没有"提交 prompt"hook,在其提示符按回车即视为开始新一轮。
   - Agent 命令退出:非 0 且不是 130(^C)→ `failed(code)`,否则清除。
6. **会话 id 认领**:hook 不带会话 id。新建 Agent 的 resume id 由定时 `refresh()` 扫描 `sessions.rs` 结果后 `adoptAgentIDs()` 按 kind + cwd + 时间匹配得到。
7. **展示**:`setPhase` 更新 `phase` / `phaseSince`,刷新 Dock 角标(`waitingIDs` 数量),对用户**看不到**的会话发系统通知(需要确认、出错、以及耗时 ≥30 秒的完成),然后 `resort` 让等待中的会话在侧栏上浮并 `notify`。Inbox 按 needs / review / working 分组;以问号结尾的完成消息归入 needs(视为在提问)。点击通知 → `Notifier.onOpen` → 切到对应工作区/打开 tab。

## 注意事项
- **绝不修改用户的 Claude/Codex 配置文件**。一切通过包装脚本对单次启动加参数实现;用户原有的 Codex `notify` 由 `seperate-hook` 转调,必须保持可用。
- **`seperate-hook` 不得向 stdout 输出、必须永远 exit 0**(Claude 会把 stdout 当上下文;失败不能卡住 Agent)。
- 通知名 `dev.seperate.agent-event` 与 userInfo 键(`session/agent/event/kind/message`)是 `SeperateHook` 与 `Store.agentEvent` 间的隐式协议;改任一端都要同步,并跑 `AgentHooksTests`。
- 只在 `.app` 包内生效:`AgentHooks.helper` 找不到 `Contents/MacOS/seperate-hook` 时不装 hook、Agent 以原命令启动;`Notifier` 在包外同样不工作。用 `swift run` 调试时看不到状态变化是正常的。
- `PermissionRequest` 与 `Notification` 常对同一问题各来一次:`setPhase` 在已是 `needsInput` 时只更新消息、不重复提醒;"问题/计划"标签优先于"权限"标签。
- 当前正看着的会话(App 在前台且其 tab 在活动工作区可见)不发横幅;完成/失败直接视为已读;但需要确认时仍播放提示音。
- 排查时先看数据目录下的 `hook-events.log`(最近约 200 条),以及 `os.Logger` 子系统 `dev.seperate`、类别 `agent`。
