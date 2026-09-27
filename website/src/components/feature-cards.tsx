/**
 * The homepage features: three tall cards, each a grainy gradient with one piece of Seperate's UI
 * rebuilt in HTML on top (the sidebar's worktrees, split panes, the inbox). Colors, type and layout
 * follow the app (Sources/Workbench/UI, Theme.swift); names in them are examples, terminals are skeletons.
 */

// Film grain: SVG turbulence noise as a tiling data URI. `tone` is the grain's color (white lifts the
// light areas, black digs into the dark ones); both layers together read as frosted, grainy print.
const grain = (tone: string, alpha: number) =>
  `url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='180' height='180'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.72' numOctaves='2' stitchTiles='stitch'/%3E%3CfeColorMatrix values='0 0 0 0 ${tone} 0 0 0 0 ${tone} 0 0 0 0 ${tone} 0 0 0 ${alpha} 0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E")`;
// Faint rings around the centre, as in a lens.
const rings = "repeating-radial-gradient(circle at 50% 52%, transparent 0 88px, rgb(255 255 255 / 0.07) 88px 89px)";

const backdrops = {
  // Codex blue into a pale haze.
  blue: "radial-gradient(70% 55% at 25% 20%, #b9c8f2 0%, transparent 60%), radial-gradient(60% 60% at 80% 85%, #3c4f9c 0%, transparent 70%), radial-gradient(55% 45% at 20% 75%, #d99b86 0%, transparent 65%), linear-gradient(160deg, #8fa6e6 0%, #5c73c9 55%, #2d3a73 100%)",
  // Green with a streak of light.
  green: "linear-gradient(115deg, transparent 38%, rgb(236 244 220 / 0.75) 50%, transparent 62%), radial-gradient(60% 50% at 20% 15%, #a9c35e 0%, transparent 65%), radial-gradient(70% 55% at 75% 90%, #1f4d2a 0%, transparent 70%), linear-gradient(170deg, #7fa84a 0%, #4f8b4c 50%, #234f2d 100%)",
  // Amber and Claude clay with dark bands.
  amber: "radial-gradient(40% 70% at 78% 30%, #3a2a1c 0%, transparent 70%), radial-gradient(55% 60% at 25% 20%, #f2b23c 0%, transparent 65%), radial-gradient(60% 55% at 70% 85%, #d9621f 0%, transparent 70%), linear-gradient(100deg, #e8962f 0%, #c9591c 55%, #7a2e12 100%)",
};

function Card({ backdrop, title, body, children }: { backdrop: keyof typeof backdrops; title: string; body: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-5">
      <div className="relative flex aspect-[4/5] items-center justify-center overflow-hidden rounded-2xl" style={{ backgroundImage: backdrops[backdrop] }}>
        <div className="pointer-events-none absolute inset-0" style={{ backgroundImage: rings }} />
        <div className="pointer-events-none absolute inset-0 opacity-70 mix-blend-overlay" style={{ backgroundImage: grain("1", 0.9) }} />
        <div className="pointer-events-none absolute inset-0 opacity-45 mix-blend-soft-light" style={{ backgroundImage: grain("0", 0.9) }} />
        <div className="relative aspect-square w-[82%]">{children}</div>
      </div>
      <div className="flex flex-col gap-2">
        <h3 className="text-lg font-semibold text-ink">{title}</h3>
        <p className="text-[15px] leading-[1.7] text-muted">{body}</p>
      </div>
    </div>
  );
}

/* ——— Pieces of the app's UI ——— */

const ui = "font-sans text-[12px] leading-none text-[#e8e8e2] antialiased";
const surface = "rounded-[12px] border border-[#42433c] bg-[#22231e] shadow-[0_30px_60px_-20px_rgba(0,0,0,0.55)]";

