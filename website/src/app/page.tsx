import { Brackets, DownloadButton } from "@/components/brand";
import { HeroVideo } from "@/components/hero-video";
import { FeatureCards } from "@/components/feature-cards";
import { latestVersion } from "@/lib/changelog";
import { site } from "@/lib/site";

const specs = [
  ["系统", "macOS 14 或更新"],
  ["芯片", "Apple Silicon"],
  ["需要", "Claude Code 或 Codex CLI"],
];

// Structured data for search engines: a free macOS app.
function jsonLd(version: string) {
  return {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: site.name,
    description: site.description,
    url: site.url,
    downloadUrl: site.download,
    softwareVersion: version || undefined,
    applicationCategory: "DeveloperApplication",
    operatingSystem: "macOS 14+",
    inLanguage: "zh-CN",
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    author: { "@type": "Person", name: "Barry Song", url: site.repo },
  };
}

export default function Home() {
  const version = latestVersion();
  return (
    <div className="mx-auto max-w-[1440px] px-4 sm:px-8 lg:px-16">
      <script
        type="application/ld+json"
        // Static data from this file; "<" is escaped so the JSON can never close the script tag.
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd(version)).replace(/</g, "\\u003c") }}
      />
      {/* The pitch first (title and download on the left, what it is on the right), the demo video under it. */}
      <section className="flex flex-col gap-14 pt-16 sm:gap-20 sm:pt-24">
        <div className="grid gap-10 lg:grid-cols-12 lg:gap-x-8">
          <div className="flex flex-col gap-6 lg:col-span-7">
            <span className="text-sm font-medium tracking-[0.04em] text-claude">macOS 上的 agent 工作台</span>
            <h1 className="font-serif text-[40px] leading-[1.1] font-bold tracking-tight text-balance text-ink sm:text-[60px]">
              所有 agent，<br className="hidden sm:inline" />一个窗口，并排跑。
            </h1>
            <div className="mt-2">
              <DownloadButton size="lg" label={`下载 Seperate ${version}`} />
            </div>
          </div>
          <div className="flex flex-col items-start gap-5 lg:col-span-4 lg:col-start-9 lg:pt-14">
            <Brackets>
              <span className="block bg-claude/10 px-4 py-2 font-mono text-xs text-bone">{site.requirements}</span>
            </Brackets>
            <p className="text-lg leading-[1.7] text-body">
              Seperate 把 Claude Code、Codex 和终端放进同一个窗口，按项目和 worktree 排好。哪个 agent 在等你，一眼就看到。
            </p>
          </div>
        </div>
        <Brackets inset="-inset-2.5">
          <HeroVideo src={site.heroVideo.src} poster={site.heroVideo.poster} />
        </Brackets>
      </section>

      <section id="features" className="flex scroll-mt-24 flex-col gap-12 pt-28 sm:gap-16 sm:pt-36">
        <div className="flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between lg:gap-16">
          <div className="flex flex-col gap-4">
            <span className="w-fit rounded-full border border-line bg-panel px-3 py-1 text-xs text-muted">功能</span>
            <h2 className="font-serif text-[32px] leading-tight font-bold text-balance text-ink sm:text-[44px]">同时跑好几个 agent，也不乱。</h2>
          </div>

        </div>
        <FeatureCards />
      </section>

      <section className="mt-28 grid gap-12 border-t border-line pt-20 pb-24 sm:mt-40 sm:pt-24 lg:grid-cols-12 lg:gap-x-8">
        <div className="flex flex-col gap-5 lg:col-span-7">
          <h2 className="font-serif text-4xl leading-tight font-bold text-ink sm:text-5xl">下载，双击，开始。</h2>

          <div className="mt-2 flex flex-wrap gap-3">
            <DownloadButton size="lg" label="下载 macOS 版" />
            <a href={site.repo} className="inline-flex h-13 items-center rounded-[10px] border border-line-strong px-5.5 text-base hover:border-muted">
              在 GitHub 上查看
            </a>
          </div>
        </div>
        <dl className="text-sm lg:col-span-4 lg:col-start-9">
          <div className="flex justify-between border-b border-line-soft py-3.5">
            <dt className="text-faint">版本</dt>
            <dd className="font-mono">{version}</dd>
          </div>
          {specs.map(([k, v], i) => (
            <div key={k} className={`flex justify-between py-3.5 ${i < specs.length - 1 ? "border-b border-line-soft" : ""}`}>
              <dt className="text-faint">{k}</dt>
              <dd>{v}</dd>
            </div>
          ))}
        </dl>
      </section>
    </div>
  );
}
