import AppKit
import os

/// App state: workspaces (projects + a pane layout each), sessions, and the live terminals.
/// Views register for specific changes; nothing re-renders wholesale.
@MainActor
final class Store {
    enum Change {
        case projects                 // projects / worktrees / sessions list changed
        case session(String)          // one session's title or status
        case layout(structure: Bool)  // active layout: structure = panes added/removed/nested; else tabs/active/focus/sizes
        case workspace                // switched workspace, or the workspace list changed
        case reveal(String)           // a session was just created: show it in the sidebar
        case sidebar                  // showOlder / hidden
    }

    // Persisted
    private(set) var workspaces: [Workspace] = []
    private(set) var activeID = ""
    private(set) var aliases: [String: String] = [:]     // worktree path → display name
    private(set) var worktreeOrder: [String: [String]] = [:]   // project root → worktree paths, the user's order
    /// Worktrees removed from Seperate only (folder and git record stay): path → (project, when). Sticky across refreshes.
    private(set) var hiddenWorktrees: [String: (projectRoot: String, at: Date)] = [:]
    /// The editor the header's open button and ⌥⌘O use.
    private(set) var defaultEditor: ExternalApp? = nil
    private(set) var showOlder = false
    private(set) var sidebarHidden = false
    private(set) var created: [AgentSession] = []         // sessions started in the app
    private(set) var pinned: Set<String> = []             // session ids pinned to the top of their worktree

    // Runtime
    private(set) var projects: [Project] = []              // union over all workspaces
    private(set) var worktrees: [Worktree] = []
    private(set) var discovered: [AgentSession] = []
    private(set) var attention: Set<String> = []          // plain terminals that rang the bell
    private(set) var phase: [String: AgentPhase] = [:]     // what each running agent is doing (absent = idle)
    private var turnStarted: [String: Date] = [:]
    private var phaseSince: [String: Date] = [:]        // when the current phase (or bell) began
    private var needKind: [String: NeedKind] = [:]
    /// Installed by the sidebar; toggles the inbox popover (⌘I).
    var inboxHandler: (() -> Void)?
    func toggleInbox() { inboxHandler?() }
    private var agentExited: Set<String> = []             // the agent quit back to its shell
    let notifier = Notifier()
    private(set) var liveTitles: [String: String] = [:]
    private(set) var terminals: [String: TerminalView] = [:]

    // Indexes (rebuilt when projects/sessions change; read by every view)
    private(set) var sessionsByWorktree: [String: [AgentSession]] = [:]   // visible, sorted
    private(set) var worktreeOfSession: [String: String] = [:]           // session id → worktree path
    private var sessionByID: [String: AgentSession] = [:]

    private var observers: [UUID: (Change) -> Void] = [:]
    private var saveWork: DispatchWorkItem?
    private var refreshing = false
    private var dbReady = false
    private var pinnedRows: [String: Core.DBState.SessionRow] = [:]   // pins of sessions the scan has not found (yet)


    init() {
        AgentHooks.install()
        load()
        if workspaces.isEmpty { workspaces = [Workspace.make(name: "默认")]; activeID = workspaces[0].id; saveNow() }
        if !workspaces.contains(where: { $0.id == activeID }) { activeID = workspaces[0].id }
        let (ps, ws) = Self.resolveProjects(roots: allRoots, aliases: aliases, order: worktreeOrder, hidden: Set(hiddenWorktrees.keys))
        projects = ps; worktrees = ws
        rebuildIndex()
        DistributedNotificationCenter.default().addObserver(forName: AgentHooks.eventName, object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo ?? [:]
            MainActor.assumeIsolated { self?.agentEvent(info) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.markSeen() }
        }
        notifier.start()
        notifier.onOpen = { [weak self] id in
            NSApp.activate(ignoringOtherApps: true)
            guard let self else { return }
            if self.workspaceContaining(id) != nil { self.reveal(id) } else { self.open(id) }
        }
    }

    /// Installed by the window; opens the command palette.
    var paletteHandler: ((PaletteScope) -> Void)?
    func showPalette(_ scope: PaletteScope = .all) { paletteHandler?(scope) }
    /// Installed by the window; opens "import projects your agents used".
    var importHandler: (() -> Void)?
    func showImport() { importHandler?() }

    // MARK: Observation

    func observe(_ f: @escaping (Change) -> Void) -> UUID {
        let id = UUID(); observers[id] = f; return id
    }
    func unobserve(_ id: UUID) { observers[id] = nil }

    private func notify(_ c: Change) {
        for o in observers.values { o(c) }
        scheduleSave()
    }

    // MARK: Workspaces

    var activeIndex: Int { workspaces.firstIndex { $0.id == activeID } ?? 0 }
    var active: Workspace { workspaces[activeIndex] }

    var layout: LayoutModel {
        get { workspaces[activeIndex].layout }
        set { workspaces[activeIndex].layout = newValue }
    }

    private var allRoots: [String] {
        var seen = Set<String>(), out: [String] = []
        for w in workspaces { for r in w.projectRoots where seen.insert(r).inserted { out.append(r) } }
        return out
    }

    /// Projects of the active workspace, in the user's order.
    var visibleProjects: [Project] { active.projectRoots.compactMap(project) }

    func switchWorkspace(to id: String) {
        guard id != activeID, workspaces.contains(where: { $0.id == id }) else { return }
        activeID = id
        notify(.workspace)
        markSeen()
    }

    func switchWorkspace(offset: Int) {
        let i = (activeIndex + offset + workspaces.count) % workspaces.count
        switchWorkspace(to: workspaces[i].id)
    }

    func addWorkspace(name: String) {
        let w = Workspace.make(name: name, tint: Workspace.nextTint(used: workspaces.map(\.tint)))
        workspaces.append(w)
        activeID = w.id
        notify(.workspace)
    }

