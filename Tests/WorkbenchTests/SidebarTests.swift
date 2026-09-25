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
}
