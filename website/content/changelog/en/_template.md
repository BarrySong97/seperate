---
# Copy to en/<version>.md (e.g. 0.3.0.md) and write the Chinese entry in zh/<version>.md with the same
# version, date, media and patch versions. Files starting with "_" are not published.
version: 0.3.0
date: 2026-10-09
title: The one or two biggest new features
# Lead video or image, uploaded with `pnpm upload <file>`. Optional.
media:
  type: video
  src: https://<R2_PUBLIC_BASE>/seperate/<hash>.mp4
  poster: https://<R2_PUBLIC_BASE>/seperate/<hash>.webp
# Patch releases of this minor version, newest or oldest first (the page sorts them). Optional.
patches:
  - version: 0.3.1
    date: 2026-10-12
    notes: What was fixed: what used to happen, what happens now.
---

Two or three sentences: what problem this release solves. Write what users will notice, not how it's built.

### Name of feature one

What it does, where to find it, and its shortcut (`⌘K`).

![Screenshot of feature one](https://<R2_PUBLIC_BASE>/seperate/<hash>.webp)

### Name of feature two

Without an image, just a paragraph. A drawn mock of the app's UI works too: `![caption](mock:<name>)`.

#### Improvements

- One improvement per line, starting with a verb

#### Fixes

- What was fixed: what used to happen, what happens now
