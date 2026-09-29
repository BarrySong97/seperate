import fs from "node:fs";
import path from "node:path";
import matter from "gray-matter";
import { langs, type Lang } from "@/i18n";

/**
 * One file per minor release and language: content/changelog/en/<version>.md and zh/<version>.md.
 * Frontmatter holds the version, date, title, lead media and patch releases; the body is the notes.
 * Both languages must list the same releases with the same dates and patch versions, or the build fails.
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

const root = path.join(process.cwd(), "content/changelog");

const semver = (v: string) => v.split(".").map(Number);
function compareDesc(a: string, b: string) {
  const [x, y] = [semver(a), semver(b)];
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return (y[i] ?? 0) - (x[i] ?? 0);
  return 0;
}

// gray-matter turns an unquoted YYYY-MM-DD into a Date; keep dates as plain strings.
const day = (d: unknown) => (d instanceof Date ? d.toISOString().slice(0, 10) : String(d));

function load(lang: Lang): Release[] {
  const dir = path.join(root, lang);
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".md") && !f.startsWith("_"))
    .map((f) => {
      const { data, content } = matter(fs.readFileSync(path.join(dir, f), "utf8"));
      // Usually a YAML slip, e.g. an unquoted value containing ": " (use `notes: >-` for long text).
      if (!data.version || !data.date || !data.title) throw new Error(`content/changelog/${lang}/${f}: frontmatter needs version, date and title`);
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

/** What must match across languages: versions, dates, patch versions and dates. */
const shape = (rs: Release[]) =>
  rs.map((r) => `${r.version}@${r.date}[${r.patches.map((p) => `${p.version}@${p.date}`).join(",")}]`).join("\n");

let cache: Record<Lang, Release[]> | undefined;
function all(): Record<Lang, Release[]> {
  if (cache) return cache;
  const loaded = Object.fromEntries(langs.map((l) => [l, load(l)])) as Record<Lang, Release[]>;
  const [first, ...rest] = langs;
  for (const l of rest) {
    if (shape(loaded[l]) !== shape(loaded[first])) {
      throw new Error(
        `content/changelog: ${first}/ and ${l}/ disagree. Every release (and patch) needs an entry in both languages ` +
          `with the same version and date.\n${first}:\n${shape(loaded[first])}\n${l}:\n${shape(loaded[l])}`,
      );
    }
  }
  return (cache = loaded);
}

export function getReleases(lang: Lang): Release[] {
  return all()[lang];
}

/** Newest version, counting patches: shown on download buttons. */
export function latestVersion(): string {
  const [newest] = getReleases("en");
  return newest?.patches[0]?.version ?? newest?.version ?? "";
}
