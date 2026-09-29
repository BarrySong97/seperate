/**
 * The site's two languages. English lives at `/`, Chinese under `/zh`; every page exists in both.
 * Server components take a `lang` prop and call `dict(lang)`; client components use `useDict()` (client.tsx).
 */
import { en, type Dict } from "./en";
import { zh } from "./zh";

export type { Dict };
export const langs = ["en", "zh"] as const;
export type Lang = (typeof langs)[number];

const dicts: Record<Lang, Dict> = { en, zh };
export const dict = (lang: Lang): Dict => dicts[lang];

/** `<html lang>`, hreflang and Open Graph locale for each language. */
export const htmlLang: Record<Lang, string> = { en: "en", zh: "zh-CN" };
export const ogLocale: Record<Lang, string> = { en: "en_US", zh: "zh_CN" };

/** A page path ("/", "/changelog") in the given language: "/zh", "/zh/changelog" for Chinese. */
export function localePath(lang: Lang, path: string): string {
  if (lang === "en") return path;
  return path === "/" ? "/zh" : `/zh${path}`;
}

/** The language of a URL path and the path without its language prefix. */
export function splitPath(pathname: string): { lang: Lang; path: string } {
  if (pathname === "/zh" || pathname.startsWith("/zh/")) return { lang: "zh", path: pathname.slice(3) || "/" };
  return { lang: "en", path: pathname || "/" };
}
