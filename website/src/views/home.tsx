import { Brackets, DownloadButton } from "@/components/brand";
import { HeroVideo } from "@/components/hero-video";
import { FeatureCards } from "@/components/feature-cards";
import { dict, htmlLang, localePath, type Lang } from "@/i18n";
import { latestVersion } from "@/lib/changelog";
import { site } from "@/lib/site";

/** The homepage, in either language (app/(en)/page.tsx, app/(zh)/zh/page.tsx). */

// Structured data for search engines: a free macOS app.
function jsonLd(lang: Lang, version: string) {
  return {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: site.name,
    description: dict(lang).site.description,
    url: site.url + (lang === "en" ? "" : localePath(lang, "/")),
    downloadUrl: site.download,
    softwareVersion: version || undefined,
    applicationCategory: "DeveloperApplication",
    operatingSystem: "macOS 14+",
    inLanguage: htmlLang[lang],
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    author: { "@type": "Person", name: "Barry Song", url: site.repo },
  };
}

export function Home({ lang }: { lang: Lang }) {
  const version = latestVersion();
  const t = dict(lang);
  const h = t.home;
  return (
    <div className="mx-auto max-w-[1440px] px-4 sm:px-8 lg:px-16">
      <script
        type="application/ld+json"
        // Static data from this file; "<" is escaped so the JSON can never close the script tag.
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd(lang, version)).replace(/</g, "\\u003c") }}
      />
      {/* The pitch first (title and download on the left, what it is on the right), the demo video under it. */}
      <section className="flex flex-col gap-14 pt-16 sm:gap-20 sm:pt-24">
        <div className="grid gap-10 lg:grid-cols-12 lg:gap-x-8">
          <div className="flex flex-col gap-6 lg:col-span-7">
            <span className="text-sm font-medium tracking-[0.04em] text-claude">{h.tag}</span>
            <h1 className="font-serif text-[40px] leading-[1.1] font-bold tracking-tight text-balance text-ink sm:text-[60px]">
              {h.titleA}
              <br className="hidden sm:inline" />
              {/* Where the line break is hidden (phones), English needs a space; Chinese does not. */}
              {lang === "en" ? " " : ""}
              {h.titleB}
            </h1>
            <div className="mt-2">
              <DownloadButton size="lg" label={h.downloadVersion(version)} />
            </div>
          </div>
          <div className="flex flex-col items-start gap-5 lg:col-span-4 lg:col-start-9 lg:pt-14">
            <Brackets>
              <span className="block bg-claude/10 px-4 py-2 font-mono text-xs text-bone">{t.site.requirements}</span>
            </Brackets>
            <p className="text-lg leading-[1.7] text-body">
              {h.pitch}
            </p>
          </div>
        </div>
        <Brackets inset="-inset-2.5">
          <HeroVideo src={site.heroVideo.src} poster={site.heroVideo.poster} lang={lang} />
        </Brackets>
      </section>

      <section id="features" className="flex scroll-mt-24 flex-col gap-12 pt-28 sm:gap-16 sm:pt-36">
        <div className="flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between lg:gap-16">
          <div className="flex flex-col gap-4">
            <span className="w-fit rounded-full border border-line bg-panel px-3 py-1 text-xs text-muted">{h.featuresChip}</span>
            <h2 className="font-serif text-[32px] leading-tight font-bold text-balance text-ink sm:text-[44px]">{h.featuresTitle}</h2>
          </div>

        </div>
        <FeatureCards lang={lang} />
      </section>

      <section className="mt-28 grid gap-12 border-t border-line pt-20 pb-24 sm:mt-40 sm:pt-24 lg:grid-cols-12 lg:gap-x-8">
        <div className="flex flex-col gap-5 lg:col-span-7">
          <h2 className="font-serif text-4xl leading-tight font-bold text-ink sm:text-5xl">{h.ctaTitle}</h2>

          <div className="mt-2 flex flex-wrap gap-3">
            <DownloadButton size="lg" label={h.ctaDownload} />
            <a href={site.repo} className="inline-flex h-13 items-center rounded-[10px] border border-line-strong px-5.5 text-base hover:border-muted">
              {h.ctaGitHub}
            </a>
          </div>
        </div>
        <dl className="text-sm lg:col-span-4 lg:col-start-9">
          <div className="flex justify-between border-b border-line-soft py-3.5">
            <dt className="text-faint">{h.version}</dt>
            <dd className="font-mono">{version}</dd>
          </div>
          {h.specs.map(([k, v], i) => (
            <div key={k} className={`flex justify-between py-3.5 ${i < h.specs.length - 1 ? "border-b border-line-soft" : ""}`}>
              <dt className="text-faint">{k}</dt>
              <dd>{v}</dd>
            </div>
          ))}
        </dl>
      </section>
    </div>
  );
}
