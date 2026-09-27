import fs from "node:fs";
import path from "node:path";
import matter from "gray-matter";

/**
 * One file per minor release in content/changelog/<version>.md.
 * Frontmatter holds the version, date, title, lead media and patch releases; the body is the notes.
 */
export type Patch = { version: string; date: string; notes: string };
/** Lead media of an entry: a video (.mp4/.webm/.mov) or an image, as printed by `pnpm upload`. */
export type Media = { src: string; poster?: string; alt?: string; width?: number; height?: number; thumbhash?: string };
export type Release = {
  version: string;
  date: string;
  title: string;
  media?: Media;
  patches: Patch[];
  body: string;
};

const dir = path.join(process.cwd(), "content/changelog");

const semver = (v: string) => v.split(".").map(Number);
function compareDesc(a: string, b: string) {
  const [x, y] = [semver(a), semver(b)];
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return (y[i] ?? 0) - (x[i] ?? 0);
  return 0;
}

// gray-matter turns an unquoted YYYY-MM-DD into a Date; keep dates as plain strings.
const day = (d: unknown) => (d instanceof Date ? d.toISOString().slice(0, 10) : String(d));

export function getReleases(): Release[] {
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".md") && !f.startsWith("_"))
    .map((f) => {
      const { data, content } = matter(fs.readFileSync(path.join(dir, f), "utf8"));
      return {
        version: String(data.version),
        date: day(data.date),
        title: String(data.title),
        media: data.media as Media | undefined,
        patches: ((data.patches ?? []) as Patch[])
          .map((p) => ({ ...p, version: String(p.version), date: day(p.date) }))
          .sort((a, b) => compareDesc(a.version, b.version)),
        body: content.trim(),
      };
    })
    .sort((a, b) => compareDesc(a.version, b.version));
}

/** Newest version, counting patches: shown on download buttons. */
export function latestVersion(): string {
  const [newest] = getReleases();
  return newest?.patches[0]?.version ?? newest?.version ?? "";
}

export function formatDate(iso: string) {
  const [y, m, d] = iso.split("-").map(Number);
  return `${y} 年 ${m} 月 ${d} 日`;
}