function ClaudeIcon() {
  return <span className="w-3 shrink-0 text-center text-[13px] leading-none text-[#e8916c]">✱</span>;
}
function CodexIcon() {
  return <span className="w-3 shrink-0 text-center font-mono text-[9px] leading-none font-semibold text-[#c9c9c2]">&gt;_</span>;
}
function Chevron({ open = true }: { open?: boolean }) {
  return (
    <svg className={`size-2.5 shrink-0 text-[#6d6e67] ${open ? "" : "-rotate-90"}`} viewBox="0 0 10 10" fill="none" stroke="currentColor" strokeWidth="1.4" aria-hidden="true">
      <path d="M2.5 3.8 5 6.3l2.5-2.5" />
    </svg>
  );
}
function Badge({ letter, color }: { letter: string; color: string }) {
  return (
    <span className="flex size-4 shrink-0 items-center justify-center rounded-[4px] text-[9px] font-semibold text-[#e8e8e2]" style={{ background: color }}>
      {letter}
    </span>
  );
}
function Spinner() {
  return <span className="size-2 shrink-0 rounded-full border-[1.5px] border-[#9ccf6c] border-t-transparent" />;
}
function Dot({ color }: { color: string }) {
  return <span className="size-1.5 shrink-0 rounded-full" style={{ background: color }} />;
}
function Bell({ count }: { count: number }) {
  return (
    <span className="relative flex size-6 items-center justify-center text-[#e8e8e2]">
      <svg className="size-3.5" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" aria-hidden="true">
        <path d="M4 11V7a4 4 0 0 1 8 0v4l1 1.5H3L4 11ZM6.5 14a1.6 1.6 0 0 0 3 0" />
      </svg>
      <span className="absolute -right-0.5 bottom-0 flex size-3 items-center justify-center rounded-full bg-[#e6b450] text-[8px] font-bold text-[#1e1f1a]">{count}</span>
    </span>
  );
}

/** Sidebar: project → worktree → session, with each session's state. */
function SidebarUI() {
  const session = "flex h-7 items-center gap-2 rounded-[6px] pr-2 pl-9";
  return (
    <div className={`${ui} ${surface} flex h-full flex-col gap-0.5 p-2`}>
      <div className="flex h-7 items-center gap-2 px-1.5 font-semibold"><Chevron /><Badge letter="L" color="#3f5a44" />lumen-notes</div>
      <div className="flex h-6 items-center gap-1.5 pl-6 text-[11px] text-[#9c9d95]"><Chevron />主目录</div>
      <div className={session}>
        <ClaudeIcon /><span className="min-w-0 flex-1 truncate font-medium">加上按标题搜索</span>
        <span className="text-[11px] text-[#9c9d95]">完成 · 刚刚</span><Dot color="#d6d3c3" />
      </div>
      <div className="flex h-6 items-center gap-1.5 pl-6 text-[11px] text-[#9c9d95]"><Chevron />暗色模式</div>
      <div className={session}>
        <CodexIcon /><span className="min-w-0 flex-1 truncate font-medium">暗色模式开关</span>
        <span className="text-[11px] text-[#9c9d95]">运行中</span><Spinner />
      </div>
      <div className="mt-1 flex h-7 items-center gap-2 px-1.5 font-semibold"><Chevron /><Badge letter="P" color="#5a4a3a" />pixel-api</div>
      <div className={`${session} bg-[#34352f]`}>
        <ClaudeIcon /><span className="min-w-0 flex-1 truncate font-medium">补上 /users 的测试</span>
        <span className="text-[11px] text-[#9c9d95]">刚刚</span><Spinner />
      </div>
      <div className="mt-1 flex h-7 items-center gap-2 px-1.5 font-semibold"><Chevron /><Badge letter="A" color="#6a3d33" />atlas-cli</div>
      <div className={`${session} bg-[#e6b450]/12`}>
        <CodexIcon /><span className="min-w-0 flex-1 truncate font-medium">加上 --json 输出</span>
        <span className="text-[11px] font-medium text-[#e6b450]">等待确认</span><Dot color="#e6b450" />
      </div>
      <div className="mt-auto flex items-center justify-between border-t border-[#34352f] px-1.5 pt-2 text-[11px] text-[#6d6e67]">
        <span>+ 添加项目 ⌄</span>
        <Bell count={1} />
      </div>
    </div>
  );
}

