import Foundation
import WorkbenchCore

/// Thin bridge to the Rust core (`core/`). Every call is synchronous and safe from any thread;
/// results are JSON strings owned by Rust.
enum Core {
    struct RepoInfo: Decodable {
        struct WorktreeEntry: Decodable { let path: String; let isMain: Bool }
        let root: String
        let worktrees: [WorktreeEntry]
    }

    private struct ScannedSession: Decodable {
        let id: String, kind: String, agentSessionId: String, cwd: String, title: String, lastActivity: UInt64
    }

    private struct AddResult: Decodable { let ok: Bool; let error: String }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static func call<T: Decodable>(_ ptr: UnsafeMutablePointer<CChar>?, as: T.Type) -> T? {
        guard let ptr else { return nil }
        defer { wb_free(ptr) }
        return try? decoder.decode(T.self, from: Data(bytes: ptr, count: strlen(ptr)))
    }

    // MARK: App database (SQLite, owned by the core)

    /// Mirrors `db::State` in core/src/db.rs. Explicit keys and a plain coder: a snake_case key strategy
    /// would also rewrite dictionary keys, and those are file paths.
    struct DBState: Codable {
        struct WorkspaceRow: Codable { var id, name, icon, color, layout: String; var projects: [String] }
        struct SessionRow: Codable {
            var id, kind: String
            var agentSessionID: String?
            var origin, cwd, title: String
            var customTitle: String?
            var createdAt, lastActivityAt: Int64
            var pinned: Bool
            enum CodingKeys: String, CodingKey {
                case id, kind, origin, cwd, title, pinned
                case agentSessionID = "agent_session_id", customTitle = "custom_title"
                case createdAt = "created_at", lastActivityAt = "last_activity_at"
            }
        }
        var activeID: String
        var workspaces: [WorkspaceRow]
        var aliases: [String: String]
        var worktreeOrder: [String: [String]] = [:]     // project root → worktree paths
        struct HiddenRow: Codable {
            var path, projectRoot: String
            var hiddenAt: Int64
            enum CodingKeys: String, CodingKey { case path, projectRoot = "project_root", hiddenAt = "hidden_at" }
        }
        var hiddenWorktrees: [HiddenRow] = []
        var settings: [String: String]
        var sessions: [SessionRow]
        enum CodingKeys: String, CodingKey {
            case activeID = "active_id", workspaces, aliases, worktreeOrder = "worktree_order",
                 hiddenWorktrees = "hidden_worktrees", settings, sessions
        }
    }

    /// Opens (creating/migrating) the database; returns an error message on failure.
    static func dbOpen(_ path: String) -> String? {
        let r = call(wb_db_open(path), as: AddResult.self)
        return r?.ok == true ? nil : (r?.error ?? "无法打开数据库")
    }

    static func dbLoad() -> DBState? {
        guard let ptr = wb_db_load() else { return nil }
        defer { wb_free(ptr) }
        return try? JSONDecoder().decode(DBState.self, from: Data(bytes: ptr, count: strlen(ptr)))
    }

    /// Saves the whole state in one transaction; returns an error message on failure.
    static func dbSave(_ state: DBState) -> String? {
        guard let data = try? JSONEncoder().encode(state), let json = String(data: data, encoding: .utf8) else { return "编码失败" }
        let r = call(wb_db_save(json), as: AddResult.self)
        return r?.ok == true ? nil : (r?.error ?? "保存失败")
    }

    /// Repository containing `path` (its main worktree plus linked worktrees); nil for a plain folder.
    static func repoInfo(_ path: String) -> RepoInfo? {
        call(wb_repo_info(path), as: RepoInfo.self)
    }

    static func worktreeAdd(root: String, dir: String) throws {
        let r = call(wb_worktree_add(root, dir), as: AddResult.self)
        if r?.ok != true {
            throw NSError(domain: "Workbench", code: 1, userInfo: [NSLocalizedDescriptionKey: r?.error ?? "git worktree add 失败"])
        }
    }

