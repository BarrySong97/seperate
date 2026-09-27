# Seperate website

The landing page and changelog. Next.js (App Router), Tailwind CSS 4 and TypeScript, exported as a fully static site into `out/`. Images and videos are hosted on Cloudflare R2.

```sh
pnpm install
pnpm dev          # http://localhost:3000
pnpm build        # static site in out/
```

## Layout

| Path | What |
| --- | --- |
| `src/app/page.tsx` | Landing page: demo video, feature sections, download |
| `src/app/changelog/page.tsx` | Changelog, one entry per minor release, newest first |
| `content/changelog/<version>.md` | Changelog entries (Markdown with frontmatter) |
| `content/changelog/_template.md` | Copy this for a new release (files starting with `_` are not published) |
| `src/components/mocks.tsx` | Drawings of the app's UI used on the landing page |
| `src/lib/site.ts` | Links, requirements line, homepage video URL |

Download buttons point to `releases/latest` on GitHub, and the version shown comes from the newest changelog entry.

## Writing a changelog entry

1. Copy `content/changelog/_template.md` to `content/changelog/0.2.0.md`.
2. Fill in the frontmatter (`version`, `date`, `title`, optional lead `media`) and the notes.
   - `### Heading` for each feature, `#### 改进` / `#### 修复` for the short lists.
   - An image or video on its own line: `![alt](https://…/file.webp)` or `![alt](https://…/clip.mp4)` (videos loop muted).
3. Patch releases (0.2.1, 0.2.2…) go in the same file under `patches:`; they fold into one box under the entry.

### How the notes are written (the default for every entry)

The changelog is for people who use Seperate, not for people who read its code.

- **Say what you can do now, not what changed in the code.** "在文件菜单（⌘N）里新建项目，可以顺便初始化 Git" — not "added `NewProjectSheet`", "new `wb_project_create` FFI", "refactored the store".
- **New features** get a `### Heading` each: what it does, where to find it (menu, button, shortcut).
- **`#### 改进`** for things that already existed and now work better, one line each, starting with a verb.
- **`#### 修复`** for bugs, written as before → after from the user's side: "拖动进度条时滑块会跳回去；现在可以正常拖动".
- **Patch notes** (`patches[].notes`) follow the same rules in one or two sentences.
- Leave out internal work nobody can see: refactors, tests, build scripts, CI, docs, dependency bumps.
- Only real screenshots and recordings; no placeholder images.

## Uploading media to R2

One-time: `cp .env.example .env` and fill in the R2 credentials (same keys as jade's `.env`; `R2_KEY_PREFIX=seperate` keeps this site's files in their own folder).

```sh
pnpm upload ~/Desktop/inbox.png ~/Desktop/demo.mp4
pnpm upload ~/Desktop/inbox.png --dry-run     # convert and show the URL without uploading
```

Images are converted to WebP (max 2400px wide); videos are uploaded as they are. File names are content hashes, so the same file always gets the same URL and it is cached forever. The script prints the URL and a ready-made `![]()` line.

For the homepage video, upload it and put the URLs in `site.heroVideo` in `src/lib/site.ts`. Until then the hero shows a still of the app.
