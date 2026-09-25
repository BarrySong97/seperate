import XCTest
@testable import Workbench

final class LayoutModelTests: XCTestCase {
    func testOpenAddsTabToFocusedPaneAndRefocusesExisting() {
        var m = LayoutModel()
        m.open("a"); m.open("b")
        XCTAssertEqual(m.panes.count, 1)
        XCTAssertEqual(m.panes[0].tabs, ["a", "b"])
        XCTAssertEqual(m.panes[0].active, "b")
        m.open("a")
        XCTAssertEqual(m.panes[0].tabs, ["a", "b"], "re-opening must not duplicate")
        XCTAssertEqual(m.panes[0].active, "a")
    }

    func testSplitSameAxisInsertsSiblingInsteadOfNesting() {
        var m = LayoutModel()
        m.open("a")
        let first = m.focusedPaneID
        m.split(first, edge: .right, with: "b")
        m.split(m.focusedPaneID, edge: .right, with: "c")
        guard case .split(_, let axis, let sizes, let kids) = m.root else { return XCTFail("expected split") }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(kids.count, 3)
        XCTAssertEqual(sizes.reduce(0, +), 2, accuracy: 1e-9)
        XCTAssertEqual(m.panes.map(\.tabs), [["a"], ["b"], ["c"]])
    }

    func testMovingLastTabOutClosesSourcePane() {
        var m = LayoutModel()
        m.open("a")
        let left = m.focusedPaneID
        let right = m.split(left, edge: .right, with: "b")
        m.move("b", to: left, edge: nil)
        XCTAssertEqual(m.panes.count, 1)
        XCTAssertEqual(m.panes[0].tabs, ["a", "b"])
        XCTAssertNil(m.panes.first { $0.id == right })
    }

    func testMoveToEdgeSplitsTarget() {
        var m = LayoutModel()
        m.open("a"); m.open("b")
        let p = m.focusedPaneID
        m.move("b", to: p, edge: .bottom)
        guard case .split(_, let axis, _, _) = m.root else { return XCTFail("expected split") }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(m.panes.map(\.tabs), [["a"], ["b"]])
    }

    func testClosePaneCollapsesTree() {
        var m = LayoutModel()
        m.open("a")
        let p1 = m.focusedPaneID
        let p2 = m.split(p1, edge: .bottom, with: "b")
        m.split(p2, edge: .right, with: "c")
        m.closePane(p2)
        m.closePane(m.panes.last!.id)
        XCTAssertEqual(m.panes.count, 1)
        if case .split = m.root { XCTFail("single pane should not stay wrapped in a split") }
    }

    func testPresetKeepsTabGroupsAndMergesOverflow() {
        var m = LayoutModel()
        m.open("a")
        m.split(m.focusedPaneID, edge: .right, with: "b")
        m.split(m.focusedPaneID, edge: .right, with: "c")
        m.apply(.two)
        XCTAssertEqual(m.panes.map(\.tabs), [["a"], ["b", "c"]])
        m.apply(.grid, fillWith: ["a", "d", "e"])
        XCTAssertEqual(m.panes.map(\.tabs), [["a"], ["b", "c"], ["d"], ["e"]])
        XCTAssertEqual(m.preset, .grid)
    }

    func testMovePaneCenterSwaps() {
        var m = LayoutModel()
        m.open("a")
        let p1 = m.focusedPaneID
        m.split(p1, edge: .right, with: "b")
        let p3 = m.split(m.focusedPaneID, edge: .right, with: "c")
        m.movePane(p1, to: p3, edge: nil)
        XCTAssertEqual(m.panes.map(\.tabs), [["c"], ["b"], ["a"]])
        XCTAssertEqual(m.focusedPaneID, p1)
    }

    func testMovePaneToEdgeRedocksAndCollapsesTree() {
        var m = LayoutModel()
        m.open("a")
        let p1 = m.focusedPaneID
        let p2 = m.split(p1, edge: .right, with: "b")
        m.movePane(p2, to: p1, edge: .top)          // b goes above a: one vertical split
        guard case .split(_, let axis, _, let kids) = m.root else { return XCTFail("expected split") }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(kids.count, 2)
        XCTAssertEqual(m.panes.map(\.tabs), [["b"], ["a"]])
        m.movePane(p2, to: p2, edge: .left)          // onto itself: no-op
        XCTAssertEqual(m.panes.map(\.tabs), [["b"], ["a"]])
    }

    func testLayoutRoundTripsThroughJSON() throws {
        var m = LayoutModel()
        m.open("a")
        m.split(m.focusedPaneID, edge: .top, with: "b")
        let data = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(LayoutModel.self, from: data), m)
    }
}

final class PathTests: XCTestCase {
    func testPathInside() {
        XCTAssertTrue("/a/b/c".isPath(inside: "/a/b"))
        XCTAssertTrue("/a/b".isPath(inside: "/a/b/"))
        XCTAssertFalse("/a/bc".isPath(inside: "/a/b"))
    }
}
