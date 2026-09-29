/**
 * Drawings of new UI for changelog entries, used where a release has no screenshot. In Markdown they are
 * images with a `mock:` source, e.g. `![caption](mock:tab-menu)`; markdown.tsx renders them from here.
 * Same stage as the homepage feature cards (feature-cards.tsx): grainy gradient, one piece of the app on top.
 * Menus follow the app's real menus (Sources/Workbench/UI/Menus.swift); names in them are examples.
 */
import { backdrops, Badge, Chevron, ClaudeIcon, CodexIcon, Dot, grain, rings, surface, ui } from "@/components/feature-cards";

function Stage({ backdrop, caption, children }: { backdrop: keyof typeof backdrops; caption?: string; children: React.ReactNode }) {
  return (
    <figure className="flex flex-col gap-2.5">
      <div className="@container relative aspect-[16/10] overflow-hidden rounded-2xl" style={{ backgroundImage: backdrops[backdrop] }}>
        <div className="pointer-events-none absolute inset-0" style={{ backgroundImage: rings }} />
        <div className="pointer-events-none absolute inset-0 opacity-70 mix-blend-overlay" style={{ backgroundImage: grain("1", 0.9) }} />
        <div className="pointer-events-none absolute inset-0 opacity-45 mix-blend-soft-light" style={{ backgroundImage: grain("0", 0.9) }} />
        {/* Drawn at a fixed 568×330 and scaled to ~86% of the stage's width, so menus keep their layout on phones. */}
        <div
          className="absolute top-1/2 left-1/2 h-[330px] w-[568px] -translate-x-1/2 -translate-y-1/2 scale-[0.48] @sm:scale-[0.58] @md:scale-[0.68] @lg:scale-[0.78] @xl:scale-[0.87] @min-[640px]:scale-100"
          aria-hidden="true"
        >
          {children}
        </div>
      </div>
      {caption && <figcaption className="text-center text-[13px] leading-relaxed text-faint">{caption}</figcaption>}
    </figure>
  );
}

/* ——— A native macOS menu, dark appearance ——— */

type Item = { label: string; icon?: React.ReactNode; hover?: boolean; disabled?: boolean; submenu?: boolean } | "-";

function Menu({ items, className = "" }: { items: Item[]; className?: string }) {
  return (
    <div className={`${ui} absolute z-10 flex w-max min-w-44 flex-col rounded-[9px] border border-white/10 bg-[#2d2e2a]/95 p-[5px] text-[12.5px] shadow-[0_18px_40px_-8px_rgba(0,0,0,0.6)] backdrop-blur ${className}`}>
      {items.map((it, i) =>
        it === "-" ? (
          <span key={i} className="mx-2 my-[5px] h-px bg-white/12" />
        ) : (
          <span key={i} className={`flex h-[22px] items-center gap-2 rounded-[5px] px-2 ${it.hover ? "bg-[#2f6fd6] text-white" : it.disabled ? "text-[#e8e8e2]/30" : ""}`}>
            {it.icon}
            <span className="flex-1 whitespace-nowrap">{it.label}</span>
            {it.submenu && <span className="pl-4 text-[10px] opacity-60">›</span>}
          </span>
        ),
      )}
    </div>
  );
}

function ShellIcon() {
  return <span className="w-3 shrink-0 text-center font-mono text-[10px] leading-none text-[#78c6de]">$</span>;
}

/* ——— Right-click a tab: close it, the others, left, right, or all ——— */

function Tab({ icon, title, active, focused, hot }: { icon: React.ReactNode; title: string; active?: boolean; focused?: boolean; hot?: boolean }) {
  return (
    <div className={`relative flex h-full w-[23%] min-w-0 items-center gap-1.5 border-r border-[#34352f] pr-1 pl-2.5 ${active ? "bg-[#272822] text-[#e8e8e2]" : "text-[#9c9d95]"} ${hot ? "bg-white/[0.06]" : ""}`}>
      {active && focused && <span className="absolute inset-x-0 top-0 h-0.5 bg-[#d6d3c3]" />}
      {icon}
      <span className="min-w-0 flex-1 truncate">{title}</span>
      <span className={`px-1 text-[10px] ${active ? "" : "opacity-60"}`}>✕</span>
    </div>
  );
}