    /// Moves a workspace to `index` (an insertion point in the current order); ⌃1…⌃9 follow the order.
    func reorderWorkspace(_ id: String, to index: Int) {
        guard let from = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, from < index ? index - 1 : index), workspaces.count - 1)
        guard to != from else { return }
        workspaces.insert(workspaces.remove(at: from), at: to)
        notify(.workspace)
    }

    func setColor(_ id: String, _ tint: UInt32) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }), workspaces[i].tint != tint else { return }
        workspaces[i].tint = tint
        notify(.workspace)
    }

    func renameWorkspace(_ id: String, to name: String) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        workspaces[i].name = name
        workspaces[i].icon = String(name.prefix(1))
        notify(.workspace)
    }

    /// Projects and sessions survive; terminals open in this workspace's panes are ended.
    func deleteWorkspace(_ id: String) {
        guard workspaces.count > 1, let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        for sid in workspaces[i].layout.openSessionIDs { endSession(sid) }
        workspaces.remove(at: i)
        if activeID == id { activeID = workspaces[min(i, workspaces.count - 1)].id }
        refreshProjects()
        notify(.workspace)
    }

    /// True when an agent is waiting in a pane of this workspace (or in one of its projects, if not open anywhere).
    /// Sessions that need the user: bells from plain terminals, and agents asking for permission.
    var waitingIDs: Set<String> {
        attention.union(phase.compactMap { if case .needsInput = $0.value { return $0.key } else { return nil } })
    }

    func needsAttention(_ w: Workspace) -> Bool {
        for sid in waitingIDs {
            if w.layout.openSessionIDs.contains(sid) { return true }
            if workspaceContaining(sid) == nil,
               let wt = session(sid).flatMap(worktree(for:)), w.projectRoots.contains(wt.projectID) { return true }
        }
        return false
    }

    /// Which workspace's layout holds this session's tab, if any.
    func workspaceContaining(_ sid: String) -> Workspace? {
        workspaces.first { $0.layout.pane(containing: sid) != nil }
    }

    // MARK: Sessions

    func session(_ id: String) -> AgentSession? { sessionByID[id] }

    func status(of id: String) -> SessionStatus {
        guard terminals[id] != nil else { return .history }
        if attention.contains(id) { return .waiting }
        switch phase[id] {
        case .needsInput: return .waiting
        case .working: return .working
        case .done: return .done
        case .failed: return .failed
        case nil: return .running
        }
    }

    /// The agent's own words for its current state (the permission it wants, or its last reply).
    func phaseMessage(of id: String) -> String? {
        switch phase[id] {
        case .needsInput(let m), .done(let m): return m
        case .failed(let code): return "退出码 \(code)"
        default: return nil
        }
    }

    func title(of s: AgentSession) -> String { liveTitles[s.id].map(Self.cleanTitle) ?? s.title }

    /// Agents prefix titles with spinners/marks ("✳ Fix login"); keep the words.
    static func cleanTitle(_ t: String) -> String {
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.unicodeScalars.first, !first.properties.isAlphabetic, !first.properties.isIdeographic,
           trimmed.count > 2, trimmed.dropFirst().first == " " {
            return String(trimmed.dropFirst(2))
        }
        return trimmed
    }

    func worktree(for s: AgentSession) -> Worktree? { worktreeOfSession[s.id].flatMap(worktree(path:)) }
    func worktree(path: String) -> Worktree? { worktrees.first { $0.path == path } }
    func project(_ id: String) -> Project? { projects.first { $0.id == id } }
    func worktrees(of p: Project) -> [Worktree] { worktrees.filter { $0.projectID == p.id } }
    func projectName(of wt: Worktree) -> String { project(wt.projectID)?.name ?? (wt.projectID as NSString).lastPathComponent }
    func sessions(in wt: Worktree) -> [AgentSession] { sessionsByWorktree[wt.path] ?? [] }

    /// Every known session of a worktree, older ones included, newest first.
    func allSessions(in wt: Worktree) -> [AgentSession] {
        sessionByID.values.filter { worktreeOfSession[$0.id] == wt.path }.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Everything the views need, computed once. Cost: sessions × worktrees, a few ms.
    private func rebuildIndex() {
        let claimed = Set(created.compactMap(\.agentSessionID))
        let all = created + discovered.filter { !claimed.contains($0.agentSessionID ?? "") }
        sessionByID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let byDepth = worktrees.sorted { $0.path.count > $1.path.count }   // deepest match wins
        worktreeOfSession = [:]
        // Every session, whatever its age; the sidebar shows the first few of each worktree.
        var grouped: [String: [AgentSession]] = [:]
        let hidden = Array(hiddenWorktrees.keys)
        for s in all {
            // Sessions of a hidden worktree go with it (they would otherwise fall back to an enclosing one).
            if hidden.contains(where: { s.cwd.isPath(inside: $0) }) { continue }
            guard let wt = byDepth.first(where: { s.cwd.isPath(inside: $0.path) }) else { continue }
            worktreeOfSession[s.id] = wt.path
            grouped[wt.path, default: []].append(s)
        }
        // Pinned first, then the ones waiting for you, then the most recent.
        let waiting = waitingIDs
        for k in grouped.keys {
            grouped[k]!.sort { l, r in
                let lp = pinned.contains(l.id), rp = pinned.contains(r.id)
                if lp != rp { return lp }
                let lw = waiting.contains(l.id), rw = waiting.contains(r.id)
                if lw != rw { return lw }
                return l.lastActivity > r.lastActivity
            }
        }
        sessionsByWorktree = grouped
    }

    // MARK: Opening / creating

    /// Opens in the active workspace; a tab living in another workspace moves here (like Arc tabs between spaces).
    func open(_ sessionID: String, newPane: Bool = false) {
        if let other = workspaceContaining(sessionID), other.id != activeID,
           let i = workspaces.firstIndex(where: { $0.id == other.id }) {
            workspaces[i].layout.detach(sessionID)
        }
        mutateLayout {
            if newPane {
                $0.detach(sessionID)
                $0.split($0.focusedPaneID, edge: .right, with: sessionID)
            } else {
                $0.open(sessionID)
            }
        }
        clearAttention(sessionID)
    }

    func newSession(_ kind: AgentKind, in wt: Worktree, newPane: Bool = false) {
        let s = makeSession(kind, in: wt)
        open(s.id, newPane: newPane)
    }

    private func makeSession(_ kind: AgentKind, in wt: Worktree) -> AgentSession {
        let n = created.filter { $0.kind == kind && worktreeOfSession[$0.id] == wt.path }.count + 1
        let s = AgentSession(id: "new:" + UUID().uuidString, kind: kind, agentSessionID: nil, cwd: wt.path,
                             title: kind == .shell ? "zsh \(n)" : "\(kind.displayName) \(n)", lastActivity: Date(), status: .running)
        created.append(s)
        rebuildIndex()
        notify(.projects)
        notify(.reveal(s.id))
        return s
    }

    /// Terminal for a session, started on first use. Discovered agents are resumed; new ones start fresh.
    func terminal(for id: String) -> TerminalView? {
        if let t = terminals[id] { return t }
        guard let s = session(id) else { return nil }
        let cwd = FileManager.default.fileExists(atPath: s.cwd) ? s.cwd : NSHomeDirectory()
        let t = TerminalView(sessionID: id, cwd: cwd, initialInput: AgentHooks.terminalCommand(for: s).map { $0 + "\n" },
                             env: AgentHooks.environment(session: id))
        t.onTitle = { [weak self] title in
            guard let self, self.liveTitles[id] != title else { return }
            self.liveTitles[id] = title
            self.notify(.session(id))
        }
        t.onAttention = { [weak self] in
            // Agents report through their hooks; a bell from them would only duplicate that.
            if self?.session(id)?.kind == .shell { self?.flagAttention(id) }
        }
        t.onNotify = { [weak self] title, body in self?.terminalNotification(id, title: title, body: body) }
        t.onCommandFinished = { [weak self] code in self?.agentQuit(id, exitCode: code) }
        t.onUserInput = { [weak self] isReturn in self?.userTyped(id, isReturn: isReturn) }
        t.contextMenu = { [weak self, weak t] in
            guard let self, let t else { return nil }
            return Menus.terminal(self, sessionID: id, view: t)
        }
        t.onFocus = { [weak self] in self?.focusSession(id) }
        t.onClose = { [weak self] alive in self?.confirmEnd(id, processAlive: alive) }
        terminals[id] = t
        if !created.contains(where: { $0.id == id }), var copy = discovered.first(where: { $0.id == id }) {
            copy.lastActivity = Date()
            created.append(copy)   // keeps it listed after it ages out of the scan window
        }
        rebuildIndex()
        notify(.session(id))
        return t
    }

    /// Closing a tab ends its process (after confirming if something is still running);
    /// agents stay listed in the sidebar and can be resumed.
    func closeTab(_ id: String) {
        if let t = terminals[id] { t.requestClose() } else { detachEverywhere(id) }
    }

    private func confirmEnd(_ id: String, processAlive: Bool) {
        if processAlive, let s = session(id) {
            let a = NSAlert()
            a.messageText = "结束「\(title(of: s))」？"
            a.informativeText = s.kind == .shell ? "终端里还有进程在运行。" : "\(s.kind.displayName) 还在运行。结束后可以在侧栏重新打开，继续这个会话。"
            a.addButton(withTitle: "结束")
            a.addButton(withTitle: "取消")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        endSession(id)
    }

    func endSession(_ id: String) {
        if let t = terminals.removeValue(forKey: id) {
            t.removeFromSuperview()
            t.destroy()
        }
        attention.remove(id)
        clearPhase(id)
        agentExited.remove(id)
        liveTitles[id] = nil
        detachEverywhere(id)
        if let i = created.firstIndex(where: { $0.id == id }), created[i].agentSessionID == nil {
            created.remove(at: i)   // a shell, or an agent that never saved anything: nothing to resume
        }
        rebuildIndex()
        notify(.projects)
    }

    private func detachEverywhere(_ id: String) {
        for i in workspaces.indices where workspaces[i].id != activeID { workspaces[i].layout.detach(id) }
        mutateLayout { $0.detach(id) }
    }

    func focusSession(_ id: String) {
        if let p = layout.pane(containing: id), layout.focusedPaneID != p.id || p.active != id {
            mutateLayout { $0.activate(id, in: p.id) }
        }
        clearAttention(id)
        markSeen()
    }

    private func flagAttention(_ id: String) {
        let focused = layout.focusedPane?.active == id && NSApp.isActive && terminals[id]?.window?.firstResponder === terminals[id]
        guard !focused, !attention.contains(id) else { return }
        attention.insert(id)
        notifier.setBadge(waitingIDs.count)
        resort(after: id)
    }

    func clearAttention(_ id: String) {
        guard attention.remove(id) != nil else { return }
        notifier.setBadge(waitingIDs.count)
        resort(after: id)
    }

    /// Waiting sessions float up: rebuild, and reload the lists only if the order actually changed.
    private func resort(after id: String) {
        let order = { self.worktreeOfSession[id].flatMap { self.sessionsByWorktree[$0] }?.map(\.id) }
        let before = order()
        rebuildIndex()
        let after = order()
        notify(before == after ? .session(id) : .projects)
    }

    func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    func togglePin(_ id: String) {
        if pinned.remove(id) == nil { pinned.insert(id) } else { pinnedRows[id] = nil }
        rebuildIndex()
        notify(.projects)
    }

    // MARK: Agent state (hooks → working / needs you / done; system notifications)

    private func agentEvent(_ info: [AnyHashable: Any]) {
        guard let id = info["session"] as? String, terminals[id] != nil else { return }
        let message = (info["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        agentExited.remove(id)
        let event = info["event"] as? String ?? ""
        Self.log.info("agent event \(event, privacy: .public) kind=\(info["kind"] as? String ?? "", privacy: .public) session=\(id, privacy: .public) seen=\(self.isSeen(id))")
        switch event {
        case "UserPromptSubmit", "PostToolUse":
            setPhase(id, .working)
        case "PreToolUse", "PermissionRequest":
            // AskUserQuestion / ExitPlanMode come through PreToolUse; everything else is a permission request.
            let kind = info["kind"] as? String ?? ""
            let need: NeedKind = kind == "AskUserQuestion" ? .question : kind == "ExitPlanMode" ? .plan : .permission
            if event == "PreToolUse" && need == .permission { return }
            if case .needsInput = phase[id], needKind[id] != .permission, need == .permission { return }   // keep the better label
            needKind[id] = need
            setPhase(id, .needsInput(message))
        case "Notification":
            // Claude also notifies after a minute of idling at its prompt; that turn already shows as done.
            let kind = info["kind"] as? String ?? ""
            if kind == "idle_prompt" || (kind.isEmpty && (message ?? "").contains("waiting for your input")) { return }
            if needKind[id] == nil || phase[id] == nil || phase[id] == .working { needKind[id] = .permission }
            setPhase(id, .needsInput(message))
        case "Stop":
            setPhase(id, .done(message))
        case "SessionEnd":
            setPhase(id, nil)
        default:
            break
        }
    }

    /// Codex's own terminal notifications: only approval requests matter (turn ends come from `notify`).
    private func terminalNotification(_ id: String, title: String, body: String) {
        guard let s = session(id) else { return }
        switch s.kind {
        case .shell: flagAttention(id)
        case .codex:
            // Codex writes "Approval requested: <command>" (a finished turn's text could mention approval too).
            if let t = [title, body].first(where: { $0.hasPrefix("Approval requested") }) { needKind[id] = .permission; setPhase(id, .needsInput(t)) }
        case .claude: break   // hooks say it better
        }
    }

    private func userTyped(_ id: String, isReturn: Bool) {
        guard let s = session(id), s.kind != .shell else { return }
        switch phase[id] {
        case .needsInput: setPhase(id, .working)           // answering the question
        case .working: break
        default:
            // Codex has no "prompt submitted" hook; Return at its prompt starts a turn.
            if s.kind == .codex, isReturn, !agentExited.contains(id) { setPhase(id, .working) }
        }
    }

    /// The agent's command ended. A non-zero exit (other than ^C, 130) is an error the user should see.
    private func agentQuit(_ id: String, exitCode: Int) {
        guard session(id)?.kind != .shell else { return }
        agentExited.insert(id)
        setPhase(id, exitCode > 0 && exitCode != 130 ? .failed(exitCode) : nil)
    }

    private func clearPhase(_ id: String) {
        phase[id] = nil; turnStarted[id] = nil; phaseSince[id] = nil; needKind[id] = nil
        notifier.remove(session: id)
        notifier.setBadge(waitingIDs.count)
    }

    /// The user can see this session now: its tab is showing in the active workspace and the app is in front.
    func isSeen(_ id: String) -> Bool { NSApp.isActive && layout.panes.contains { $0.active == id } }

    /// Finished turns the user is now looking at stop being "unread".
    func markSeen() {
        for (id, p) in phase where isSeen(id) {
            switch p {
            case .done, .failed: phase[id] = nil; notifier.remove(session: id); notify(.session(id))
            default: break
            }
        }
    }

    static let log = Logger(subsystem: "dev.seperate", category: "agent")

    private func setPhase(_ id: String, _ new: AgentPhase?) {
        let old = phase[id]
        guard old != new else { return }
        // PermissionRequest and Notification both announce the same question: one alert, the better message.
        if case .needsInput = old, case .needsInput(let m) = new {
            if m != nil { phase[id] = new; notify(.session(id)) }
            return
        }
        if new == .working, case .needsInput = old {} else if new == .working { turnStarted[id] = Date() }
        phase[id] = new
        phaseSince[id] = Date()
        if case .needsInput = new {} else { notifier.remove(session: id); needKind[id] = nil }
        notifier.setBadge(waitingIDs.count)
        if !isSeen(id), let s = session(id) {
            let who = "\(s.kind.displayName) · \(worktree(for: s).map(projectName(of:)) ?? title(of: s))"
            switch new {
            case .needsInput(let m):
                Self.log.info("notify needs-input session=\(id, privacy: .public)")
                notifier.post(session: id, title: who, subtitle: "需要你确认", body: m ?? title(of: s), sound: true)
            case .failed(let code):
                notifier.post(session: id, title: who, subtitle: "出错了 · 退出码 \(code)", body: title(of: s), sound: true)
            case .done(let m):
                // Quick answers do not need a notification; long turns do.
                if let start = turnStarted[id], Date().timeIntervalSince(start) >= Self.notifyDoneAfter {
                    notifier.post(session: id, title: who, subtitle: "完成 · 用时 \(Self.duration(Date().timeIntervalSince(start)))",
                                  body: m ?? title(of: s), sound: true)
                }
            default: break
            }
        }
        // A permission request always makes a sound, even for the session you are looking at (no banner then).
        if case .needsInput = new, isSeen(id) { NSSound(named: "Glass")?.play() }
        if case .done = new, isSeen(id) { phase[id] = nil }   // finished while you were watching: nothing unread
        if case .failed = new, isSeen(id) { phase[id] = nil }
        if case .done = new {} else if new == nil { turnStarted[id] = nil }
        resort(after: id)
    }

    static let notifyDoneAfter: TimeInterval = 30

    // MARK: Inbox

    /// Everything that wants the user's attention, plus what is still running. Newest first within a group.
    func inboxItems() -> [InboxItem] {
        var out: [InboxItem] = []
        let ids = Set(phase.keys).union(attention)
        for id in ids {
            guard let s = session(id) else { continue }
            let wsName = workspaceContaining(id).flatMap { $0.id == activeID ? nil : $0.name }
            let place = (worktree(for: s).map { projectName(of: $0) + ($0.isMain ? "" : " / " + $0.alias) } ?? s.cwd.abbreviatingHome)
                + (wsName.map { " · 在「\($0)」" } ?? "")
            let since = phaseSince[id] ?? s.lastActivity
            func item(_ label: InboxItem.Label, _ group: InboxItem.Group, _ message: String) -> InboxItem {
                InboxItem(id: id, agent: s.kind, title: title(of: s), place: place, message: message, label: label, group: group, since: since)
            }
            if attention.contains(id) { out.append(item(.bell, .needs, "终端响铃了")); continue }
            switch phase[id] {
            case .needsInput(let m):
                let label: InboxItem.Label = [.question: .question, .plan: .plan][needKind[id] ?? .permission] ?? .permission
                out.append(item(label, .needs, m ?? "等你处理"))
            case .done(let m):
                // A turn that ends by asking something is waiting for an answer.
                let text = (m ?? "完成").trimmingCharacters(in: .whitespacesAndNewlines)
                let asks = text.hasSuffix("?") || text.hasSuffix("？")
                let took = turnStarted[id].map { " · 用时 " + Self.duration(since.timeIntervalSince($0)) } ?? ""
                out.append(asks ? item(.question, .needs, text) : item(.done, .review, text + took))
            case .failed(let code): out.append(item(.failed, .review, "退出码 \(code)"))
            case .working: out.append(item(.working, .working, "正在运行 · 已 " + Self.duration(Date().timeIntervalSince(since))))
            case nil: break
            }
        }
        return out.sorted { ($0.group.rawValue, -$0.since.timeIntervalSince1970) < ($1.group.rawValue, -$1.since.timeIntervalSince1970) }
    }

    /// Finished turns and errors are marked read; questions and permission requests stay until answered.
    func markInboxRead() {
        for (id, p) in phase {
            switch p {
            case .done(let m):
                let t = (m ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !(t.hasSuffix("?") || t.hasSuffix("？")) { phase[id] = nil; notifier.remove(session: id); notify(.session(id)) }
            case .failed: phase[id] = nil; notifier.remove(session: id); notify(.session(id))
            default: break
            }
        }
    }

    /// Jump from the inbox: its workspace, its tab (opening one if needed), and it counts as read.
    func openFromInbox(_ id: String) {
        if workspaceContaining(id) != nil { reveal(id) } else { open(id) }
        markSeen()
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 60 ? "\(s / 60)分\(s % 60)秒" : "\(s)秒"
    }

    /// Jump to a session waiting in another workspace.
    func reveal(_ id: String) {
        if let w = workspaceContaining(id) { switchWorkspace(to: w.id) }
        focusSession(id)
    }

    // MARK: Layout (active workspace)

    /// Applies a layout mutation and tells views whether the pane structure changed.
    func mutateLayout(_ body: (inout LayoutModel) -> Void) {
        let before = layout
        var next = before
        body(&next)
        guard next != before else { return }
        layout = next
        notify(.layout(structure: LayoutModel.shape(next.root) != LayoutModel.shape(before.root)))
        markSeen()   // a finished turn that just came into view is read
    }

    var focusedWorktree: Worktree? { layout.focusedPane?.active.flatMap(session).flatMap(worktree(for:)) }

    func activate(_ id: String, in paneID: String) {
        mutateLayout { $0.activate(id, in: paneID) }
        clearAttention(id)
    }

    func focus(pane id: String) { mutateLayout { $0.focusedPaneID = id } }

    func focusPane(number n: Int) {
        let ps = layout.panes
        guard n >= 1, n <= ps.count else { return }
        focus(pane: ps[n - 1].id)
    }

    /// Splits a pane and starts a shell in the same worktree (an empty pane when there is none).
    func splitFocused(_ paneID: String, edge: DropEdge) {
        focus(pane: paneID)
        if let wt = focusedWorktree {
            let s = makeSession(.shell, in: wt)
            mutateLayout { $0.split(paneID, edge: edge, with: s.id) }
        } else {
            mutateLayout { $0.split(paneID, edge: edge) }
        }
    }

    func closePane(_ paneID: String) {
        guard let pane = layout.panes.first(where: { $0.id == paneID }) else { return }
        let live = pane.tabs.filter { terminals[$0] != nil }
        if !live.isEmpty {
            let a = NSAlert()
            a.messageText = "关闭这一栏？"
            a.informativeText = "这一栏里有 \(live.count) 个 Session 在运行，会一起结束。Codex / Claude 会话之后可以从侧栏恢复。"
            a.addButton(withTitle: "关闭")
            a.addButton(withTitle: "取消")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        live.forEach(endSession)
        mutateLayout { if $0.panes.count > 1 { $0.closePane(paneID) } }
    }

    func closeActiveTab() { if let id = layout.focusedPane?.active { closeTab(id) } }

    func newShellInFocusedPane() {
        guard let wt = focusedWorktree ?? visibleProjects.first.flatMap({ worktrees(of: $0).first }) else { return }
        newSession(.shell, in: wt)
    }

    func apply(_ preset: LayoutPreset) {
        let openElsewhere = Set(workspaces.filter { $0.id != activeID }.flatMap { $0.layout.openSessionIDs })
        let spare = sessionByID.values.filter { terminals[$0.id] != nil && !openElsewhere.contains($0.id) }
            .sorted { $0.lastActivity > $1.lastActivity }.map(\.id)
        mutateLayout { $0.apply(preset, fillWith: spare) }
    }

    func movePane(_ id: String, to target: String, edge: DropEdge?) { mutateLayout { $0.movePane(id, to: target, edge: edge) } }

    func setSizes(splitID: String, _ sizes: [Double]) { mutateLayout { $0.setSizes(splitID: splitID, sizes) } }

    func move(_ sid: String, to paneID: String, edge: DropEdge?) {
        if let other = workspaceContaining(sid), other.id != activeID, let i = workspaces.firstIndex(where: { $0.id == other.id }) {
            workspaces[i].layout.detach(sid)
        }
        mutateLayout { $0.move(sid, to: paneID, edge: edge) }
        clearAttention(sid)
    }

    func addTab(_ sid: String, to paneID: String) {
        if let other = workspaceContaining(sid), other.id != activeID, let i = workspaces.firstIndex(where: { $0.id == other.id }) {
            workspaces[i].layout.detach(sid)
        }
        mutateLayout { $0.addTab(sid, to: paneID) }
    }

    // MARK: Sidebar state

    func toggleShowOlder() {
        showOlder.toggle()
        rebuildIndex()
        notify(.projects)
    }

    func toggleSidebar() {
        sidebarHidden.toggle()
        notify(.sidebar)
    }

    // MARK: Projects (only ever added by the user, into a workspace)

    func addProject(path: String, to workspaceID: String? = nil) {
        let root = Core.repoInfo(path)?.root ?? path
        guard let i = workspaces.firstIndex(where: { $0.id == (workspaceID ?? activeID) }),
              !workspaces[i].projectRoots.contains(root) else { return }
        // One workspace per project: adding it here takes it out of wherever it was.
        for j in workspaces.indices { workspaces[j].projectRoots.removeAll { $0 == root } }
        workspaces[i].projectRoots.insert(root, at: 0)
        refreshProjects()
    }

    /// Makes a new folder `name` in `parent`, adds it to the active workspace and opens a shell in it.
    func createProject(name: String, in parent: String, git: Bool) throws {
        let dir = (parent as NSString).appendingPathComponent(name)
        try Core.projectCreate(dir: dir, git: git)
        addProject(path: dir)
        let root = Core.repoInfo(dir)?.root ?? dir
        if let p = project(root), let wt = worktrees(of: p).first { newSession(.shell, in: wt) }
    }

    /// Moves a worktree inside its project, before `before` (nil = to the end).
    func reorderWorktree(_ path: String, before: String?) {
        guard path != before, let wt = worktree(path: path), let p = project(wt.projectID) else { return }
        var paths = worktrees(of: p).map(\.path)
        paths.removeAll { $0 == path }
        paths.insert(path, at: before.flatMap { paths.firstIndex(of: $0) } ?? paths.count)
        guard paths != worktrees(of: p).map(\.path) else { return }
        worktreeOrder[p.id] = paths
        let others = worktrees.filter { $0.projectID != p.id }
        let mine = paths.compactMap { path in worktrees.first { $0.path == path } }
        // Keep the global list grouped by project in project order.
        worktrees = projects.flatMap { proj in proj.id == p.id ? mine : others.filter { $0.projectID == proj.id } }
        rebuildIndex()
        notify(.projects)
    }

    /// Moves a project inside the active workspace to `index` (an insertion point in the current order).
    func reorderProject(_ id: String, to index: Int) {
        var roots = workspaces[activeIndex].projectRoots
        guard let from = roots.firstIndex(of: id) else { return }
        roots.remove(at: from)
        roots.insert(id, at: min(max(0, from < index ? index - 1 : index), roots.count))
        guard roots != workspaces[activeIndex].projectRoots else { return }
        workspaces[activeIndex].projectRoots = roots
        notify(.projects)
    }

    /// Removes the project from the active workspace only; other workspaces keep it.
    /// Sessions of a project that have a tab somewhere (open in any workspace, or running).
    func openSessions(of p: Project) -> [String] {
        let paths = Set(worktrees(of: p).map(\.path))
        let open = Set(workspaces.flatMap(\.layout.openSessionIDs)).union(terminals.keys)
        return open.filter { worktreeOfSession[$0].map(paths.contains) ?? false }.sorted()
    }

    /// Takes the project out of Seperate: its tabs close (running ones end), its place in the list goes.
    /// Nothing on disk is touched; adding the folder again brings everything back.
    func removeProject(_ p: Project) {
        for id in openSessions(of: p) {
            if terminals[id] != nil { endSession(id) } else { detachEverywhere(id) }
        }
        for i in workspaces.indices { workspaces[i].projectRoots.removeAll { $0 == p.id } }
        worktreeOrder[p.id] = nil
        refreshProjects()
    }

    func promptRemoveProject(_ p: Project) {
        let running = openSessions(of: p).filter { terminals[$0] != nil }.count
        let a = NSAlert()
        a.messageText = "从 Seperate 移除「\(p.name)」？"
        a.informativeText = "只是不再在 Seperate 里显示：文件夹、Git 仓库和 Codex / Claude 的会话记录都不会被删除，之后重新添加这个文件夹就能恢复。"
            + (running > 0 ? "\n\n它有 \(running) 个 Session 正在运行，会一起结束。" : "")
        a.addButton(withTitle: "移除")
        a.addButton(withTitle: "取消")
        if running > 0 { a.buttons[0].hasDestructiveAction = true }
        if a.runModal() == .alertFirstButtonReturn { removeProject(p) }
    }

    /// Moves the project into another workspace (a project lives in exactly one).
    func moveProject(_ p: Project, to workspaceID: String) {
        guard let i = workspaces.firstIndex(where: { $0.id == workspaceID }), !workspaces[i].projectRoots.contains(p.id) else { return }
        for j in workspaces.indices { workspaces[j].projectRoots.removeAll { $0 == p.id } }
        workspaces[i].projectRoots.insert(p.id, at: 0)
        refreshProjects()
    }

    func workspaces(containing p: Project) -> [Workspace] { workspaces.filter { $0.projectRoots.contains(p.id) } }

    func rename(_ wt: Worktree, to alias: String) {
        let a = alias.trimmingCharacters(in: .whitespaces)
        aliases[wt.path] = a.isEmpty ? nil : a
        refreshProjects()
    }

    func createWorktree(in p: Project, name: String) throws {
        let dir = (p.rootPath as NSString).deletingLastPathComponent + "/" + (p.name + "-" + name)
        try Core.worktreeAdd(root: p.rootPath, dir: dir)
        aliases[dir] = name
        refreshProjects()
    }

    /// Where a new worktree named `name` goes: next to the repo, in "<repo>.worktrees/".
    func newWorktreeDir(in p: Project, name: String) -> String {
        (p.rootPath as NSString).deletingLastPathComponent + "/\(p.name).worktrees/" + name
    }

    /// A worktree from `base`, on the new branch `branch` (nil = detached).
    func createWorktree(in p: Project, name: String, base: String, branch: String?) throws {
        let dir = newWorktreeDir(in: p, name: name)
        try FileManager.default.createDirectory(atPath: (dir as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Core.worktreeAdd(root: p.rootPath, dir: dir, branch: branch, base: base)
        aliases[dir] = name
        refreshProjects()
    }

    // MARK: Removing worktrees (from Seperate only, or from disk)

    /// Tabs of sessions in this worktree, in any workspace, plus running ones.
    func openSessions(in wt: Worktree) -> [String] {
        let open = Set(workspaces.flatMap(\.layout.openSessionIDs)).union(terminals.keys)
        return open.filter { worktreeOfSession[$0] == wt.path }.sorted()
    }

    private func closeSessions(in wt: Worktree) {
        for id in openSessions(in: wt) {
            if terminals[id] != nil { endSession(id) } else { detachEverywhere(id) }
        }
    }

    /// Stops showing a worktree; its folder and git's record stay. The main worktree cannot be hidden.
    func hideWorktree(_ wt: Worktree) {
        guard !wt.isMain else { return }
        closeSessions(in: wt)
        hiddenWorktrees[wt.path] = (wt.projectID, Date())
        refreshProjects()
    }

    func unhideWorktree(_ path: String) {
        guard hiddenWorktrees.removeValue(forKey: path) != nil else { return }
        refreshProjects()
    }

    func hiddenWorktrees(of p: Project) -> [(path: String, at: Date)] {
        hiddenWorktrees.filter { $0.value.projectRoot == p.id }.map { ($0.key, $0.value.at) }.sorted { $0.at > $1.at }
    }

    /// Deletes the worktree folder (`git worktree remove`, `force` discards changes) and optionally its
    /// branch (merged only). Returns why the branch was kept, if it was.
    @discardableResult
    func deleteWorktree(_ wt: Worktree, force: Bool, deleteBranch branch: String?) throws -> String? {
        guard !wt.isMain, let p = project(wt.projectID) else { return nil }
        closeSessions(in: wt)
        try Core.worktreeRemove(root: p.rootPath, path: wt.path, force: force)
        let kept = branch.flatMap { Core.branchDelete(root: p.rootPath, branch: $0) }
        aliases[wt.path] = nil
        hiddenWorktrees[wt.path] = nil
        worktreeOrder[p.id]?.removeAll { $0 == wt.path }
        refreshProjects()
        return kept
    }

    func setDefaultEditor(_ app: ExternalApp) {
        defaultEditor = app
        scheduleSave()
        notify(.layout(structure: false))
    }

    /// The editor used by the header button: the chosen one if still installed, else the first installed.
    var preferredEditor: ExternalApp? {
        if let d = defaultEditor, d.url != nil { return d }
        return ExternalApp.editors.first
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func pickProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择项目文件夹，加入「\(active.name)」（Git 仓库会自动识别它的所有 Worktree）"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addProject(path: url.path) }
    }

    func promptText(title: String, message: String, initial: String = "", placeholder: String = "", button: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        let field = NSTextField(string: initial)
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: button)
        a.addButton(withTitle: "取消")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    func promptRename(_ wt: Worktree) {
        if let v = promptText(title: "重命名 Worktree", message: wt.path.abbreviatingHome, initial: wt.alias, button: "保存") { rename(wt, to: v) }
    }

    func promptNewWorktree(in p: Project) {
        guard let w = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NewWorktreeSheet(store: self, project: p).present(on: w)
    }

    func promptNewProject() {
        guard let w = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NewProjectSheet(store: self).present(on: w)
    }

    func promptNewWorkspace() {
        if let name = promptText(title: "新建 Workspace", message: "一组项目和它们的分栏布局，比如「公司」「个人」。", placeholder: "公司", button: "创建") {
            addWorkspace(name: name)
        }
    }

    func promptRenameWorkspace(_ w: Workspace) {
        if let v = promptText(title: "重命名 Workspace", message: "", initial: w.name, button: "保存") { renameWorkspace(w.id, to: v) }
    }

    func promptDeleteWorkspace(_ w: Workspace) {
        let live = w.layout.openSessionIDs.filter { terminals[$0] != nil }.count
        let a = NSAlert()
        a.messageText = "删除「\(w.name)」？"
        a.informativeText = "项目和会话记录都会保留。" + (live > 0 ? "这个 Workspace 里有 \(live) 个 Session 在运行，会一起结束。" : "")
        a.addButton(withTitle: "删除")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { deleteWorkspace(w.id) }
    }

    // MARK: Refresh (Rust core, off the main thread; views are told only when something changed)

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let roots = allRoots, aliases = self.aliases, order = worktreeOrder, hidden = Set(hiddenWorktrees.keys)
        Task.detached(priority: .utility) {
            let found = Core.scanSessions()
            let (ps, ws) = Self.resolveProjects(roots: roots, aliases: aliases, order: order, hidden: hidden)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.refreshing = false
                var changed = false
                if found != self.discovered { self.discovered = found; changed = true }
                if ps != self.projects || ws != self.worktrees { self.projects = ps; self.worktrees = ws; changed = true }
                if self.adoptAgentIDs() { changed = true }
                if changed { self.rebuildIndex(); self.notify(.projects) }
            }
        }
    }

    func refreshProjects() {
        let (ps, ws) = Self.resolveProjects(roots: allRoots, aliases: aliases, order: worktreeOrder, hidden: Set(hiddenWorktrees.keys))
        projects = ps; worktrees = ws
        rebuildIndex()
        notify(.projects)
    }

    nonisolated private static func resolveProjects(roots: [String], aliases: [String: String],
                                                    order: [String: [String]], hidden: Set<String> = []) -> ([Project], [Worktree]) {
        var ps: [Project] = [], ws: [Worktree] = []
        for root in roots {
            let info = Core.repoInfo(root)
            let name = (root as NSString).lastPathComponent
            ps.append(Project(id: root, name: name, rootPath: root, isGit: info != nil, iconPath: Core.projectIcon(root)))
            var entries = info?.worktrees.map { ($0.path, $0.isMain) } ?? [(root, true)]
            // The user's order first; worktrees it does not know yet keep git's order after them.
            let rank = Dictionary((order[root] ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            entries = entries.enumerated().sorted { (rank[$0.element.0] ?? Int.max, $0.offset) < (rank[$1.element.0] ?? Int.max, $1.offset) }.map(\.element)
            for (path, isMain) in entries where isMain || !hidden.contains(path) {
                let alias = aliases[path] ?? (isMain ? "主目录" : (path as NSString).lastPathComponent)
                ws.append(Worktree(projectID: root, path: path, alias: alias, isMain: isMain))
            }
        }
        return (ps, ws)
    }

    /// New agents get their conversation id once the CLI writes its transcript; match by kind + cwd + time.
    private func adoptAgentIDs() -> Bool {
        var claimed = Set(created.compactMap(\.agentSessionID)), changed = false
        for i in created.indices where created[i].agentSessionID == nil && created[i].kind != .shell {
            let s = created[i]
            if let match = discovered
                .filter({ $0.kind == s.kind && $0.cwd == s.cwd && $0.lastActivity >= s.lastActivity.addingTimeInterval(-5)
                          && !claimed.contains($0.agentSessionID ?? "") })
                .min(by: { $0.lastActivity < $1.lastActivity }) {
                created[i].agentSessionID = match.agentSessionID
                if liveTitles[s.id] == nil { created[i].title = match.title }
                claimed.insert(match.agentSessionID ?? "")
                changed = true
            }
        }
        return changed
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var workspaces: [Workspace]
        var activeID: String
        var aliases: [String: String]
        var showOlder: Bool
        var sidebarHidden: Bool
        var created: [AgentSession]
    }

    /// Pre-workspace state file (single project list + layout).
    private struct SavedV1: Codable {
        var projectRoots: [String]
        var aliases: [String: String]
        var showOlder: Bool
        var sidebarHidden: Bool?
        var created: [AgentSession]
        var layout: LayoutModel
    }

    /// Where the app keeps its data. Tests point SEPERATE_DATA_DIR at a temp folder.
    nonisolated static var dataDir: URL {
        let dir = ProcessInfo.processInfo.environment["SEPERATE_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Workbench", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    // Demo launches (WORKBENCH_DEMO) keep their own data so they never touch the real layout.
    private static var isDemo: Bool { ProcessInfo.processInfo.environment["WORKBENCH_DEMO"] != nil }
    static var dbURL: URL { dataDir.appendingPathComponent(isDemo ? "seperate-demo.db" : "seperate.db") }
    static var legacyURL: URL { dataDir.appendingPathComponent(isDemo ? "state-demo.json" : "state.json") }

    /// SQLite (seperate.db, owned by the core). The old state.json is imported once and kept as state.json.bak.
    private func load() {
        if let err = Core.dbOpen(Self.dbURL.path) {
            NSLog("Seperate: database unavailable (%@), using state.json", err)
            _ = loadLegacy()
        } else {
            dbReady = true
            let stored = Core.dbLoad()
            if let stored, !stored.workspaces.isEmpty {
                apply(stored)
            } else if loadLegacy(), saveNow() {
                try? FileManager.default.moveItem(at: Self.legacyURL, to: Self.legacyURL.appendingPathExtension("bak"))
            } else if let stored {
                apply(stored)
            }
        }
        // A project lives in one workspace; older data may list it twice (first one wins).
        var seen = Set<String>()
        for i in workspaces.indices { workspaces[i].projectRoots = workspaces[i].projectRoots.filter { seen.insert($0).inserted } }
        // Nothing runs after a restart; resumable agents come back as history.
        created = created.filter { $0.agentSessionID != nil }.map { var c = $0; c.status = .history; return c }
        let valid = Set(created.map(\.id))
        for i in workspaces.indices { workspaces[i].layout.prune(keeping: valid) }
    }

    private func apply(_ s: Core.DBState) {
        workspaces = s.workspaces.map { r in
            Workspace(id: r.id, name: r.name, icon: r.icon, tint: UInt32(r.color.dropFirst(), radix: 16) ?? Workspace.tints[0].color,
                      projectRoots: r.projects,
                      layout: (try? JSONDecoder().decode(LayoutModel.self, from: Data(r.layout.utf8))) ?? LayoutModel())
        }
        activeID = s.activeID
        aliases = s.aliases
        worktreeOrder = s.worktreeOrder
        hiddenWorktrees = Dictionary(s.hiddenWorktrees.map { ($0.path, (projectRoot: $0.projectRoot, at: Date(timeIntervalSince1970: TimeInterval($0.hiddenAt) / 1000))) },
                                     uniquingKeysWith: { a, _ in a })
        defaultEditor = s.settings["default_editor"].flatMap(ExternalApp.init(rawValue:))
        showOlder = s.settings["show_older"] == "true"
        sidebarHidden = s.settings["sidebar_hidden"] == "true"
        created = s.sessions.filter { $0.origin == "created" }.map {
            AgentSession(id: $0.id, kind: AgentKind(rawValue: $0.kind) ?? .shell, agentSessionID: $0.agentSessionID, cwd: $0.cwd,
                         title: $0.title, lastActivity: Date(timeIntervalSince1970: TimeInterval($0.lastActivityAt) / 1000))
        }
        let pins = s.sessions.filter(\.pinned)
        pinned = Set(pins.map(\.id))
        pinnedRows = Dictionary(pins.filter { $0.origin == "discovered" }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The pre-SQLite state file, in either of its two shapes.
    private func loadLegacy() -> Bool {
        guard let data = try? Data(contentsOf: Self.legacyURL) else { return false }
        if let s = try? JSONDecoder().decode(Saved.self, from: data) {
            workspaces = s.workspaces; activeID = s.activeID
            aliases = s.aliases; showOlder = s.showOlder; sidebarHidden = s.sidebarHidden
            created = s.created
        } else if let v1 = try? JSONDecoder().decode(SavedV1.self, from: data) {
            let w = Workspace.make(name: "默认", projectRoots: v1.projectRoots, layout: v1.layout)
            workspaces = [w]; activeID = w.id
            aliases = v1.aliases; showOlder = v1.showOlder; sidebarHidden = v1.sidebarHidden ?? false
            created = v1.created
        } else { return false }
        return true
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    @discardableResult
    func saveNow() -> Bool {
        guard dbReady else {
            let s = Saved(workspaces: workspaces, activeID: activeID, aliases: aliases, showOlder: showOlder,
                          sidebarHidden: sidebarHidden, created: created)
            guard let data = try? JSONEncoder().encode(s) else { return false }
            return (try? data.write(to: Self.legacyURL, options: .atomic)) != nil
        }
        let ms = { (d: Date) in Int64(d.timeIntervalSince1970 * 1000) }
        func row(_ x: AgentSession, origin: String) -> Core.DBState.SessionRow {
            .init(id: x.id, kind: x.kind.rawValue, agentSessionID: x.agentSessionID, origin: origin, cwd: x.cwd, title: x.title,
                  customTitle: nil, createdAt: ms(x.lastActivity), lastActivityAt: ms(x.lastActivity), pinned: pinned.contains(x.id))
        }
        let createdIDs = Set(created.map(\.id))
        var rows = created.map { row($0, origin: "created") }
        for id in pinned where !createdIDs.contains(id) {
            if let x = sessionByID[id] { rows.append(row(x, origin: "discovered")) } else if let r = pinnedRows[id] { rows.append(r) }
        }
        let state = Core.DBState(
            activeID: activeID,
            workspaces: workspaces.map {
                .init(id: $0.id, name: $0.name, icon: $0.icon, color: String(format: "#%06X", $0.tint & 0xFFFFFF),
                      layout: (try? JSONEncoder().encode($0.layout)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}",
                      projects: $0.projectRoots)
            },
            aliases: aliases,
            worktreeOrder: worktreeOrder,
            hiddenWorktrees: hiddenWorktrees.map { .init(path: $0.key, projectRoot: $0.value.projectRoot, hiddenAt: ms($0.value.at)) },
            settings: ["show_older": String(showOlder), "sidebar_hidden": String(sidebarHidden)]
                .merging(defaultEditor.map { ["default_editor": $0.rawValue] } ?? [:]) { a, _ in a },
            sessions: rows)
        if let err = Core.dbSave(state) { NSLog("Seperate: save failed: %@", err); return false }
        return true
    }

    func shutdown() {
        saveNow()
        for t in terminals.values { t.destroy() }
        terminals.removeAll()
    }
}

extension LayoutModel {
    /// Pane ids and nesting only — what decides whether views must be rebuilt.
    static func shape(_ n: LayoutNode) -> String {
        switch n {
        case .pane(let p): return p.id
        case .split(let id, let axis, _, let kids): return "\(id)\(axis == .horizontal ? "H" : "V")(\(kids.map(shape).joined(separator: ",")))"
        }
    }
}
