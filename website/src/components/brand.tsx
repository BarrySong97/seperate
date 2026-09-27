import { site } from "@/lib/site";

/** The app icon (design/app-icon.svg, also src/app/icon.svg), inline so it stays sharp at any size. */
export function LogoMark({ className = "size-7" }: { className?: string }) {
  return (
    <svg className={`block ${className}`} viewBox="0 0 100 100" aria-hidden="true">
      <defs>
        <clipPath id="logo-tile">
          <rect width="100" height="100" rx="22.5" />
        </clipPath>
        <linearGradient id="logo-bg" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#2a2b25" />
          <stop offset="1" stopColor="#1c1d19" />
        </linearGradient>
      </defs>
      <g clipPath="url(#logo-tile)">
        <rect width="100" height="100" fill="url(#logo-bg)" />
        <path d="M8 112 L8 64 A25 25 0 0 1 58 64 L58 112 Z" fill="#e8916c" />
        <rect x="20.85" y="60.75" width="5.8" height="12.5" rx="2.9" fill="#fbf1e3" />
        <rect x="31.35" y="60.75" width="5.8" height="12.5" rx="2.9" fill="#fbf1e3" />
        <path d="M40 112 L40 60 A31 31 0 0 1 102 60 L102 112 Z" fill="none" stroke="#1c1d19" strokeWidth="3.4" />
        <path d="M40 112 L40 60 A31 31 0 0 1 102 60 L102 112 Z" fill="#7b8fe6" />
        <rect x="59.85" y="51.75" width="5.8" height="12.5" rx="2.9" fill="#fbf1e3" />
        <rect x="70.35" y="51.75" width="5.8" height="12.5" rx="2.9" fill="#fbf1e3" />
      </g>
      <rect x=".6" y=".6" width="98.8" height="98.8" rx="22" fill="none" stroke="#fff" strokeOpacity=".08" strokeWidth="1.2" />
    </svg>
  );
}

export function DownloadIcon({ className = "size-3.5" }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M12 4v12M6 11l6 6 6-6M5 20h14" />
    </svg>
  );
}

export function DownloadButton({ label, size = "md" }: { label: string; size?: "md" | "lg" }) {
  const sizing = size === "lg" ? "h-13 px-6 text-base rounded-[10px] gap-2.5" : "h-10 px-4.5 text-sm rounded-lg gap-2";
  return (
    <a
      href={site.download}
      className={`inline-flex shrink-0 items-center bg-cta font-semibold text-ground transition-colors hover:bg-white ${sizing}`}
    >
      <DownloadIcon className={size === "lg" ? "size-4" : "size-3.5"} />
      {label}
    </a>
  );
}

/** Four corner brackets around whatever it wraps (hero tag, hero video). */
export function Brackets({ children, className = "", inset = "-inset-1.5" }: { children: React.ReactNode; className?: string; inset?: string }) {
  const corner = "pointer-events-none absolute size-2.5 border-claude";
  return (
    <div className={`relative ${className}`}>
      <span className={`absolute ${inset}`} aria-hidden="true">
        <span className={`${corner} top-0 left-0 border-t border-l`} />
        <span className={`${corner} top-0 right-0 border-t border-r`} />
        <span className={`${corner} bottom-0 left-0 border-b border-l`} />
        <span className={`${corner} right-0 bottom-0 border-r border-b`} />
      </span>
      {children}
    </div>
  );
}

/** Keyboard shortcut chip used in body copy. */
export function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="rounded border border-line bg-panel px-1.5 py-px font-mono text-[0.875em] text-text">{children}</kbd>
  );
}
