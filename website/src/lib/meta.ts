import type { Metadata } from "next";
import { dict, langs, localePath, ogLocale, htmlLang, type Lang } from "@/i18n";
import { site } from "@/lib/site";

/**
 * Social card image per language. There is only a Chinese card so far (its text is Chinese); English pages
 * use it too until public/og-en.png exists — then point `en` at it.
 */
const ogImage: Record<Lang, string> = { en: "/og-zh.png", zh: "/og-zh.png" };

/** hreflang links for a page: each language's URL, plus x-default → English. */
export function languageAlternates(path: string): Record<string, string> {
  const out: Record<string, string> = Object.fromEntries(langs.map((l) => [htmlLang[l], localePath(l, path)]));
  out["x-default"] = localePath("en", path);
  return out;
}

/** Site-wide metadata for a language's root layout. */
export function siteMetadata(lang: Lang): Metadata {
  const t = dict(lang).site;
  return {
    metadataBase: new URL(site.url),
    title: { default: t.title, template: "%s · Seperate" },
    description: t.description,
    applicationName: site.name,
    keywords: t.keywords,
    authors: [{ name: "Barry Song", url: site.repo }],
    creator: "Barry Song",
    category: "developer tools",
    robots: { index: true, follow: true },
  };
}

/**
 * Per-page metadata: canonical URL, hreflang alternates, Open Graph and Twitter card.
 * Child openGraph replaces the parent's as a whole, so every page repeats the shared fields here.
 */
export function pageMetadata(lang: Lang, path: string, page?: { title: string; description: string }): Metadata {
  const t = dict(lang).site;
  const url = localePath(lang, path);
  const ogTitle = page ? `${page.title} · Seperate` : t.title;
  const description = page?.description ?? t.description;
  return {
    ...(page && { title: page.title, description }),
    alternates: { canonical: url, languages: languageAlternates(path) },
    openGraph: {
      type: "website",
      locale: ogLocale[lang],
      alternateLocale: langs.filter((l) => l !== lang).map((l) => ogLocale[l]),
      siteName: site.name,
      url,
      title: ogTitle,
      description,
      images: [{ url: ogImage[lang], width: 1200, height: 630, alt: t.ogAlt }],
    },
    twitter: { card: "summary_large_image", title: ogTitle, description, images: [{ url: ogImage[lang], alt: t.ogAlt }] },
  };
}