function TabMenuUI() {
  const line = (w: number, c = "#4a4b44") => <span className="h-[5px] rounded-full" style={{ width: `${w}%`, background: c }} />;
  return (
    <div className={`${ui} ${surface} relative flex h-full flex-col bg-[#272822]`}>
      <div className="flex h-[34px] shrink-0 items-stretch overflow-hidden rounded-t-[12px] border-b border-[#34352f] bg-[#22231e] pl-1.5">
        <Tab icon={<ClaudeIcon />} title="Claude Code 1" />
        <Tab icon={<CodexIcon />} title="修复登录跳转" />
        <Tab icon={<ShellIcon />} title="zsh 1" active focused hot />
        <Tab icon={<ClaudeIcon />} title="Claude Code 2" />
      </div>
      <div className="flex h-[25px] shrink-0 items-center gap-2 border-b border-[#34352f] px-3 text-[11px] text-[#9c9d95]">
        <Badge letter="L" color="#3f5a44" />
        <span>lumen-notes&nbsp; / &nbsp;main&nbsp;&nbsp; 终端</span>
        <span className="ml-auto flex items-center gap-1.5"><Dot color="#9ccf6c" />运行中</span>
      </div>
      <div className="flex flex-col gap-[9px] px-4 pt-4">
        {line(46, "#5d5e56")}{line(70)}{line(58)}{line(34, "#3c5a3a")}{line(62)}{line(40, "#5d5e56")}{line(52)}
      </div>
      <Menu
        className="top-[30px] left-[52%]"
        items={[
          { label: "关闭 Tab" },
          { label: "关闭其他 Tab", hover: true },
          { label: "关闭左侧 Tab" },
          { label: "关闭右侧 Tab" },
          "-",
          { label: "关闭所有 Tab" },
        ]}
      />
    </div>
  );
}

/* ——— "Claude Code（跳过权限）" in the project's + menu ——— */

function SkipPermissionsUI() {
  const session = "flex h-7 items-center gap-2 rounded-[6px] pr-2 pl-9";
  return (
    <div className="relative h-full">
      <div className={`${ui} ${surface} flex h-full w-[46%] flex-col gap-0.5 p-2`}>
        <div className="flex h-7 items-center gap-2 rounded-[6px] bg-white/[0.05] px-1.5 font-semibold">
          <Chevron /><Badge letter="L" color="#3f5a44" />lumen-notes
          <span className="ml-auto flex size-5 items-center justify-center rounded-[5px] bg-white/10 text-[13px] font-normal">+</span>
        </div>
        <div className={session}><ClaudeIcon /><span className="min-w-0 flex-1 truncate font-medium">加上按标题搜索</span><span className="text-[11px] text-[#9c9d95]">完成</span></div>
        <div className={session}><CodexIcon /><span className="min-w-0 flex-1 truncate font-medium">修复登录跳转</span><span className="text-[11px] text-[#9c9d95]">运行中</span></div>
        <div className="mt-1 flex h-7 items-center gap-2 px-1.5 font-semibold"><Chevron open={false} /><Badge letter="P" color="#5a4a3a" />pixel-api</div>
        <div className="flex h-7 items-center gap-2 px-1.5 font-semibold"><Chevron open={false} /><Badge letter="A" color="#6a3d33" />atlas-cli</div>
        <div className="mt-auto border-t border-[#34352f] px-1.5 pt-2 text-[11px] text-[#6d6e67]">+ 添加项目 ⌄</div>
      </div>
      <Menu
        className="top-[34px] left-[38%]"
        items={[
          { label: "Codex", icon: <CodexIcon /> },
          { label: "Claude Code", icon: <ClaudeIcon /> },
          { label: "Claude Code（跳过权限）", icon: <span className="w-3 shrink-0 text-center text-[13px] leading-none">✱</span>, hover: true },
          { label: "终端", icon: <ShellIcon /> },
          "-",
          { label: "新建 Worktree…" },
          { label: "在 Finder 中显示" },
          { label: "复制路径" },
          "-",
          { label: "移到 Workspace", submenu: true },
        ]}
      />
      <div className="absolute top-[112px] left-[50%] z-20 w-[40%] max-w-60 rounded-[6px] border border-white/10 bg-[#3a3b36] px-2.5 py-2 font-sans text-[11px] leading-[1.45] text-[#e8e8e2] shadow-lg">
        以 --dangerously-skip-permissions 启动：不再询问权限，直接执行命令和改文件
      </div>
    </div>
  );
}

const mocks = {
  "tab-menu": { backdrop: "green", ui: TabMenuUI },
  "skip-permissions": { backdrop: "amber", ui: SkipPermissionsUI },
} as const;

/** `mock:<name>` in a changelog image; null for an unknown name so a typo shows nothing rather than a broken image. */
export function ChangelogMock({ name, caption }: { name: string; caption?: string }) {
  const m = mocks[name as keyof typeof mocks];
  if (!m) return null;
  const UI = m.ui;
  return (
    <Stage backdrop={m.backdrop} caption={caption}>
      <UI />
    </Stage>
  );
}
