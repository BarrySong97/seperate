import Link from "next/link";
import { dict, localePath, type Lang } from "@/i18n";
import { site } from "@/lib/site";

export function Footer({ lang }: { lang: Lang }) {
  const t = dict(lang);
  return (
    <footer className="border-t border-line-soft">
      <div className="mx-auto flex max-w-[1440px] flex-wrap items-center gap-x-6 gap-y-2 px-4 py-8 text-[13px] text-faint sm:px-8 lg:px-16">
        <span className="font-serif font-semibold text-muted">Seperate</span>
        <span className="flex-1">{t.footer.poweredBy}</span>
        <a href={site.repo} className="text-muted hover:text-text">
          GitHub
        </a>
        <Link href={localePath(lang, "/changelog")} className="text-muted hover:text-text">
          {t.nav.changelog}
        </Link>
      </div>
    </footer>
  );
}
