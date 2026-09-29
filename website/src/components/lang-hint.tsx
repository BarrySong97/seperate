"use client";

/**
 * On English pages, a thin bar offering the Chinese page to visitors whose browser prefers Chinese.
 * Never redirects (a static site can only decide in the browser, and a redirect would flash the English page).
 * Dismissing it is remembered in localStorage.
 */
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { localePath, splitPath } from "@/i18n";
import { useDict } from "@/i18n/client";

const KEY = "seperate.langHint.dismissed";

export function LangHint() {
  const t = useDict().langHint;
  const pathname = usePathname();
  const [show, setShow] = useState(false);

  useEffect(() => {
    let dismissed = false;
    try {
      dismissed = localStorage.getItem(KEY) === "1";
    } catch {}
    const prefersZh = (navigator.languages ?? [navigator.language]).find((l) => /^(zh|en)/i.test(l))?.toLowerCase().startsWith("zh");
    // Reading the browser's language has to wait for the client; the bar appears after hydration.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    if (prefersZh && !dismissed) setShow(true);
  }, []);

  if (!show) return null;
  const dismiss = () => {
    setShow(false);
    try {
      localStorage.setItem(KEY, "1");
    } catch {}
  };
  return (
    <div lang="zh-CN" className="flex items-center justify-center gap-3 border-b border-line-soft bg-panel px-4 py-2 text-[13px] text-body">
      <a href={localePath("zh", splitPath(pathname).path)} className="text-text underline decoration-line-strong underline-offset-4 hover:decoration-muted">
        {t.text} →
      </a>
      <button type="button" onClick={dismiss} aria-label={t.dismiss} className="rounded p-1 text-faint hover:text-text">
        <svg className="size-3" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" aria-hidden="true">
          <path d="M18 6 6 18M6 6l12 12" />
        </svg>
      </button>
    </div>
  );
}