/** A terminal pane: tab bar, where it runs, and skeleton lines for the agent's output. */
function Pane({ icon, tab, project, status, statusColor, lines, focused }: {
  icon: React.ReactNode; tab: string; project: string; status: string; statusColor: string; lines: [number, string][]; focused?: boolean;
}) {
  return (
    <div className={`flex min-w-0 flex-col overflow-hidden rounded-[7px] border bg-[#272822] ${focused ? "border-[#6d6e67]" : "border-[#34352f]"}`}>
      <div className="flex h-6 items-center gap-1.5 border-b border-[#34352f] bg-[#2b2c26] px-2 text-[10.5px] font-medium">
        {icon}<span className="truncate">{tab}</span><span className="ml-auto text-[#6d6e67]">×</span>
      </div>
      <div className="flex h-5 items-center gap-1 px-2 text-[9.5px] text-[#9c9d95]">
        <span className="truncate">{project}</span>
        <span className="ml-auto flex items-center gap-1 whitespace-nowrap" style={{ color: statusColor }}><Dot color={statusColor} />{status}</span>
      </div>
      <div className="flex flex-col gap-[7px] px-2 pt-1 pb-3">
        {lines.map(([w, c], i) => (
          <span key={i} className="h-[5px] rounded-full" style={{ width: `${w}%`, background: c }} />
        ))}
      </div>
    </div>
  );
}

const dim = "#4a4b44", mid = "#5d5e56";

/** The window in a 2×2 split: top bar with the layout picker, four agents side by side. */
function PanesUI() {
  return (
    <div className={`${ui} ${surface} flex h-full flex-col overflow-hidden bg-[#1e1f1a]`}>
      <div className="flex h-8 items-center gap-2 border-b border-[#34352f] px-3 text-[11px]">
        <span className="font-semibold">工作</span>
        <span className="truncate text-[#9c9d95]">4 栏 · 来自 3 个项目 ·</span>
        <span className="font-semibold whitespace-nowrap text-[#e6b450]">1 个需要你</span>
        <span className="ml-auto flex gap-1">
          {[1, 2, 3].map((n) => <span key={n} className="h-2.5 w-3.5 rounded-[2px] border border-[#6d6e67]" />)}
          <span className="grid h-2.5 w-3.5 grid-cols-2 gap-px rounded-[2px] bg-[#e8e8e2] p-px"><i className="bg-[#1e1f1a]" /><i className="bg-[#1e1f1a]" /><i className="bg-[#1e1f1a]" /><i className="bg-[#1e1f1a]" /></span>
        </span>
      </div>
      <div className="grid flex-1 grid-cols-2 grid-rows-2 gap-1.5 p-1.5">
        <Pane icon={<ClaudeIcon />} tab="Claude Code" project="lumen-notes / 主目录" status="完成" statusColor="#9c9d95" focused
          lines={[[72, mid], [48, dim], [86, "#3c5a3a"], [64, "#3c5a3a"], [40, dim], [78, mid], [55, dim]]} />
        <Pane icon={<CodexIcon />} tab="暗色模式" project="lumen-notes / 暗色模式" status="运行中" statusColor="#9ccf6c"
          lines={[[58, mid], [80, dim], [44, "#44507a"], [70, dim], [36, mid], [62, dim], [50, dim]]} />
        <Pane icon={<ClaudeIcon />} tab="Claude Code" project="pixel-api / 主目录" status="工作中" statusColor="#9ccf6c"
          lines={[[66, mid], [84, dim], [52, dim], [74, "#44507a"], [46, mid], [68, dim], [38, dim]]} />
        <Pane icon={<CodexIcon />} tab="atlas-cli" project="atlas-cli / 主目录" status="需要你" statusColor="#e6b450"
          lines={[[60, mid], [42, dim], [76, dim], [54, "#6b5a2e"], [82, "#6b5a2e"], [48, mid], [30, dim]]} />
      </div>
    </div>
  );
}

