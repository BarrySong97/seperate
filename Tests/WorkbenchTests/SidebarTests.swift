// @purpose Regression tests: sidebar collapse/expand state survives data reloads; rows that first appear
//          (a worktree gaining its first session from an outside agent) open expanded.
// @role    XCTest driving SidebarView's NSOutlineView over a real Store.
// @deps    XCTest, AppKit, Workbench (@testable), git (new-row test)
// @gotcha  Skips when the saved state has no project rows; AppKit autosaves expansion across runs.
//          docs/modules/ui/README.md
import XCTest
import AppKit
@testable import Workbench

/// Regression: the sidebar must collapse/expand via the outline view and keep that state across reloads.
final class SidebarTests: XCTestCase {
    @MainActor func testCollapseWorksAndSurvivesReload() throws {
        _ = useTempDataDir()
        let store = Store()
        let side = SidebarView(store: store)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 244, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = side
        side.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(side.subviews.compactMap { $0.subviews.compactMap { $0 as? NSScrollView }.first }.first?.documentView as? NSOutlineView)
        guard outline.numberOfRows > 1, let first = outline.item(atRow: 0) as? SidebarView.Item else { throw XCTSkip("needs at least one project with sessions in the saved state") }
        outline.expandItem(first, expandChildren: true)   // AppKit autosaves expansion across test runs; start from a known state
        let rowsBefore = outline.numberOfRows
        outline.collapseItem(first); side.noteExplicitCollapse(first)
        XCTAssertFalse(outline.isItemExpanded(first))
        XCTAssertLessThan(outline.numberOfRows, rowsBefore)
        store.toggleShowOlder(); store.toggleShowOlder()   // two data reloads
        XCTAssertFalse(outline.isItemExpanded(first), "collapse must survive a reload")
        outline.expandItem(first)
        XCTAssertEqual(outline.numberOfRows, rowsBefore, "re-expanding restores every row, worktree children included")
    }

    /// Regression: a session started outside Seperate in a worktree that had none used to land in a
    /// collapsed worktree row (and folded away the main worktree's sessions too), so it looked missing.
    @MainActor func testRowsThatAppearWithANewSessionOpenExpanded() throws {
        let dir = useTempDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = try repo(in: dir)
        let store = Store()
        store.addProject(path: root)
        let p = try XCTUnwrap(store.project(root))
        try store.createWorktree(in: p, name: "b", base: "main", branch: "wt/b")
        let main = try XCTUnwrap(store.worktrees(of: p).first { $0.isMain })
        let b = try XCTUnwrap(store.worktrees(of: p).first { !$0.isMain })
        let side = SidebarView(store: store)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 244, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = side
        side.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(side.subviews.compactMap { $0.subviews.compactMap { $0 as? NSScrollView }.first }.first?.documentView as? NSOutlineView)
        func shown(_ key: String) -> Bool {
            (0..<outline.numberOfRows).contains { (outline.item(atRow: $0) as? SidebarView.Item)?.key == key }
        }
        func session(_ id: String, in wt: Worktree) -> AgentSession {
            AgentSession(id: "claude:" + id, kind: .claude, agentSessionID: id, cwd: wt.path, title: id, lastActivity: Date())
        }
        var found = [session("m1", in: main)]
        store.applyScan(found, projects: store.projects, worktrees: store.worktrees)
        XCTAssertTrue(shown("s:claude:m1"))

        // The outside agent works in "b": the project now lists both worktrees, and both rows are new.
        found.append(session("b1", in: b))
        store.applyScan(found, projects: store.projects, worktrees: store.worktrees)
        XCTAssertTrue(shown("s:claude:b1"), "the new worktree row opens so its session is visible")
        XCTAssertTrue(shown("s:claude:m1"), "the main worktree's sessions stay visible after the regroup")

        // A row the user folded stays folded when more sessions arrive.
        let row = try XCTUnwrap(outline.item(atRow: (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarView.Item)?.key == "w:" + b.path }!) as? SidebarView.Item)
        outline.collapseItem(row); side.noteExplicitCollapse(row)
        found.append(session("b2", in: b))
        store.applyScan(found, projects: store.projects, worktrees: store.worktrees)
        XCTAssertFalse(shown("s:claude:b2"), "an explicit collapse is respected")
    }

    /// A real repo with one commit on main (skips when git is unavailable).
    private func repo(in dir: URL) throws -> String {
        let r = dir.appendingPathComponent("side").path
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
}
