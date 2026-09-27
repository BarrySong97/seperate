"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { DownloadButton, LogoMark } from "@/components/brand";
import { site } from "@/lib/site";

const links = [
  { href: "/#features", label: "功能", match: "/" },
  { href: "/changelog", label: "更新日志", match: "/changelog" },
];

export function Nav() {
  const pathname = usePathname();
  return (
    <header className="sticky top-0 z-20 border-b border-line-soft bg-ground/85 backdrop-blur-md">
      <div className="mx-auto flex h-18 max-w-[1440px] items-center gap-6 px-4 sm:gap-10 sm:px-8 lg:px-16">
        <Link href="/" className="flex items-center gap-2.5 font-serif text-[22px] font-semibold tracking-tight text-text">
          <LogoMark />
          Seperate
        </Link>
        <nav aria-label="主导航" className="flex flex-1 gap-5 text-sm sm:gap-7">
          {links.map((l) => {
            const active = l.match === "/changelog" && pathname.startsWith("/changelog");
            return (
              <Link
                key={l.href}
                href={l.href}
                aria-current={active ? "page" : undefined}
                className={active ? "text-ink" : "text-muted transition-colors hover:text-text"}
              >
                {l.label}
              </Link>
            );
          })}
          <a href={site.repo} className="hidden text-muted transition-colors hover:text-text sm:inline">
            GitHub
          </a>
        </nav>
        <div className="hidden sm:block">
          <DownloadButton label="下载 macOS 版" />
        </div>
      </div>
    </header>
  );
}
