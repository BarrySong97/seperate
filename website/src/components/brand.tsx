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

/** The Apple logo on download buttons: Seperate runs only on macOS. Path from Simple Icons (CC0). */
export function AppleIcon({ className = "size-3.5" }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701" />
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
      <AppleIcon className={size === "lg" ? "size-[18px] -mt-0.5" : "size-4 -mt-px"} />
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
