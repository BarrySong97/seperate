# 0005. 日常改动只做本地安装,发版由用户触发

- 状态:已采纳
- 日期:2026-09-25

## 背景
用户在 Seperate 里跑 agent 开发 Seperate 本身;每个小改动都发版太重,而退出/重启 App 会杀掉正在运行的 agent 会话(发生过)。

## 决策
每完成一个功能/修复:`scripts/build-app.sh release` 构建,然后把 `/Applications/Seperate.app` **原地替换**(旧包移到 `~/.Trash`,新包移入),不启动、不退出 App,由用户自己重启。只有用户明确说「发版」时才跑 `scripts/release.sh <version>` / 打 tag / 推送。

## 理由
用户想立刻试用改动,又不想为每个小改动发布版本;同时绝不能打断正在运行的会话。

## 后果
agent 收尾时要说清「已构建 + 已安装,重启 Seperate 试用」;版本号在发版时向用户确认。
