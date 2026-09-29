"use client";

/** Top bar: logo, Features / Changelog / GitHub, the English / 中文 switch (same page, other language) and Download. */
import Link from "next/link";
import { usePathname } from "next/navigation";
import { DownloadButton, LogoMark } from "@/components/brand";
import { localePath, splitPath, type Lang } from "@/i18n";
import { useDict, useLang } from "@/i18n/client";
import { site } from "@/lib/site";

const langLabel: Record<Lang, string> = { en: "English", zh: "中文" };

export function Nav() {
  const lang = useLang();
  const t = useDict().nav;
  const { path } = splitPath(usePathname());
  const links = [
    { href: `${localePath(lang, "/")}#features`, label: t.features, active: false },
    { href: localePath(lang, "/changelog"), label: t.changelog, active: path.startsWith("/changelog") },
  ];
  const other: Lang = lang === "en" ? "zh" : "en";
  return (
    <header className="sticky top-0 z-20 border-b border-line-soft bg-ground/85 backdrop-blur-md">
      <div className="mx-auto flex h-18 max-w-[1440px] items-center gap-6 px-4 sm:gap-10 sm:px-8 lg:px-16">
        <Link href={localePath(lang, "/")} className="flex items-center gap-2.5 font-serif text-[22px] font-semibold tracking-tight text-text">
          <LogoMark />
          Seperate
        </Link>
        <nav aria-label={t.aria} className="flex flex-1 gap-5 text-sm sm:gap-7">
          {links.map((l) => (
            <Link
              key={l.href}
              href={l.href}
              aria-current={l.active ? "page" : undefined}
              className={l.active ? "text-ink" : "text-muted transition-colors hover:text-text"}
            >
              {l.label}
            </Link>
          ))}
          <a href={site.repo} className="hidden text-muted transition-colors hover:text-text sm:inline">
            GitHub
          </a>
        </nav>
        {/* A plain link: the two languages are separate root layouts, so switching is a full page load anyway. */}
        <a
          href={localePath(other, path)}
          hrefLang={other === "zh" ? "zh-CN" : "en"}
          lang={other === "zh" ? "zh-CN" : "en"}
          aria-label={`${t.language}: ${langLabel[other]}`}
          className="flex shrink-0 items-center gap-1.5 text-sm whitespace-nowrap text-muted transition-colors hover:text-text"
        >
          <svg className="hidden size-3.5 sm:block" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true">
            <circle cx="12" cy="12" r="9" />
            <path d="M3 12h18M12 3c2.5 2.6 3.8 5.6 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3Z" />
          </svg>
          {langLabel[other]}
        </a>
        <div className="hidden sm:block">
          <DownloadButton label={t.download} />
        </div>
      </div>
    </header>
  );
}
