// @purpose What each `seperate` CLI command does: list / status / new / send / key / read / wait / open / close / refresh.
// @role    ControlServer hands every decoded request to handle(_:); everything here goes through Store's methods.
// @deps    AppKit (key codes via Carbon), Store, LayoutModel (DropEdge)
// @gotcha  Replies carry both `data` (for --json) and `text` (what the CLI prints). A new session must be the shown
//          tab of a pane or its terminal never starts. `wait` counts reports after the last send, so a turn that
//          ended before `wait` was called is not missed. docs/modules/cli/README.md
import AppKit
import Carbon.HIToolbox

@MainActor
final class ControlCommands {
    static let protocolVersion = 1
    private let store: Store
    /// Report number at the last `new` / `send` / `key` per session: `wait` answers with what came after it.
    private var sentAt: [String: Int] = [:]

    init(store: Store) { self.store = store }

    struct Failure: Error { let message: String }

    func handle(_ req: [String: Any]) async -> [String: Any] {
        guard (req["v"] as? Int) == Self.protocolVersion else {
            return ["ok": false, "error": "this seperate CLI does not match the running app; restart Seperate"]
        }
        let args = req["args"] as? [String: Any] ?? [:]
        let ctx = Context(caller: (req["caller"] as? String).flatMap { store.session($0) != nil ? $0 : nil },
                          cwd: req["cwd"] as? String ?? NSHomeDirectory(), origin: req["origin"] as? String ?? "")
        do {
            let (data, text) = try await run(req["cmd"] as? String ?? "", args, ctx)
            return ["ok": true, "data": data, "text": text]
        } catch let f as Failure {
            return ["ok": false, "error": f.message]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    struct Context {
        let caller: String?
        let cwd: String
        let origin: String
    }

    private func run(_ cmd: String, _ a: [String: Any], _ ctx: Context) async throws -> ([String: Any], String) {
        switch cmd {
        case "list": return list(all: a["all"] as? Bool ?? false, ctx)
        case "status":
            let id = try resolve(a["session"], ctx)
            let info = describe(id, ctx)
            return (info, statusText(info))
        case "new": return try newSession(a, ctx)
        case "send": return try send(a, ctx)
        case "key": return try await keys(a, ctx)
        case "read":
            let id = try resolve(a["session"], ctx)
            guard let t = store.terminals[id], let text = t.recentText(lines: min(max(a["lines"] as? Int ?? 80, 1), 5000)) else {
                throw Failure(message: "\(handle(id)) is not running here; `seperate open \(handle(id))` starts it")
            }
            return (["session": id, "text": text], text)
        case "wait": return try await wait(a, ctx)
        case "open":
            let id = try resolve(a["session"], ctx)
            store.goTo(id)
            return (describe(id, ctx), "Opened \(handle(id)) in Seperate.")
        case "close": return try close(a, ctx)
        case "refresh":
            store.refresh()
            return ([:], "Rescanning sessions.")
        default:
            throw Failure(message: "unknown command \"\(cmd)\"; see `seperate --help`")
        }
    }

    // MARK: Sessions by reference

    /// Every session the app knows: running ones, open tabs, and each worktree's history.
    private var knownIDs: [String] {
        var seen = Set<String>(), out: [String] = []
        let ids = Array(store.terminals.keys) + store.workspaces.flatMap(\.layout.openSessionIDs) + store.worktrees.flatMap { store.allSessions(in: $0).map(\.id) }
        for id in ids where store.session(id) != nil && seen.insert(id).inserted { out.append(id) }
        return out
    }

    /// The short handle shown everywhere: 8 characters of the id after its "kind:" prefix.
    func handle(_ id: String) -> String { String((id.split(separator: ":").last.map(String.init) ?? id).lowercased().prefix(8)) }

    /// An id, an agent session id, a unique prefix of either (or of the handle), or "self".
    private func resolve(_ ref: Any?, _ ctx: Context) throws -> String {
        guard let ref = (ref as? String)?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else { throw Failure(message: "which session? pass its id (see `seperate list`)") }
        if ref == "self" || ref == "." {
            guard let c = ctx.caller else { throw Failure(message: "\"self\" only works inside a Seperate terminal") }
            return c
        }
        if store.session(ref) != nil { return ref }
        let r = ref.lowercased()
        let matches = knownIDs.filter { id in
            let s = store.session(id)
            return id.lowercased().hasPrefix(r) || handle(id).hasPrefix(r) || (id.split(separator: ":").last.map { $0.lowercased().hasPrefix(r) } ?? false)
                || (s?.agentSessionID?.lowercased().hasPrefix(r) ?? false)
        }
        if matches.count == 1 { return matches[0] }
        let live = matches.filter { store.terminals[$0] != nil }
        if live.count == 1 { return live[0] }
        if matches.isEmpty { throw Failure(message: "no session matches \"\(ref)\"; see `seperate list --all`") }
        throw Failure(message: "\"\(ref)\" matches \(matches.count) sessions (\(matches.prefix(5).map(handle).joined(separator: ", "))); use more characters")
    }

    // MARK: Describing

    private func state(_ id: String) -> String {
        guard store.terminals[id] != nil else { return "history" }
        switch store.phase[id] {
        case .working: return "working"
        case .needsInput: return "needs-input"
        case .done: return "done"
        case .failed: return "failed"
        case nil:
            if store.session(id)?.kind == .shell { return "running" }
            return store.hasExited(id) ? "exited" : "idle"
        }
    }

    private static func needName(_ n: NeedKind?) -> String? {
        switch n { case .permission: "permission"; case .question: "question"; case .plan: "plan"; case .bell: "bell"; case nil: nil }
    }

    private static func reportState(_ r: Store.AgentReport, exited: Bool) -> String {
        switch r.phase {
        case .working: "working"
        case .needsInput: "needs-input"
        case .done: "done"
        case .failed: "failed"
        case nil: exited ? "exited" : "idle"
        }
    }

    private static func message(_ p: AgentPhase?) -> String? {
        switch p {
        case .needsInput(let m), .done(let m): m
        case .failed(let code): "exit code \(code)"
        default: nil
        }
    }

    private func describe(_ id: String, _ ctx: Context) -> [String: Any] {
        guard let s = store.session(id) else { return ["id": id] }
        var d: [String: Any] = ["id": id, "handle": handle(id), "kind": s.kind.rawValue, "title": store.title(of: s),
                                "cwd": s.cwd, "state": state(id), "running": store.terminals[id] != nil,
                                "open": store.workspaceContaining(id) != nil, "you": id == ctx.caller]
        if let a = s.agentSessionID { d["agentSessionId"] = a }
        if let wt = store.worktree(for: s) { d["project"] = store.projectName(of: wt); d["worktree"] = wt.alias; d["worktreePath"] = wt.path }
        if let w = store.workspaceContaining(id) { d["workspace"] = w.name }
        if case .needsInput = store.phase[id] { d["need"] = Self.needName(store.needKind(of: id)) }
        if let m = store.phaseMessage(of: id) { d["message"] = m }
        if let last = store.reports[id]?.last(where: { $0.phase != .working }) {
            var l: [String: Any] = ["state": Self.reportState(last, exited: store.hasExited(id)), "seq": last.seq, "at": last.at.timeIntervalSince1970]
            if let m = Self.message(last.phase) { l["message"] = m }
            d["last"] = l
        }
        if let n = store.remoteNotes[id] { d["by"] = n.by }
        return d
    }

    private func statusText(_ d: [String: Any]) -> String {
        var lines = ["\(d["handle"] ?? "")  \(d["kind"] ?? "")  \(d["state"] ?? "")" + ((d["need"] as? String).map { " (\($0))" } ?? "")]
        lines.append("title: \(d["title"] ?? "")")
        lines.append("where: " + ((d["project"] as? String).map { "\($0) / \(d["worktree"] ?? "")  " } ?? "") + "\(d["cwd"] ?? "")")
        if let m = d["message"] as? String { lines.append("message: \(m)") }
        else if let l = d["last"] as? [String: Any], let m = l["message"] as? String { lines.append("last \(l["state"] ?? ""): \(m)") }
        return lines.joined(separator: "\n")
    }

    private func list(all: Bool, _ ctx: Context) -> ([String: Any], String) {
        var out: [[String: Any]] = [], text: [String] = []
        for w in store.workspaces {
            var projects: [[String: Any]] = []
            text.append("Workspace \(w.name)" + (w.id == store.activeID ? " (active)" : ""))
            for root in w.projectRoots {
                guard let p = store.project(root) else { continue }
                text.append("  \(p.name)  \(p.rootPath)")
                var wts: [[String: Any]] = []
                for wt in store.worktrees(of: p) {
                    text.append("    [\(wt.alias)]  \(wt.path)")
                    let sessions = store.allSessions(in: wt)
                    let live = sessions.filter { store.terminals[$0.id] != nil || store.workspaceContaining($0.id) != nil }
                    let shown = all ? live + sessions.filter { s in !live.contains { $0.id == s.id } }.prefix(5) : live
                    let rows = shown.map { describe($0.id, ctx) }
                    for r in rows {
                        let state = (r["state"] as? String ?? "") + ((r["need"] as? String).map { "(\($0))" } ?? "")
                        let kind = (r["kind"] as? String ?? "").padding(toLength: 6, withPad: " ", startingAt: 0)
                        text.append("      \(r["handle"] ?? "")  \(kind)  \(state.padding(toLength: 22, withPad: " ", startingAt: 0))  \(r["title"] ?? "")" + (r["you"] as? Bool == true ? "  <- you" : ""))
                    }
                    wts.append(["alias": wt.alias, "path": wt.path, "main": wt.isMain, "sessions": rows])
                }
                projects.append(["name": p.name, "root": p.rootPath, "worktrees": wts])
            }
            out.append(["name": w.name, "active": w.id == store.activeID, "projects": projects])
        }
        if out.allSatisfy({ ($0["projects"] as? [Any])?.isEmpty ?? true }) { text.append("(no projects yet; `seperate new … --cwd DIR --add-project` adds one)") }
        return (["workspaces": out], text.joined(separator: "\n"))
    }

    // MARK: Driving sessions

    /// Who is doing this, for the "typed by …" line in the pane header.
    private func by(_ ctx: Context) -> String {
        if let c = ctx.caller, let s = store.session(c) { return store.title(of: s) }
        return ctx.origin.isEmpty ? tr("外部程序", "an outside program") : ctx.origin
    }

    private func newSession(_ a: [String: Any], _ ctx: Context) throws -> ([String: Any], String) {
        guard let kind = (a["kind"] as? String).flatMap(AgentKind.init(rawValue:)) else {
            throw Failure(message: "seperate new needs claude, codex or shell")
        }
        let given = ((a["cwd"] as? String ?? ctx.cwd) as NSString).expandingTildeInPath
        let dir = Self.real(given)
        // Paths may come through a symlink on either side (/var vs /private/var): compare both forms.
        func enclosing() -> Worktree? {
            store.worktrees.sorted { $0.path.count > $1.path.count }.first { wt in
                [given, dir].contains { $0.isPath(inside: wt.path) || $0.isPath(inside: Self.real(wt.path)) }
            }
        }
        var wt = enclosing()
        if wt == nil, a["addProject"] as? Bool == true {
            guard FileManager.default.fileExists(atPath: dir) else { throw Failure(message: "\(dir) does not exist") }
            store.addProject(path: given)
            wt = enclosing()
        }
        guard var target = wt else {
            let known = store.projects.map { "  \($0.rootPath)" }.joined(separator: "\n")
            throw Failure(message: "\(dir) is not inside a project Seperate knows. Pass --cwd <project dir>, or --add-project to add this folder.\nProjects:\n\(known)")
        }
        guard let p = store.project(target.projectID) else { throw Failure(message: "project not found") }
        if let name = a["newWorktree"] as? String, !name.isEmpty {
            do {
                try store.createWorktree(in: p, name: name, base: a["base"] as? String ?? "HEAD", branch: a["branch"] as? String ?? name)
            } catch {
                throw Failure(message: "could not create worktree \(name): \(error.localizedDescription)")
            }
            guard let made = store.worktree(path: store.newWorktreeDir(in: p, name: name)) else { throw Failure(message: "worktree \(name) was created but not found") }
            target = made
        } else if let name = a["worktree"] as? String, !name.isEmpty {
            guard let named = store.worktrees(of: p).first(where: { $0.alias == name || ($0.path as NSString).lastPathComponent == name || $0.path == name }) else {
                throw Failure(message: "no worktree \"\(name)\" in \(p.name); have: \(store.worktrees(of: p).map(\.alias).joined(separator: ", "))")
            }
            target = named
        }
        let place = a["place"] as? String ?? "right"
        let edge: DropEdge? = switch place { case "tab": nil; case "down": .bottom; default: .right }
        let s = try store.startSession(kind, in: target, prompt: a["prompt"] as? String, skipPermissions: a["skipPermissions"] as? Bool ?? false,
                                       nearPane: ctx.caller.flatMap { store.layout.pane(containing: $0)?.id }, edge: edge,
                                       focus: a["focus"] as? Bool ?? false, by: by(ctx))
        sentAt[s.id] = store.reportSeq
        let h = handle(s.id)
        let next = kind == .shell ? "`seperate read \(h)` shows its output." : "`seperate wait \(h)` waits for its turn to end; `seperate read \(h)` shows its screen."
        return (describe(s.id, ctx), "Started \(h) (\(kind.displayName)) in \(store.projectName(of: target)) / \(target.alias).\n\(next)")
    }

    private func live(_ ref: Any?, _ ctx: Context, verb: String) throws -> String {
        let id = try resolve(ref, ctx)
        if id == ctx.caller { throw Failure(message: "that is your own session; \(verb) another one") }
        guard store.terminals[id] != nil else { throw Failure(message: "\(handle(id)) is not running here; `seperate open \(handle(id))` starts it") }
        return id
    }

    private func send(_ a: [String: Any], _ ctx: Context) throws -> ([String: Any], String) {
        let id = try live(a["session"], ctx, verb: "send to")
        let text = a["text"] as? String ?? ""
        let enter = a["enter"] as? Bool ?? true
        guard store.remoteType(id, text: text, enter: enter, by: by(ctx)) else { throw Failure(message: "\(handle(id))'s terminal has not started yet; try again in a moment") }
        sentAt[id] = store.reportSeq
        let kind = store.session(id)?.kind
        return (["session": id], "Sent to \(handle(id))." + (kind == .shell ? "" : " `seperate wait \(handle(id))` waits for the reply."))
    }

    /// Named keys for `seperate key`: keyCode, the text the key types, modifiers.
    static let keyTable: [String: (Int, String?, NSEvent.ModifierFlags)] = {
        var t: [String: (Int, String?, NSEvent.ModifierFlags)] = [
            "enter": (kVK_Return, "\r", []), "return": (kVK_Return, "\r", []),
            "esc": (kVK_Escape, "\u{1b}", []), "escape": (kVK_Escape, "\u{1b}", []),
            "tab": (kVK_Tab, "\t", []), "shift-tab": (kVK_Tab, nil, [.shift]),
            "up": (kVK_UpArrow, nil, []), "down": (kVK_DownArrow, nil, []), "left": (kVK_LeftArrow, nil, []), "right": (kVK_RightArrow, nil, []),
            "backspace": (kVK_Delete, "\u{7f}", []), "space": (kVK_Space, " ", []),
            "ctrl-c": (kVK_ANSI_C, "\u{03}", [.control]), "ctrl-d": (kVK_ANSI_D, "\u{04}", [.control]),
            "y": (kVK_ANSI_Y, "y", []), "n": (kVK_ANSI_N, "n", []),
        ]
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, code) in digits.enumerated() { t[String(i + 1)] = (code, String(i + 1), []) }
        return t
    }()

    private func keys(_ a: [String: Any], _ ctx: Context) async throws -> ([String: Any], String) {
        let id = try live(a["session"], ctx, verb: "press keys in")
        let names = (a["keys"] as? [String] ?? []).map { $0.lowercased() }
        guard !names.isEmpty else { throw Failure(message: "which keys? e.g. `seperate key \(handle(id)) down enter`") }
        if let bad = names.first(where: { Self.keyTable[$0] == nil }) {
            throw Failure(message: "unknown key \"\(bad)\"; known: \(Self.keyTable.keys.sorted().joined(separator: " "))")
        }
        for (i, n) in names.enumerated() {
            if i > 0 { try? await Task.sleep(nanoseconds: 80_000_000) }   // a TUI redraws between keys
            let (code, text, mods) = Self.keyTable[n]!
            _ = store.remoteKey(id, keyCode: code, text: text, modifiers: mods, by: by(ctx))
        }
        sentAt[id] = store.reportSeq
        return (["session": id], "Pressed \(names.joined(separator: " ")) in \(handle(id)).")
    }

    private func wait(_ a: [String: Any], _ ctx: Context) async throws -> ([String: Any], String) {
        let id = try resolve(a["session"], ctx)
        if id == ctx.caller { throw Failure(message: "a session cannot wait for itself") }
        guard let kind = store.session(id)?.kind, kind != .shell else { throw Failure(message: "wait follows Claude / Codex turns; for a shell use `seperate read`") }
        guard store.terminals[id] != nil else { throw Failure(message: "\(handle(id)) is not running here") }
        let onlyDone = (a["until"] as? String) == "done"
        let timeout = min(max(a["timeout"] as? Double ?? 110, 1), 3600)
        let since = (a["since"] as? Int) ?? sentAt[id] ?? store.reportSeq
        let h = handle(id)

        func check() -> ([String: Any], String)? {
            guard store.terminals[id] != nil else { return (["session": id, "state": "closed"], "\(h) was closed.") }
            let exited = store.hasExited(id)
            for r in store.reports[id] ?? [] where r.seq > since {
                let st = Self.reportState(r, exited: exited)
                if st == "working" || st == "idle" || (onlyDone && st == "needs-input") { continue }
                sentAt[id] = r.seq
                var d: [String: Any] = ["session": id, "state": st, "seq": r.seq]
                let msg = Self.message(r.phase)
                if let msg { d["message"] = msg }
                if st == "needs-input" { d["need"] = Self.needName(r.need) }
                let head = st == "needs-input" ? "\(h) needs input (\(Self.needName(r.need) ?? "permission"))" : "\(h) \(st)"
                let tail = st == "needs-input" ? "\nAnswer with `seperate send \(h) \"…\"` or `seperate key \(h) …`; `seperate read \(h)` shows the screen." : ""
                return (d, head + (msg.map { ":\n\($0)" } ?? ".") + tail)
            }
            return nil
        }
        if let r = check() { return r }
        return await withCheckedContinuation { cont in
            final class Once { var token: UUID?; var done = false }
            let once = Once()
            let finish: ([String: Any], String) -> Void = { [store] data, text in
                guard !once.done else { return }
                once.done = true
                if let t = once.token { store.unobserve(t) }
                cont.resume(returning: (data, text))
            }
            once.token = store.observe { _ in if let r = check() { finish(r.0, r.1) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                finish(["session": id, "state": self.state(id), "timedOut": true],
                       "Still \(self.state(id)) after \(Int(timeout)) s. Run `seperate wait \(h)` again to keep waiting.")
            }
        }
    }

    private func close(_ a: [String: Any], _ ctx: Context) throws -> ([String: Any], String) {
        let id = try resolve(a["session"], ctx)
        if id == ctx.caller, a["force"] as? Bool != true { throw Failure(message: "that is your own session; pass --force to close it anyway") }
        guard store.terminals[id] != nil || store.workspaceContaining(id) != nil else { return (["session": id], "\(handle(id)) was not open.") }
        let resumable = store.session(id)?.agentSessionID != nil
        store.endSession(id)
        return (["session": id], "Closed \(handle(id))." + (resumable ? " Its conversation stays in the sidebar and can be reopened." : ""))
    }

    private static func real(_ p: String) -> String {
        guard let r = realpath((p as NSString).expandingTildeInPath, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }
}
