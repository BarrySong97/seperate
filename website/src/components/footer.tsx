import Link from "next/link";
import { site } from "@/lib/site";

export function Footer() {
  return (
    <footer className="border-t border-line-soft">
      <div className="mx-auto flex max-w-[1440px] flex-wrap items-center gap-x-6 gap-y-2 px-4 py-8 text-[13px] text-faint sm:px-8 lg:px-16">
        <span className="font-serif font-semibold text-muted">Seperate</span>
        <span className="flex-1">由 Ghostty 的终端引擎驱动</span>
        <a href={site.repo} className="text-muted hover:text-text">
          GitHub
        </a>
        <Link href="/changelog" className="text-muted hover:text-text">
          更新日志
        </Link>
      </div>
    </footer>
  );
}
