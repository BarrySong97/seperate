/**
 * A drawing of Seperate's window, shown in place of the demo video when there is none.
 * The names and messages in it are examples. (The feature cards live in feature-cards.tsx.)
 */

const agentText = { claude: "text-claude", codex: "text-codex", shell: "text-shell" } as const;
type Agent = keyof typeof agentText;

function Dot({ className }: { className: string }) {
  return <span className={`block size-1.5 shrink-0 rounded-full ${className}`} />;
}

function Terminal({ agent, title, lines }: { agent: Agent; title: string; lines: React.ReactNode[] }) {
  return (
    <div className="bg-pane px-3 py-2.5 font-mono text-[11px] leading-relaxed text-muted">
      <div className={agentText[agent]}>● {title}</div>
      {lines.map((l, i) => (
        <div key={i}>{l}</div>
      ))}
    </div>
  );
}

/** The whole app window: the still shown in place of the demo video. */
export function AppWindowMock() {
  return (
    <div className="flex h-full overflow-hidden rounded-xl border border-[#3a3b35] bg-surface">
      <div className="hidden w-[19%] shrink-0 flex-col gap-1.5 border-r border-line px-3.5 pt-11 text-xs text-muted sm:flex">
        <div className="font-semibold text-text">seperate</div>
        <div className="pl-3">main</div>
        <div className="flex items-center gap-1.5 pl-6 text-text"><Dot className="bg-wait" />重写安装器</div>
        <div className="flex items-center gap-1.5 pl-6"><Dot className="bg-run" />Sparkle 更新</div>
        <div className="mt-2.5 font-semibold text-text">stratum</div>
        <div className="pl-3">feat-billing</div>
        <div className="flex items-center gap-1.5 pl-6"><Dot className="bg-run" />迁移计费表</div>
      </div>
      <div className="flex min-w-0 flex-1 flex-col">
        <div className="flex h-9.5 items-center gap-2.5 overflow-hidden whitespace-nowrap border-b border-line px-3.5 text-xs">
          <span className="font-semibold">工作</span>
          <span className="text-muted">3 栏 · 5 个 Tab · 来自 2 个项目 ·</span>
          <span className="font-semibold text-wait">1 个需要你</span>
        </div>
        <div className="grid flex-1 grid-cols-3 gap-1 bg-well p-1">
          <Terminal agent="claude" title="Claude · 重写安装器" lines={["> 需要你确认：", <span key="q" className="text-text">编辑 InstallerWindow.swift?</span>, <span key="o" className="text-wait">1. 是   2. 否</span>]} />
          <Terminal agent="codex" title="Codex · 迁移计费表" lines={["running migrations…", <span key="a" className="text-run">✓ 0007_invoices</span>, <span key="b" className="text-run">✓ 0008_usage</span>]} />
          <Terminal agent="shell" title="zsh · main" lines={["$ git log --oneline", <span key="a" className="text-text">a517f1f Sign and notarize</span>, <span key="b" className="text-text">c5b3b28 DMG installer</span>]} />
        </div>
      </div>
    </div>
  );
}