    /// The project's own favicon / app icon, if it has one.
    static func projectIcon(_ root: String) -> String? {
        guard let p = wb_project_icon(root) else { return nil }
        defer { wb_free(p) }
        return String(cString: p)
    }

    struct PinyinKeys: Decodable { let initials: String; let full: String; let owner: [Int] }

    /// Pinyin search keys for a title (cached; titles repeat on every keystroke).
    static func pinyinKeys(_ text: String) -> PinyinKeys? {
        pinyinLock.lock(); defer { pinyinLock.unlock() }
        if let k = pinyinCache[text] { return k }
        let k = call(wb_pinyin_keys(text), as: PinyinKeys.self)
        pinyinCache[text] = k
        return k
    }
    nonisolated(unsafe) private static var pinyinCache: [String: PinyinKeys?] = [:]
    private static let pinyinLock = NSLock()

    // MARK: Worktree operations (git, run by the core)

    struct WorktreeStatus: Decodable {
        let missing: Bool, dirty: Int, changed: [String], branch: String?, ahead: Int?
    }
    struct Branch: Decodable, Hashable { let name: String; let updated: Int }
    struct Branches: Decodable { let local: [Branch]; let remote: [Branch] }

    private static func check(_ ptr: UnsafeMutablePointer<CChar>?, fallback: String) throws {
        let r = call(ptr, as: AddResult.self)
        if r?.ok != true {
            throw NSError(domain: "Seperate", code: 1, userInfo: [NSLocalizedDescriptionKey: r?.error.isEmpty == false ? r!.error : fallback])
        }
    }

    static func worktreeStatus(_ path: String) -> WorktreeStatus {
        call(wb_worktree_status(path), as: WorktreeStatus.self) ?? WorktreeStatus(missing: true, dirty: 0, changed: [], branch: nil, ahead: nil)
    }

    static func worktreeRemove(root: String, path: String, force: Bool) throws {
        try check(wb_worktree_remove(root, path, force ? 1 : 0), fallback: "git worktree remove 失败")
    }

    /// `git branch -d`: nil when deleted, else why it was kept (usually "not fully merged").
    static func branchDelete(root: String, branch: String) -> String? {
        let r = call(wb_branch_delete(root, branch), as: AddResult.self)
        return r?.ok == true ? nil : (r?.error ?? "删除分支失败")
    }

    static func listBranches(root: String) -> Branches {
        call(wb_list_branches(root), as: Branches.self) ?? Branches(local: [], remote: [])
    }

    static func worktreeAdd(root: String, dir: String, branch: String?, base: String) throws {
        try check(wb_worktree_add_from(root, dir, branch, base), fallback: "git worktree add 失败")
    }

    /// A new project folder with a README; `git` also makes it a repo on `main` with a first commit.
    static func projectCreate(dir: String, git: Bool) throws {
        try check(wb_project_create(dir, git ? 1 : 0), fallback: "新建项目失败")
    }

    /// A folder the user's agents worked in, folded into its Git repo (see core/src/agents.rs).
    struct AgentProject: Decodable, Hashable {
        let root: String, name: String, codex: Int, claude: Int, lastUsed: Int, git: Bool, scratch: Bool
    }

    /// Projects Codex / Claude have been used in, matching `query` (name, pinyin, path), best first.
    static func agentProjects(query: String = "") -> [AgentProject] {
        call(wb_agent_projects(NSHomeDirectory(), query), as: [AgentProject].self) ?? []
    }

    /// Every Codex + Claude conversation, whatever its age (~100 ms for ~800).
    static func scanSessions() -> [AgentSession] {
        (call(wb_scan_sessions(NSHomeDirectory(), 0), as: [ScannedSession].self) ?? []).map {
            AgentSession(id: $0.id, kind: AgentKind(rawValue: $0.kind) ?? .shell, agentSessionID: $0.agentSessionId,
                         cwd: $0.cwd, title: $0.title, lastActivity: Date(timeIntervalSince1970: TimeInterval($0.lastActivity)))
        }
    }
}
