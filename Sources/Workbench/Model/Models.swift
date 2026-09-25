import Foundation

/// A repository (or plain folder) the user works in. Worktrees hang off it.
struct Project: Codable, Identifiable, Hashable {
    var id: String            // stable: the main worktree path
    var name: String
    var rootPath: String      // main worktree (or plain folder) path
    var isGit: Bool
    var iconPath: String? = nil   // favicon / app icon found in the repo
}

/// A long-lived working directory of a project. Deliberately has no branch:
/// agents work against a directory, and which branch is checked out is the user's business.
struct Worktree: Codable, Identifiable, Hashable {
    var id: String { path }
    var projectID: String
    var path: String
    var alias: String
    var isMain: Bool
}

enum AgentKind: String, Codable, CaseIterable {
    case codex, claude, shell

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .shell: "终端"
        }
    }
}

enum SessionStatus: String, Codable {
    case running    // a live terminal in this app, nothing to report
    case working    // the agent is generating or running tools
    case done       // the agent finished a turn the user has not looked at yet
    case failed     // the agent exited with an error the user has not looked at yet
    case waiting    // needs the user: a permission / approval request, or a bell from a plain terminal
    case history    // discovered on disk, not running here

    /// For showing the most pressing state of a group.
    var urgency: Int { [.history: 0, .running: 1, .working: 2, .done: 3, .failed: 4, .waiting: 5][self] ?? 0 }
}

/// What a running agent is doing, from its hooks. No entry means idle at its prompt.
enum AgentPhase: Equatable {
    case working
    case needsInput(String?)   // the agent's question, e.g. "Claude needs your permission to use Bash"
    case done(String?)         // finished a turn, unread; its last message
    case failed(Int)           // the agent exited with this code, unread
}

/// What a session waiting for the user wants from them.
enum NeedKind { case permission, question, plan, bell }

/// One row of the inbox.
struct InboxItem: Identifiable {
    enum Group: Int { case needs, review, working }
    enum Label { case permission, question, plan, bell, done, failed, working }
    let id: String
    let agent: AgentKind
    let title: String
    let place: String          // "project / worktree", plus the workspace when it is another one
    let message: String
    let label: Label
    let group: Group
    let since: Date
}

/// One agent conversation or shell. Discovered ones come from ~/.codex / ~/.claude;
/// created ones are started by the app and get an agent session id once the CLI writes one.
struct AgentSession: Codable, Identifiable, Hashable {
    var id: String               // app-level id
    var kind: AgentKind
    var agentSessionID: String?  // codex/claude conversation id, used for resume
    var cwd: String
    var title: String
    var lastActivity: Date
    var status: SessionStatus = .history

    /// Command the terminal runs for this tab.
    var launchCommand: String? {
        switch kind {
        case .shell:
            return nil
        case .codex:
            if let sid = agentSessionID { return "codex resume \(sid)" }
            return "codex"
        case .claude:
            if let sid = agentSessionID { return "claude --resume \(sid)" }
            return "claude"
        }
    }
}

extension String {
    /// `~`-abbreviated path for display.
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }

    /// True when `self` is `dir` or lies inside it.
    func isPath(inside dir: String) -> Bool {
        let d = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        return self == d || hasPrefix(d + "/")
    }
}

/// A context: which projects you are looking at right now, and how their panes are arranged.
/// Sessions and terminals are global facts; a workspace is a view onto them.
struct Workspace: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var icon: String            // one character shown in the switcher
    var tint: UInt32            // hex color, tints the sidebar
    var projectRoots: [String]
    var layout: LayoutModel

    /// Preset colors, picked to stay readable on the dark ground; any other color can be chosen too.
    static let tints: [(color: UInt32, name: String)] = [
        (0x8FA7BA, "石板蓝"), (0x9CCF6C, "草绿"), (0xE8916C, "陶土"), (0xC9A36B, "赭石"),
        (0xB59AD6, "薰衣草"), (0x78C6DE, "湖蓝"), (0xE07A8F, "玫瑰"), (0xD6D3C3, "骨白"),
    ]

    /// The first preset no other workspace uses yet.
    static func nextTint(used: [UInt32]) -> UInt32 {
        tints.first { !used.contains($0.color) }?.color ?? tints[used.count % tints.count].color
    }

    static func make(name: String, tint: UInt32 = tints[0].color, projectRoots: [String] = [], layout: LayoutModel = LayoutModel()) -> Workspace {
        Workspace(id: UUID().uuidString, name: name, icon: String(name.prefix(1)), tint: tint,
                  projectRoots: projectRoots, layout: layout)
    }
}
