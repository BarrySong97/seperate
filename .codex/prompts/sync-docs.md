<!--
  Codex custom prompt —— /prompts:sync-docs
  Codex 只扫 ~/.codex/prompts/(用户级,不随仓库共享),所以拷贝到那里使用(一份源、两边用):
      mkdir -p ~/.codex/prompts
      ln -sf "$PWD/.codex/prompts/sync-docs.md" ~/.codex/prompts/sync-docs.md
  调用:在 Codex 里输入 /prompts:sync-docs   (可在后面带基准分支,如 main)
  注:Codex 官方已把 custom prompts 标为 deprecated、推荐改用 skills;迁移后把本文件搬成 skill 即可。
-->
跑文档同步检查,并把发现的问题**真实修好**(不是糊弄过检查)。

1. **运行检查**:
   - 若给了基准分支(如 main):`node scripts/check-docs.mjs --base main`(对比已提交差异)。
   - 否则:`node scripts/check-docs.mjs`(看未提交工作区)。
2. **按输出逐类修复**:
   - ❌ **缺 AI 文件头** → 给每个列出的源文件顶部加轻量头(`@purpose/@role/@deps/@gotcha`,见 `docs/file-headers/`),**不写函数签名**。
   - ❌ **失效引用** → 修正链接路径,或补回缺失的文件。
   - ⚠️ **疑似文档漂移** → 更新对应 `docs/modules/<module>/`(跨模块的更新 `docs/topics/`),让文档与这次代码改动一致。
3. **重跑直到干净**:再次运行命令,循环到没有 ❌(并尽量清掉 ⚠️)。
4. 🚨 **红线**:绝不为了通过检查而删检查、放宽 `check-docs.config.json`、塞占位或造假——必须真实同步。
