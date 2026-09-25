import Foundation

/// What the command palette can find, and how results are grouped and ranked. No UI here.
enum PaletteScope: Equatable {
    case all                          // ⌘K: sessions of every added project (all workspaces), workspaces, create & commands
    case worktree(String)             // "显示全部": only that worktree's sessions
}

struct PaletteEntry {
    enum Kind {
        case session(String)                    // session id
        case create(AgentKind, Worktree)        // start Codex / Claude / a shell in a worktree
        case workspace(String)                  // switch to workspace id
        case command(String, () -> Void)        // label id, action
    }
    enum Section: Int, CaseIterable {
        case sessions, workspaces, create, commands
        var title: String { ["会话", "Workspace", "新建", "命令"][rawValue] }
    }

    var kind: Kind
    var section: Section
    var title: String
    var context: String = ""          // "项目 / Worktree", shown faint on the right of the title
    var keys: [String] = []           // extra searchable words: project, worktree, agent type
    var running = false
    var local = true                  // belongs to the active workspace; ranked first
    var recency: Date = .distantPast
    var symbol: String? = nil         // SF Symbol for non-session rows
    var agent: AgentKind? = nil
    var status: SessionStatus = .history
    var openHint: String? = nil       // "已打开" / "在「个人」"
    var pinyin: Core.PinyinKeys? = nil
}

struct PaletteResult {
    let entry: PaletteEntry
    let highlights: [Range<Int>]
}

enum PaletteSearch {
    /// Groups in section order; within a group: score, then active workspace first, then running, then most recent.
    /// An empty query shows everything except the (long) "create" list.
    static func rank(_ entries: [PaletteEntry], query: String) -> [(PaletteEntry.Section, [PaletteResult])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var scored: [(PaletteResult, Int)] = []
        for e in entries {
            if q.isEmpty {
                if e.section == .create { continue }
                scored.append((PaletteResult(entry: e, highlights: []), 0))
                continue
            }
            var best = Fuzzy.matchTitle(q, e.title, keys: e.pinyin).map { ($0.score + 4, $0.ranges) }
            for k in e.keys {
                if let m = Fuzzy.match(q, in: k), m.score > (best?.0 ?? .min) { best = (m.score, []) }
            }
            if let (score, ranges) = best { scored.append((PaletteResult(entry: e, highlights: ranges), score)) }
        }
        let grouped = Dictionary(grouping: scored, by: { $0.0.entry.section })
        return PaletteEntry.Section.allCases.compactMap { section in
            guard let items = grouped[section], !items.isEmpty else { return nil }
            let sorted = items.sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                // Needs you, then unread results, then working, ahead of everything else.
                if a.0.entry.status.urgency != b.0.entry.status.urgency, max(a.0.entry.status.urgency, b.0.entry.status.urgency) >= SessionStatus.working.urgency {
                    return a.0.entry.status.urgency > b.0.entry.status.urgency
                }
                if a.0.entry.local != b.0.entry.local { return a.0.entry.local }
                if a.0.entry.running != b.0.entry.running { return a.0.entry.running }
                return a.0.entry.recency > b.0.entry.recency
            }
            return (section, sorted.map(\.0))
        }
    }
}
