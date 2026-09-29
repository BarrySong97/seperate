# Seperate website

The landing page and changelog. Next.js (App Router), Tailwind CSS 4 and TypeScript, exported as a fully static site into `out/`. Images and videos are hosted on Cloudflare R2.

```sh
pnpm install
pnpm dev          # http://localhost:3000
pnpm build        # static site in out/
```

## Deploying (Vercel)

The site is a static export, so Vercel only has to run the build and serve `out/`. `vercel.json` says so:
pnpm (the version in `package.json#packageManager`, 10.14.0) installs from the lockfile, `pnpm build` runs,
`out/` is published, `/changelog` is served from `changelog.html` (clean URLs), and hashed assets under
`/_next/static/` are cached for a year.

In the Vercel project settings:

| Setting | Value |
| --- | --- |
| Root Directory | `website` |
| Framework Preset | Other (vercel.json sets `framework: null`) |
| Build / Install / Output | leave empty: vercel.json decides (`pnpm build`, `pnpm install --frozen-lockfile`, `out`) |
| Node.js | 20 or newer |
| Domain | `seperate.vercel.app` (must match `site.url` in `src/lib/site.ts`; change both together) |

No environment variables are needed to build: R2 credentials are only for `pnpm upload` on your machine.

## Layout

The site is in English and Chinese. English lives at `/` and `/changelog`, Chinese at `/zh` and `/zh/changelog`; every page exists in both, and the nav links to the same page in the other language.

| Path | What |
| --- | --- |
| `src/i18n/en.ts`, `src/i18n/zh.ts` | All copy, one dictionary per language. `zh.ts` must have exactly the keys of `en.ts` (a missing string is a type error) |
| `src/i18n/index.ts`, `src/i18n/client.tsx` | `Lang`, `dict(lang)`, `localePath(lang, path)`; `useDict()` for client components |
| `src/app/(en)/…`, `src/app/(zh)/zh/…` | The two sites. Each route group is its own root layout, so `<html lang>` is `en` / `zh-CN` |
| `src/views/home.tsx`, `src/views/changelog.tsx` | The pages themselves, shared by both languages (they take `lang`) |
| `src/lib/meta.ts` | Titles, canonical URLs, hreflang alternates and social cards per language |
| `content/changelog/en/<version>.md`, `content/changelog/zh/<version>.md` | Changelog entries (Markdown with frontmatter), one file per release and language |
| `content/changelog/{en,zh}/_template.md` | Copy these for a new release (files starting with `_` are not published) |
| `src/components/mocks.tsx`, `feature-cards.tsx`, `changelog-mocks.tsx` | Drawings of the app's UI; their text follows the page's language (`ui` in the dictionaries) |
| `src/components/lang-hint.tsx` | On English pages, a dismissible "切换到中文" bar for browsers that prefer Chinese (no redirect) |
| `src/lib/site.ts` | Language-neutral links and the homepage video URL |
| `public/og-zh.png` | Social card image. It has Chinese text, and English pages use it too until an `og-en.png` exists (switch it in `src/lib/meta.ts`) |

Download buttons point to `releases/latest` on GitHub, and the version shown comes from the newest changelog entry.

## Writing a changelog entry

Every release is written in both languages. The build fails if a version, date or patch exists in one language but not the other.

1. Copy `content/changelog/en/_template.md` to `content/changelog/en/0.3.0.md` and `content/changelog/zh/_template.md` to `content/changelog/zh/0.3.0.md`.
2. Fill in the frontmatter (`version`, `date`, `title`, optional lead `media`) and the notes. `version`, `date`, `media` and the patch versions/dates are the same in both files; `title`, the body and `patches[].notes` are translated.
   - `### Heading` for each feature, `#### Improvements` / `#### Fixes` (`#### 改进` / `#### 修复`) for the short lists.
   - An image or video on its own line: `![alt](https://…/file.webp)` or `![alt](https://…/clip.mp4)` (videos loop muted).
   - Long patch notes with a `: ` in them need `notes: >-` and the text on the next line, or YAML misreads them.
3. Patch releases (0.3.1, 0.3.2…) go in the same files under `patches:`; they fold into one box under the entry.

### How the notes are written (the default for every entry, in both languages)

The changelog is for people who use Seperate, not for people who read its code. Write the English and the Chinese notes as natural text in each language, not word-for-word translations.

- **Say what you can do now, not what changed in the code.** "Create a project from the File menu (⌘N) and optionally run git init" / "在文件菜单（⌘N）里新建项目，可以顺便初始化 Git" — not "added `NewProjectSheet`", "new `wb_project_create` FFI", "refactored the store".
- **New features** get a `### Heading` each: what it does, where to find it (menu, button, shortcut).
- **`#### Improvements` / `#### 改进`** for things that already existed and now work better, one line each, starting with a verb.
- **`#### Fixes` / `#### 修复`** for bugs, written as before → after from the user's side: "The slider jumped back while you dragged it; now it follows your finger" / "拖动进度条时滑块会跳回去；现在可以正常拖动".
- **Patch notes** (`patches[].notes`) follow the same rules in one or two sentences.
- Leave out internal work nobody can see: refactors, tests, build scripts, CI, docs, dependency bumps.
- Only real screenshots and recordings, or a drawn mock of the app's UI; no placeholder images.
- **Mocks**: `![caption](mock:<name>)` draws a piece of the app's UI in HTML (`src/components/changelog-mocks.tsx`, same style as the homepage feature cards). Add a new `<name>` there for a new feature; copy menu titles and order from `Sources/Workbench/UI/Menus.swift`, and put the text in the `ui` section of both dictionaries so the drawing follows the page's language.

## Uploading media to R2

One-time: `cp .env.example .env` and fill in the R2 credentials (same keys as jade's `.env`; `R2_KEY_PREFIX=seperate` keeps this site's files in their own folder).

```sh
pnpm upload ~/Desktop/inbox.png ~/Desktop/demo.mp4
pnpm upload ~/Desktop/inbox.png --dry-run     # convert and show the URL without uploading
```

Images are converted to WebP (max 2400px wide); videos are uploaded as they are. File names are content hashes, so the same file always gets the same URL and it is cached forever. The script prints the URL and a ready-made `![]()` line.

For the homepage video, upload it and put the URLs in `site.heroVideo` in `src/lib/site.ts`. Until then the hero shows a still of the app.
