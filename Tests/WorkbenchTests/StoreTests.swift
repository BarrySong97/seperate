import XCTest
@testable import Workbench

/// Every test that builds a Store gets its own data folder, so the real seperate.db is never touched.
func useTempDataDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seperate-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    setenv("SEPERATE_DATA_DIR", dir.path, 1)
    return dir
}

final class StoreTests: XCTestCase {
    private var dir: URL!
    override func setUp() { dir = useTempDataDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// Plain folders: no git needed, each is its own project.
    private func folders(_ n: Int) -> [String] {
        (0..<n).map { i in
            let p = dir.appendingPathComponent("p\(i)").path
            try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
            return p
        }
    }

    @MainActor func testImportsLegacyJSONOnceAndKeepsBackup() throws {
        let layout = String(data: try JSONEncoder().encode(LayoutModel()), encoding: .utf8)!
        let legacy = """
        {"workspaces":[{"id":"w1","name":"默认","icon":"默","tint":9414586,"projectRoots":["/a","/b"],
          "layout":\(layout)}],
         "activeID":"w1","aliases":{"/a/my_wt":"wt"},"showOlder":true,"sidebarHidden":false,"created":[]}
        """
        try legacy.write(to: Store.legacyURL, atomically: true, encoding: .utf8)
        let s = Store()
        XCTAssertEqual(s.workspaces.map(\.id), ["w1"])
        XCTAssertEqual(s.active.projectRoots, ["/a", "/b"])
        XCTAssertEqual(s.aliases["/a/my_wt"], "wt", "paths with underscores survive the round trip")
        XCTAssertTrue(s.showOlder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Store.legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: Store.legacyURL.path + ".bak"))
        XCTAssertEqual(Store().active.projectRoots, ["/a", "/b"], "the second launch reads the database")
    }

    @MainActor func testAProjectLivesInOneWorkspace() {
        let s = Store()
        let (a, b) = { let f = folders(2); return (f[0], f[1]) }()
        s.addProject(path: a); s.addProject(path: b)
        let first = s.activeID
        s.addWorkspace(name: "个人")
        s.addProject(path: a)                       // adding it here moves it
        XCTAssertEqual(s.active.projectRoots, [a])
        XCTAssertEqual(s.workspaces.first { $0.id == first }?.projectRoots, [b])
        s.moveProject(s.project(a)!, to: first)
        XCTAssertEqual(s.active.projectRoots, [])
        XCTAssertEqual(s.workspaces.first { $0.id == first }?.projectRoots, [a, b])
    }

    @MainActor func testCreatingAProjectAddsItAndOpensAShell() throws {
        let s = Store()
        try s.createProject(name: "fresh", in: dir.path, git: false)
        let root = dir.appendingPathComponent("fresh").path
        XCTAssertEqual(s.active.projectRoots, [root])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/README.md"))
        XCTAssertEqual(s.layout.focusedPane?.active.flatMap(s.session)?.cwd, root, "a terminal opens in the new project")
        XCTAssertThrowsError(try s.createProject(name: "fresh", in: dir.path, git: false), "an existing non-empty folder is refused")

        try s.createProject(name: "repo", in: dir.path, git: true)
        XCTAssertEqual(s.project(Core.repoInfo(dir.appendingPathComponent("repo").path)?.root ?? "")?.isGit, true)
    }

    @MainActor func testOrderColorAndPinsPersist() {
        let s = Store()
        let f = folders(3)
        f.forEach { s.addProject(path: $0) }        // each new one goes on top: [2, 1, 0]
        s.reorderProject(f[0], to: 0)
        XCTAssertEqual(s.visibleProjects.map(\.id), [f[0], f[2], f[1]])
        s.reorderProject(f[0], to: 3)               // insertion point after the last
        XCTAssertEqual(s.visibleProjects.map(\.id), [f[2], f[1], f[0]])

        s.addWorkspace(name: "个人"); s.addWorkspace(name: "工作")
        XCTAssertEqual(Set(s.workspaces.map(\.tint)).count, 3, "new workspaces get unused preset colors")
        let last = s.workspaces[2].id
        s.reorderWorkspace(last, to: 0)
        XCTAssertEqual(s.workspaces.first?.id, last)
        s.setColor(last, 0x123456)
        s.saveNow()

        let t = Store()
        XCTAssertEqual(t.workspaces.map(\.id), s.workspaces.map(\.id))
        XCTAssertEqual(t.workspaces.first?.tint, 0x123456)
        let home = t.workspaces.first { $0.projectRoots.count == 3 }
        XCTAssertEqual(home?.projectRoots, [f[2], f[1], f[0]])
    }

    /// A pinned conversation the scan has not found yet (or not this launch) must keep its pin through saves.
    @MainActor func testPinSurvivesSavesBeforeTheScan() throws {
        _ = Store()   // creates the database
        var state = try XCTUnwrap(Core.dbLoad())
        state.sessions = [.init(id: "codex:abc", kind: "codex", agentSessionID: "abc", origin: "discovered", cwd: "/x",
                                title: "t", customTitle: nil, createdAt: 1, lastActivityAt: 1, pinned: true)]
        XCTAssertNil(Core.dbSave(state))
        let s = Store()
        XCTAssertTrue(s.isPinned("codex:abc"))
        s.saveNow()
        XCTAssertTrue(Store().isPinned("codex:abc"))
        s.togglePin("codex:abc"); s.saveNow()
        XCTAssertFalse(Store().isPinned("codex:abc"))
    }