function InboxRow({ icon, title, tag, tagClass, place, message }: {
  icon: React.ReactNode; title: string; tag: string; tagClass: string; place: string; message: string;
}) {
  return (
    <div className="flex gap-2 py-1.5">
      <span className="pt-px">{icon}</span>
      <div className="flex min-w-0 flex-1 flex-col gap-1">
        <div className="flex items-center gap-1.5">
          <span className="font-semibold">{title}</span>
          <span className={`rounded-[4px] px-1 py-[3px] text-[9px] font-semibold ${tagClass}`}>{tag}</span>
          <span className="ml-auto text-[10px] text-[#6d6e67]">刚刚</span>
        </div>
        <span className="text-[10px] text-[#9c9d95]">{place}</span>
        <span className="truncate text-[11px] leading-snug text-[#c9c9c2]">{message}</span>
      </div>
    </div>
  );
}

/** The inbox: sessions that need you, results to look at, what is still running. */
function InboxUI() {
  const group = "pt-2.5 pb-0.5 text-[10px] font-semibold";
  return (
    <div className={`${ui} ${surface} flex h-full flex-col bg-[#2b2c26] px-3 pt-3 pb-2`}>
        <div className="flex items-center gap-2">
          <span className="text-[13px] font-semibold">收件箱</span>
          <span className="text-[10.5px] text-[#9c9d95]">1 个需要你 · 1 个待查看</span>
          <span className="ml-auto text-[10.5px] text-[#9c9d95]">全部标为已读</span>
        </div>
        <div className="mt-2.5 grid grid-cols-4 rounded-[6px] bg-[#1e1f1a] p-0.5 text-center text-[10.5px]">
          <span className="rounded-[5px] bg-[#42433c] py-1 font-medium">全部 2</span>
          <span className="py-1 text-[#c9c9c2]">需要你 1</span>
          <span className="py-1 text-[#c9c9c2]">待查看 1</span>
          <span className="py-1 text-[#c9c9c2]">进行中 1</span>
        </div>
        <div className={`${group} text-[#e6b450]`}>需要你 · 1</div>
        <InboxRow icon={<CodexIcon />} title="atlas-cli" tag="需要授权" tagClass="bg-[#e6b450]/20 text-[#e6b450]" place="atlas-cli" message="Approval requested: cargo run -- --json" />
        <div className={`${group} text-[#c9c9c2]`}>待查看 · 1</div>
        <InboxRow icon={<ClaudeIcon />} title="Claude Code" tag="待查看" tagClass="bg-[#d6d3c3]/15 text-[#d6d3c3]" place="lumen-notes" message="已加上 searchNotes(query)：按标题搜索，忽略大小写" />
        <div className={`${group} text-[#9ccf6c]`}>进行中 · 1</div>
        <InboxRow icon={<ClaudeIcon />} title="Claude Code" tag="进行中" tagClass="bg-[#9ccf6c]/18 text-[#9ccf6c]" place="pixel-api" message="正在运行 · 已 2 分钟" />
        <div className="mt-auto border-t border-[#34352f] pt-2 text-[9.5px] text-[#6d6e67]">点一行 = 跳到那个会话并标为已读 · ⌘I 打开 / 关闭</div>
    </div>
  );
}

export function FeatureCards() {
  return (
    <div className="grid gap-x-5 gap-y-14 md:grid-cols-3">
      <Card backdrop="blue" title="一个 agent 一个 worktree"
        body="侧栏按项目、worktree、会话三层排。新建 worktree 时挑基础分支就行；每个会话旁边的状态告诉你它在跑、在等，还是做完了。">
        <SidebarUI />
      </Card>
      <Card backdrop="green" title="不同项目的 agent，并排跑"
        body="两栏、三栏、四栏或 2×2，一键切换。Tab 可以拖到别的栏；终端用 Ghostty 的引擎渲染，滚几万行也不卡。">
        <PanesUI />
      </Card>
      <Card backdrop="amber" title="agent 等你的时候，才来叫你"
        body="要权限、问问题、跑完了，收件箱按轻重排好，Dock 角标和系统通知同步提醒，点一下就跳到那个会话。">
        <InboxUI />
      </Card>
    </div>
  );
}
