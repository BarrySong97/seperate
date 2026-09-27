// Uploads changelog / site media to Cloudflare R2 and prints the public URLs to paste into Markdown.
//   pnpm upload <file...> [--dry-run]
// Images are converted to WebP (max 2400px wide) with a thumbhash blur placeholder;
// videos (.mp4 .webm .mov) are uploaded as they are.
// Keys are content hashes (<prefix>/<hash>.<ext>): the same file always gets the same URL, so the
// objects are cached forever and re-uploading is harmless.
// Credentials come from .env (see .env.example). Same approach as jade's scripts/lib/r2.mjs.
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { basename, extname } from "node:path";
import { AwsClient } from "aws4fetch";
import sharp from "sharp";
import { rgbaToThumbHash } from "thumbhash";

const IMAGE = new Set([".png", ".jpg", ".jpeg", ".webp", ".gif", ".heic", ".tiff"]);
const VIDEO = { ".mp4": "video/mp4", ".webm": "video/webm", ".mov": "video/quicktime" };

function loadEnv(path = ".env") {
  const env = { ...process.env };
  if (!existsSync(path)) return env;
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (!m || line.trimStart().startsWith("#")) continue;
    env[m[1]] = m[2].replace(/^(['"])(.*)\1$/, "$2");
  }
  return env;
}

function r2Config(env) {
  const need = ["R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_BUCKET", "R2_PUBLIC_BASE"];
  const missing = need.filter((k) => !env[k]);
  if (missing.length) throw new Error(`Missing in .env: ${missing.join(", ")} (cp .env.example .env and fill it in)`);
  return {
    client: new AwsClient({
      accessKeyId: env.R2_ACCESS_KEY_ID,
      secretAccessKey: env.R2_SECRET_ACCESS_KEY,
      service: "s3",
      region: "auto",
    }),
    endpoint: `https://${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${env.R2_BUCKET}`,
    publicBase: env.R2_PUBLIC_BASE.replace(/\/+$/, ""),
    prefix: (env.R2_KEY_PREFIX || "seperate").replace(/^\/+|\/+$/g, ""),
  };
}

async function prepare(file) {
  const ext = extname(file).toLowerCase();
  const input = readFileSync(file);
  if (IMAGE.has(ext)) {
    const { data, info } = await sharp(input, { failOn: "none", animated: ext === ".gif" })
      .rotate()
      .resize({ width: 2400, withoutEnlargement: true })
      .webp({ quality: 86 })
      .toBuffer({ resolveWithObject: true });
    // Blur placeholder the site paints while the image loads (thumbhash wants ≤100×100 RGBA).
    const small = await sharp(data).resize({ width: 100, height: 100, fit: "inside" }).ensureAlpha().raw()
      .toBuffer({ resolveWithObject: true });
    const thumbhash = Buffer.from(rgbaToThumbHash(small.info.width, small.info.height, small.data)).toString("base64");
    return { body: data, ext: ".webp", type: "image/webp", width: info.width, height: info.height, thumbhash, kind: "image" };
  }
  if (VIDEO[ext]) return { body: input, ext, type: VIDEO[ext], kind: "video" };
  throw new Error(`${basename(file)}: unsupported type ${ext}`);
}

const args = process.argv.slice(2);
const dryRun = args.includes("--dry-run");
const files = args.filter((a) => !a.startsWith("--"));
if (!files.length) {
  console.error("usage: pnpm upload <image or video...> [--dry-run]");
  process.exit(1);
}

const cfg = dryRun ? { publicBase: "<R2_PUBLIC_BASE>", prefix: "seperate" } : r2Config(loadEnv());
for (const file of files) {
  const media = await prepare(file);
  const hash = createHash("sha256").update(media.body).digest("hex").slice(0, 24);
  const key = `${cfg.prefix}/${hash}${media.ext}`;
  const url = `${cfg.publicBase}/${key}`;
  if (!dryRun) {
    const res = await cfg.client.fetch(`${cfg.endpoint}/${key}`, {
      method: "PUT",
      body: media.body,
      headers: { "Content-Type": media.type, "Cache-Control": "public, max-age=31536000, immutable" },
    });
    if (!res.ok) throw new Error(`R2 upload failed ${res.status}: ${await res.text().catch(() => "")}`);
  }
  const size = `${(media.body.length / 1024 / 1024).toFixed(2)} MB`;
  const dims = media.width ? ` ${media.width}×${media.height}` : "";
  console.log(`${basename(file)} → ${url}${dims} · ${size}${dryRun ? " (dry run, not uploaded)" : ""}`);
  const name = basename(file, extname(file));
  if (media.kind === "image") {
    // Title carries size + thumbhash: no layout jump, blurred preview while loading.
    console.log(`  markdown:    ![${name}](${url} "${media.width}x${media.height} ${media.thumbhash}")`);
    console.log(`  frontmatter: { src: ${url}, width: ${media.width}, height: ${media.height}, thumbhash: "${media.thumbhash}" }\n`);
  } else {
    console.log(`  markdown:    ![${name}](${url})\n`);
  }
}