    @MainActor func testWorktreeOrderPersists() throws {
        let repo = dir.appendingPathComponent("repo").path
        func git(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 { throw XCTSkip("git unavailable") }
        }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git("init", "-q"); try git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init")
        let a = dir.appendingPathComponent("wt-a").path, b = dir.appendingPathComponent("wt-b").path
        try Core.worktreeAdd(root: repo, dir: a); try Core.worktreeAdd(root: repo, dir: b)
        // git reports resolved paths (/private/var/…), like the store does.
        func resolved(_ p: String) -> String {
            guard let r = realpath(p, nil) else { return p }
            defer { free(r) }
            return String(cString: r)
        }
        let (ra, rb) = (resolved(a), resolved(b))

        let s = Store()
        s.addProject(path: repo)
        let p = try XCTUnwrap(s.project(s.active.projectRoots[0]))
        let names = { (st: Store) in st.worktrees(of: p).map { ($0.path as NSString).lastPathComponent } }
        XCTAssertEqual(names(s).count, 3)
        s.reorderWorktree(rb, before: s.worktrees(of: p)[0].path)
        XCTAssertEqual(names(s).first, "wt-b")
        s.reorderWorktree(rb, before: nil)
        XCTAssertEqual(names(s).last, "wt-b")
        s.reorderWorktree(ra, before: s.worktrees(of: p)[0].path)
        let expected = names(s)
        s.saveNow()
        XCTAssertEqual(names(Store()), expected, "order survives a restart")
    }

    @MainActor func testRemovingAProjectTakesItOutEverywhereAndCanComeBack() throws {
        let s = Store()
        let f = folders(2)
        f.forEach { s.addProject(path: $0) }
        let p = try XCTUnwrap(s.project(f[0]))
        s.removeProject(p)
        XCTAssertFalse(s.workspaces.contains { $0.projectRoots.contains(f[0]) })
        XCTAssertNil(s.project(f[0]))
        XCTAssertEqual(s.active.projectRoots, [f[1]])
        s.saveNow()
        XCTAssertEqual(Store().active.projectRoots, [f[1]], "stays removed after a restart")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f[0]), "the folder itself is untouched")
        s.addProject(path: f[0])
        XCTAssertEqual(s.active.projectRoots, [f[0], f[1]])
    }

    /// A real repo with one commit on main (skips when git is unavailable).
    private func repo(_ name: String) throws -> String {
        let r = dir.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: r, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", r] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 { throw XCTSkip("git unavailable") }
        }
        guard let real = realpath(r, nil) else { return r }
        defer { free(real) }
        return String(cString: real)
    }

    @MainActor func testHiddenWorktreeStaysHiddenAcrossRefreshAndRestart() throws {
        let root = try repo("hide")
        let s = Store()
        s.addProject(path: root)
        let p = try XCTUnwrap(s.project(root))
        try s.createWorktree(in: p, name: "测试", base: "main", branch: "wt/测试")
        let wt = try XCTUnwrap(s.worktrees(of: p).first { !$0.isMain })
        XCTAssertEqual(wt.alias, "测试")
        XCTAssertTrue(wt.path.hasSuffix("hide.worktrees/测试"), "new worktrees go to <repo>.worktrees/")

        s.hideWorktree(try XCTUnwrap(s.worktrees(of: p).first { $0.isMain }))
        XCTAssertEqual(s.worktrees(of: p).count, 2, "the main worktree cannot be hidden")

        s.hideWorktree(wt)
        XCTAssertEqual(s.worktrees(of: p).map(\.isMain), [true])
        s.refreshProjects()
        XCTAssertEqual(s.worktrees(of: p).count, 1, "a refresh that finds it in git must not bring it back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path), "hiding leaves the folder alone")
        s.saveNow()
        let t = Store()
        XCTAssertEqual(t.worktrees(of: p).count, 1, "still hidden after a restart")
        XCTAssertEqual(t.hiddenWorktrees(of: p).map(\.path), [wt.path])
        t.unhideWorktree(wt.path)
        XCTAssertEqual(t.worktrees(of: p).count, 2)
    }

    @MainActor func testDeletingAWorktreeFromDisk() throws {
        let root = try repo("del")
        let s = Store()
        s.addProject(path: root)
        let p = try XCTUnwrap(s.project(root))
        try s.createWorktree(in: p, name: "a", base: "main", branch: "wt/a")
        let wt = try XCTUnwrap(s.worktrees(of: p).first { !$0.isMain })
        try "x".write(toFile: wt.path + "/new.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(Core.worktreeStatus(wt.path).dirty, 1)
        XCTAssertThrowsError(try s.deleteWorktree(wt, force: false, deleteBranch: nil), "uncommitted work blocks a plain delete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path))

        let kept = try s.deleteWorktree(wt, force: true, deleteBranch: "wt/a")
        XCTAssertNil(kept, "a branch with nothing new is merged, so it goes too")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path))
        XCTAssertEqual(s.worktrees(of: p).count, 1)
        XCTAssertFalse(Core.listBranches(root: root).local.contains { $0.name == "wt/a" })
    }
}
