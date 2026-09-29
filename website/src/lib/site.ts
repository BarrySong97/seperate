export const repo = "https://github.com/BarrySong97/seperate";

// Language-neutral facts; titles, descriptions and other copy live in src/i18n/.
export const site = {
  name: "Seperate",
  // Production origin: canonical links, sitemap, robots and Open Graph URLs are built from it.
  url: "https://seperate.vercel.app",
  repo,
  // Always the newest DMG; the release workflow publishes it, so this never needs updating.
  download: `${repo}/releases/latest`,
  releases: `${repo}/releases`,
  commits: `${repo}/commits/main`,
  // Homepage demo video on R2 (`pnpm upload demo.mp4`). Empty: the page shows a still of the app instead.
  // "Separate 口播精剪 v3": 1080p30 H.264 + AAC, faststart; poster is the 0:02.2 frame ("我是 Separate 的开发者 Barry").
  heroVideo: {
    src: "https://blogassets.4real.ink/seperate/31a859912d1244c12b13d063.mp4",
    poster: "https://blogassets.4real.ink/seperate/8179cfae11b32637be46e965.webp",
  },
};
