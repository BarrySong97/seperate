export const repo = "https://github.com/BarrySong97/seperate";

export const site = {
  name: "Seperate",
  // Production origin: canonical links, sitemap, robots and Open Graph URLs are built from it.
  url: "https://sperate.4real.ltd",
  title: "Seperate — 所有 agent，一个窗口",
  keywords: ["Seperate", "Claude Code", "Codex", "coding agent", "AI 编程", "终端", "worktree", "macOS", "Ghostty", "多 agent"],
  description: "在一个窗口里并排运行 Claude Code、Codex 和终端，按项目和 worktree 管理，agent 需要你时提醒你。",
  repo,
  // Always the newest DMG; the release workflow publishes it, so this never needs updating.
  download: `${repo}/releases/latest`,
  releases: `${repo}/releases`,
  commits: `${repo}/commits/main`,
  requirements: "macOS 14+ · Apple Silicon · 免费",
  // Homepage demo video on R2 (`pnpm upload demo.mp4`). Empty: the page shows a still of the app instead.
  // "Separate 口播精剪 v3": 1080p30 H.264 + AAC, faststart; poster is the 0:02.2 frame ("我是 Separate 的开发者 Barry").
  heroVideo: {
    src: "https://blogassets.4real.ink/seperate/31a859912d1244c12b13d063.mp4",
    poster: "https://blogassets.4real.ink/seperate/8179cfae11b32637be46e965.webp",
  },
};
