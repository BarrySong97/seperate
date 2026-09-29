import type { Metadata } from "next";
import { RootShell } from "@/components/root-shell";
import { dict, localePath } from "@/i18n";

/**
 * The 404 page for any unknown URL (out/404.html). With one root layout per language there is no shared
 * layout to render it in, so it brings its own: the English shell, with a way back in either language.
 */
export const metadata: Metadata = { title: "404 · Seperate", robots: { index: false } };

export default function GlobalNotFound() {
  const en = dict("en").notFound;
  const zh = dict("zh").notFound;
  return (
    <RootShell lang="en">
      <div className="mx-auto flex max-w-[1440px] flex-col gap-4 px-4 pt-24 pb-32 sm:px-8 sm:pt-32 lg:px-16">
        <span className="font-mono text-sm text-faint">404</span>
        <h1 className="font-serif text-[40px] leading-tight font-bold text-ink sm:text-5xl">{en.title}</h1>
        <p className="text-base leading-[1.7] text-body">{en.body}</p>
        <p lang="zh-CN" className="text-base leading-[1.7] text-muted">
          {zh.title}。{zh.body}
        </p>
        <div className="mt-4 flex flex-wrap gap-5 text-sm">
          <a href={localePath("en", "/")} className="text-text underline decoration-line-strong underline-offset-4 hover:decoration-muted">
            {en.home}
          </a>
          <a href={localePath("zh", "/")} lang="zh-CN" className="text-text underline decoration-line-strong underline-offset-4 hover:decoration-muted">
            {zh.home}
          </a>
        </div>
      </div>
    </RootShell>
  );
}
