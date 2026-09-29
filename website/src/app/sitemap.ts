import type { MetadataRoute } from "next";
import { langs, localePath } from "@/i18n";
import { getReleases } from "@/lib/changelog";
import { languageAlternates } from "@/lib/meta";
import { site } from "@/lib/site";

export const dynamic = "force-static";

/** Both pages in both languages; each entry names its translations (hreflang) so search engines pair them. */
export default function sitemap(): MetadataRoute.Sitemap {
  // The newest release date (patches included) is when either page last changed in a way that matters.
  const [newest] = getReleases("en");
  const lastModified = newest?.patches[0]?.date ?? newest?.date;
  const pages = [
    { path: "/", priority: 1 },
    { path: "/changelog", priority: 0.7 },
  ];
  const abs = (p: string) => (p === "/" ? site.url : site.url + p);
  return pages.flatMap(({ path, priority }) => {
    const languages = Object.fromEntries(Object.entries(languageAlternates(path)).map(([k, v]) => [k, abs(v)]));
    return langs.map((lang) => ({
      url: abs(localePath(lang, path)),
      lastModified,
      changeFrequency: "weekly" as const,
      priority: lang === "en" ? priority : priority * 0.9,
      alternates: { languages },
    }));
  });
}
