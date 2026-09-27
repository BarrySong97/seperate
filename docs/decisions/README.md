# 决策日志(ADR)

记录重要技术/架构决策的「为什么」,防止 agent(或未来的人)推翻已定设计、重复踩坑。

## 怎么用
- 每条决策一个文件:`NNNN-<短标题>.md`(NNNN 递增,如 `0001-use-postgres.md`)。
- 复制 [0000-template.md](0000-template.md) 作为新条目。
- 在下方索引登记一行。
- 决策一旦写下尽量不改;要推翻就新增一条「取代 NNNN」的决策。

## archgate:给架构类决策配可执行规则
- 架构/边界类 ADR 应**配一条可执行规则**(linter 规则、结构测试,如 `*.rules.ts` / 一个 check 脚本)。
- 把 ADR 编号写进 linter 报错信息里,既拦住违规、又顺手「教育」agent 为什么。
- 原则:可执行规则承载「强制」,ADR 承载「为什么」。agent 能忽略文档,但 CI 失败绕不过去。

## 索引
| 编号 | 标题 | 状态 | 日期 |
|---|---|---|---|
| 0000 | [模板](0000-template.md) | — | — |
| 0001 | [终端用 libghostty](0001-libghostty-terminals.md) | 已采纳 | 2026-09-25 |
| 0002 | [Rust core 经 C ABI + JSON](0002-rust-core-c-abi-json.md) | 已采纳 | 2026-09-25 |
| 0003 | [Sparkle 仅启动时/手动检查更新](0003-sparkle-update-checks.md) | 已采纳 | 2026-09-25 |
| 0004 | [DMG 双击安装器与签名 secrets](0004-dmg-installer-and-signing.md) | 已采纳 | 2026-09-25 |
| 0005 | [日常只本地安装,发版由用户触发](0005-local-install-until-release.md) | 已采纳 | 2026-09-25 |
