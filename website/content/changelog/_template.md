---
# Copy to <version>.md (e.g. 0.2.0.md). Files starting with "_" are not published.
version: 0.2.0
date: 2026-10-09
title: 一两个最大的新功能
# Lead video or image, uploaded with `pnpm upload <file>`. Optional.
media:
  type: video
  src: https://<R2_PUBLIC_BASE>/seperate/<hash>.mp4
  poster: https://<R2_PUBLIC_BASE>/seperate/<hash>.webp
# Patch releases of this minor version, newest or oldest first (the page sorts them). Optional.
patches:
  - version: 0.2.1
    date: 2026-10-12
    notes: 修好了什么：以前会怎样，现在会怎样。
---

两三句话：这个版本解决了什么问题。写用户能感受到的变化，不写实现。

### 功能一的名字

这个功能能做什么，在哪里找到它，快捷键是什么（`⌘K`）。

![功能一截图](https://<R2_PUBLIC_BASE>/seperate/<hash>.webp)

### 功能二的名字

没有配图时就只写一段。视频也可以这样放：`![演示](…/clip.mp4)`。

#### 改进

- 一行一个改进，动词开头

#### 修复

- 修好了什么：以前会怎样，现在会怎样
