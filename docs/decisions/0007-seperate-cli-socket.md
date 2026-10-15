# 0007. Agent 通过 `seperate` CLI + Unix socket 操控 App

- 状态:已采纳
- 日期:2026-10-15

## 背景
用户希望 AI 能操控 Seperate:开新会话、给它们派活、等结果、关掉。之前外部编排器只能自己用 Agent SDK 在 Seperate 外面开会话,这些会话没有 hook 状态,也不在用户眼前。约束:不能改用户的 `~/.claude` / `~/.codex` 配置;CLI 要能拿到返回值(`wait` 要阻塞到 Agent 一轮结束)。

## 决策
随 App 打包一个独立的 `seperate` 命令,经数据目录下的 Unix socket(一行 JSON 请求、一行 JSON 回复)和 App 通信。Agent 通过两条途径知道它:Seperate 的终端把只含 `seperate` 的 `<dataDir>/cli` 放进 PATH;Claude / Codex 每次启动由包装脚本追加一段简短的系统提示(`--append-system-prompt-file` / `developer_instructions`)。socket 对同一用户的所有进程开放。

## 理由
- 现有的分布式通知是单向的,拿不到回复;XPC 需要 Mach 服务注册,命令行工具用起来重;本地 HTTP 端口对同机其他用户可见,还要处理端口冲突。Unix socket 有文件权限 + `getpeereid` 天然限定同一用户,tmux / kitty / wezterm 都这样做。
- 让 AI 知道有这个工具:写 skill / MCP 需要改用户配置(红线);只靠 PATH 模型不会主动发现。"PATH + 单次系统提示"不碰配置、只影响 Seperate 启动的 Agent,`seperate --help` 承载完整用法。
- 全开放(而不是只许 Seperate 自己的终端)是用户的选择:外部编排器(如 cc-control)也要能用。同一用户的进程本来就能读环境变量,只许内部调用也只是约定,挡不住。

## 后果
- CLI 与 `ControlCommands` 之间多了一份隐式协议,需要 `ControlTests` 守住。
- Agent 输入到别的会话是可见的:栏头显示「由 X 打开 / X 输入」,用户打字即消失。
- 新会话必须作为某栏当前 Tab 打开才能启动,`seperate new` 会改布局(默认在调用者右侧分栏,不抢焦点)。离屏启动以后再考虑。
- Codex 的系统提示用 `developer_instructions`,用户自己设置了就不注入;Claude 的 `--system-prompt-snapshot` 默认会把首次启动的提示记进会话,resume 时沿用。
