import type { Metadata } from "next";
import { Markdown, Media } from "@/components/markdown";
import { formatDate, getReleases, type Release } from "@/lib/changelog";
import { site } from "@/lib/site";

const description = "Seperate 每个版本的新功能和修复。";

export const metadata: Metadata = {
  title: "更新日志",
  description,
  alternates: { canonical: "/changelog" },
  // Child openGraph replaces the root one as a whole, so repeat the shared fields.
  openGraph: { type: "website", locale: "zh_CN", siteName: site.name, url: "/changelog", title: "更新日志 · Seperate", description },
  twitter: { card: "summary_large_image", title: "更新日志 · Seperate", description },
};

/**
 * One release, laid out like Cursor's changelog: the date in a narrow left column that sticks under the
 * nav while its entry scrolls by (the next entry's date takes over), the notes in a reading column.
 */
function Entry({ release }: { release: Release }) {
  const { version, date, title, media, patches, body } = release;
  return (
    <article id={`v${version}`} className="grid scroll-mt-24 gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,660px)_minmax(0,1fr)] lg:gap-x-10">
      <div className="lg:self-stretch">
        <div className="flex items-center gap-3 lg:sticky lg:top-24">
          <time dateTime={date} className="text-base text-faint">{formatDate(date)}</time>
          <a href={`#v${version}`} className="rounded-md border border-line px-2 py-0.5 font-mono text-xs text-muted hover:border-muted hover:text-text">
            {version}
          </a>
        </div>
      </div>

      <div className="flex min-w-0 flex-col gap-6">
        <header className="flex flex-col gap-2">
          <span className="text-base text-faint">更新日志</span>
          <h2 className="text-[30px] leading-[1.2] font-normal tracking-[-0.02em] text-balance text-ink sm:text-4xl">{title}</h2>
        </header>

        {media && <Media {...media} alt={media.alt ?? title} />}

        <Markdown>{body}</Markdown>

        {patches.length > 0 && (
          <details className="group mt-4 rounded-[10px] border border-line bg-surface">
            <summary className="flex cursor-pointer list-none items-center gap-2.5 px-4.5 py-3.5 text-sm text-bone">
              <svg className="size-3 text-faint transition-transform group-open:rotate-90" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" aria-hidden="true">
                <path d="M9 6l6 6-6 6" />
              </svg>
              <span className="font-mono">
                {patches.at(-1)!.version}
                {patches.length > 1 && ` – ${patches[0].version}`}
              </span>
              <span className="text-faint">补丁更新 · {patches.length} 个版本</span>
            </summary>
            <ul className="flex flex-col gap-3.5 px-4.5 pt-1 pb-4.5 text-[15px] leading-[1.65] text-body">
              {patches.map((p) => (
                <li key={p.version} id={`v${p.version}`} className="flex gap-4">
                  <span className="w-12 shrink-0 font-mono text-muted">{p.version}</span>
                  <span className="flex-1">{p.notes}</span>
                  <time dateTime={p.date} className="hidden shrink-0 text-faint sm:inline">
                    {formatDate(p.date)}
                  </time>
                </li>
              ))}
            </ul>
          </details>
        )}
      </div>
    </article>
  );
}

export default function Changelog() {
  const releases = getReleases();
  return (
    <div className="mx-auto max-w-[1440px] px-4 sm:px-8 lg:px-16">
      <header className="grid gap-3 pt-16 pb-20 sm:pt-24 lg:grid-cols-[minmax(0,1fr)_minmax(0,660px)_minmax(0,1fr)] lg:gap-x-10">
        <div className="lg:col-start-2 flex flex-col gap-3">
          <h1 className="text-[40px] leading-[1.15] font-normal tracking-[-0.02em] text-ink sm:text-5xl">更新日志</h1>
          <p className="text-base leading-[1.65] text-muted">Seperate 每个版本的新功能和修复。应用会自己更新到最新版。</p>
        </div>
      </header>

      <div className="flex flex-col gap-28 sm:gap-36">
        {releases.map((r) => (
          <Entry key={r.version} release={r} />
        ))}
      </div>

      <p className="grid pt-28 pb-24 text-sm text-faint lg:grid-cols-[minmax(0,1fr)_minmax(0,660px)_minmax(0,1fr)] lg:gap-x-10">
        <span className="lg:col-start-2">
          更早的改动见 GitHub 上的{" "}
          <a href={site.commits} className="text-muted underline underline-offset-4 hover:text-text">
            提交记录
          </a>
          。
        </span>
      </p>
    </div>
  );
}
