# Hook(seperate-hook 助手程序)

## 职责
一个独立的小命令行程序 `seperate-hook`:被 Claude Code hook / Codex `notify` 调用,把 Agent 事件归一化后通过分布式通知转发给正在运行的 Seperate。
不管:hook 的安装与包装脚本(Model 模块的 `AgentHooks`)、收到事件后的状态机(`Store.agentEvent`)。

## 文件清单与关系
- `Sources/SeperateHook/main.swift` — 全部逻辑:解析参数/stdin、提取消息、转发 Codex 用户原有 notify、写诊断日志、发通知
- 构建:`Package.swift` 中独立的 `SeperateHook` executable target(不依赖 Workbench);`scripts/build-app.sh` 把它拷进 `Seperate.app/Contents/MacOS/seperate-hook`
- 调用关系:`claude/codex 包装脚本 → seperate-hook → DistributedNotificationCenter("dev.seperate.agent-event") → Store.agentEvent`

## 数据流
1. 从环境变量 `SEPERATE_SESSION_ID` 取会话(Seperate 为自己开的每个终端设置);缺失或参数不足直接 `exit(0)`。
2. `seperate-hook claude`:stdin 读 hook JSON,取 `hook_event_name`、`notification_type`、`message`。`Stop` 无消息时从 `transcript_path` 尾部 256KB 找最后一条 assistant 文本;`AskUserQuestion` / `ExitPlanMode` 改写 kind 与提示语;`PermissionRequest` 生成 `"工具: 命令/路径"`。
3. `seperate-hook codex-notify '<json>'`:取最后一个参数,`agent-turn-complete` 映射为 `Stop`,消息取 `last-assistant-message`;若有 `SEPERATE_CODEX_NOTIFY`,用同一 payload 再调用用户原来的 notify 命令(不等待)。
4. 在 `$SEPERATE_BIN` 的上级目录(即数据目录)追加 `hook-events.log`,只保留约 200 行。
5. 发布分布式通知,userInfo 为字符串字典。

## 对外接口
- 命令行:`seperate-hook claude`(事件 JSON 走 stdin)、`seperate-hook codex-notify <json>`(JSON 为最后一个参数)。
- 输入环境变量:`SEPERATE_SESSION_ID`(必需)、`SEPERATE_BIN`(用于定位日志)、`SEPERATE_CODEX_NOTIFY`(用户原 notify,JSON 数组)。
- 输出事件:通知名 `dev.seperate.agent-event`(与 `AgentHooks.eventName` 必须一致),userInfo 键:`session`、`agent`(claude/codex)、`event`(Claude hook 名;Codex 回合结束为 `Stop`)、`kind`(notification_type,或 `AskUserQuestion` / `ExitPlanMode`)、`message`(截断到 400 字符)。

## 注意事项
- **提示语跟 app 同一种语言**:`AskUserQuestion` / `ExitPlanMode` 没有原文时的兜底文案用 hook 自己的 `tr`,语言取 `dev.workbench.app` 域的 `AppleLanguages`(没有就用系统语言),见 [ADR-0006](../../decisions/0006-bilingual-ui.md)。
- **绝不能打印到 stdout**:Claude 会把 hook 的 stdout 当作额外上下文喂给模型。测试 `testHelperForwardsEvents` 专门断言输出为空。
- **必须快、必须 exit 0**:任何失败都静默吞掉,绝不能阻塞或打断 Agent(Claude 侧 hook 超时设为 5 秒)。
- 独立 target,不能 import Workbench 的代码;通知名和 userInfo 键是与 `Store.agentEvent` 之间的**隐式协议**,两边改动要同步(并更新 `docs/topics/agent-hooks.md`)。
- 通知 `deliverImmediately: true`;App 没在运行时事件直接丢失,这是可接受的。
- 用户自己的 Codex `notify` 必须继续工作 —— 这是不修改用户配置、仅对本次启动加参数的前提。
- 详细链路见 [agent-hooks 专题](../../topics/agent-hooks.md)。
