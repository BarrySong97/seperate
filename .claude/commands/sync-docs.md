---
description: 检查并修复文档漂移:跑 check-docs,按输出同步文件头 / 模块文档 / 失效引用
argument-hint: "[base-ref 可选,如 main]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---
跑文档同步检查,并把发现的问题**真实修好**(不是糊弄过检查)。

1. **运行检查**:
   - 若本次给了基准分支参数:`node scripts/check-docs.mjs --base $ARGUMENTS`(对比已提交差异)。
   - 否则:`node scripts/check-docs.mjs`(看未提交工作区)。
2. **按输出逐类修复**:
   - ❌ **缺 AI 文件头** → 给每个列出的源文件顶部加轻量头(`@purpose/@role/@deps/@gotcha`,见 `docs/file-headers/`),**不写函数签名**。
   - ❌ **失效引用** → 修正链接路径,或补回缺失的文件。
   - ⚠️ **疑似文档漂移** → 更新对应 `docs/modules/<module>/`(跨模块的更新 `docs/topics/`),让文档与这次代码改动一致。
3. **重跑直到干净**:再次运行命令,循环到没有 ❌(并尽量清掉 ⚠️)。
4. 🚨 **红线**:绝不为了通过检查而删检查、改 `check-docs.config.json` 放宽规则、塞占位或造假——必须真实同步。
