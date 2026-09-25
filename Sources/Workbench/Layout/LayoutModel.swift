import Foundation

/// The window's pane layout: a split tree whose leaves are panes, each holding tabs of sessions.
/// Panes are not tied to a project or worktree — any session can sit in any pane.
struct Pane: Codable, Equatable, Identifiable {
    var id: String
    var tabs: [String] = []      // AgentSession ids
    var active: String?
}

indirect enum LayoutNode: Codable, Equatable {
    case pane(Pane)
    case split(id: String, axis: Axis, sizes: [Double], children: [LayoutNode])

    enum Axis: String, Codable { case horizontal, vertical }   // horizontal = side by side
}

enum DropEdge { case left, right, top, bottom }

enum LayoutPreset: String, CaseIterable, Codable {
    case one = "1", two = "2", three = "3", four = "4", grid = "2x2"
    var paneCount: Int { self == .grid ? 4 : Int(rawValue)! }
}

struct LayoutModel: Codable, Equatable {
    var root: LayoutNode
    var focusedPaneID: String
    var preset: LayoutPreset?

    init() {
        let p = Pane(id: LayoutModel.newID("p"))
        root = .pane(p)
        focusedPaneID = p.id
        preset = .one
    }

    static func newID(_ prefix: String) -> String { prefix + "-" + UUID().uuidString.prefix(8).lowercased() }

    // MARK: Queries

    var panes: [Pane] { LayoutModel.leaves(root) }
    var focusedPane: Pane? { panes.first { $0.id == focusedPaneID } }
    func pane(containing sessionID: String) -> Pane? { panes.first { $0.tabs.contains(sessionID) } }
    func paneNumber(_ paneID: String) -> Int? { panes.firstIndex { $0.id == paneID }.map { $0 + 1 } }
    var openSessionIDs: [String] { panes.flatMap(\.tabs) }

    static func leaves(_ n: LayoutNode) -> [Pane] {
        switch n {
        case .pane(let p): [p]
        case .split(_, _, _, let kids): kids.flatMap(leaves)
        }
    }

    // MARK: Tab operations

    /// Opens a session: focus it if already visible, else add as a tab to the focused pane.
    mutating func open(_ sid: String) {
        if let p = pane(containing: sid) {
            updatePane(p.id) { $0.active = sid }
            focusedPaneID = p.id
            return
        }
        addTab(sid, to: focusedPaneID)
    }

    mutating func addTab(_ sid: String, to paneID: String) {
        detach(sid)
        updatePane(paneID) { p in
            if !p.tabs.contains(sid) { p.tabs.append(sid) }
            p.active = sid
        }
        focusedPaneID = paneID
    }

    /// Removes a tab from whichever pane holds it. Returns that pane's id.
    @discardableResult
    mutating func detach(_ sid: String) -> String? {
        guard let p = pane(containing: sid) else { return nil }
        updatePane(p.id) { p in
            guard let i = p.tabs.firstIndex(of: sid) else { return }
            p.tabs.remove(at: i)
            if p.active == sid { p.active = p.tabs.isEmpty ? nil : p.tabs[max(0, i - 1)] }
        }
        return p.id
    }

    mutating func activate(_ sid: String, in paneID: String) {
        updatePane(paneID) { $0.active = sid }
        focusedPaneID = paneID
    }

    /// Moves a tab next to / into another pane. `edge == nil` means "into" as a tab.
    /// A pane emptied by dragging its last tab away is closed.
    mutating func move(_ sid: String, to paneID: String, edge: DropEdge?) {
        let source = pane(containing: sid)
        if let edge {
            if source?.id == paneID, source?.tabs.count == 1 { return }
            detach(sid)
            split(paneID, edge: edge, with: sid)
        } else {
            if source?.id == paneID { activate(sid, in: paneID); return }
            addTab(sid, to: paneID)
        }
        if let source, source.id != paneID, self.panes.first(where: { $0.id == source.id })?.tabs.isEmpty == true {
            closePane(source.id)
        }
    }

    // MARK: Split operations

    /// Splits `paneID`, placing a new pane (optionally holding `sid`) on the given edge.
    @discardableResult
    mutating func split(_ paneID: String, edge: DropEdge, with sid: String? = nil) -> String {
        let new = Pane(id: LayoutModel.newID("p"), tabs: sid.map { [$0] } ?? [], active: sid)
        let axis: LayoutNode.Axis = (edge == .left || edge == .right) ? .horizontal : .vertical
        let before = edge == .left || edge == .top
        root = LayoutModel.insert(new, beside: paneID, axis: axis, before: before, in: root)
        focusedPaneID = new.id
        preset = nil
        return new.id
    }

    /// Moves a whole pane. `edge == nil` swaps it with the target; an edge re-docks it beside the target.
    mutating func movePane(_ id: String, to target: String, edge: DropEdge?) {
        guard id != target, let moving = panes.first(where: { $0.id == id }),
              let dest = panes.first(where: { $0.id == target }) else { return }
        if let edge {
            guard let removed = LayoutModel.remove(id, from: root) else { return }
            let axis: LayoutNode.Axis = (edge == .left || edge == .right) ? .horizontal : .vertical
            root = LayoutModel.normalize(LayoutModel.insert(moving, beside: target, axis: axis,
                                                            before: edge == .left || edge == .top,
                                                            in: LayoutModel.normalize(removed)))
        } else {
            root = LayoutModel.map(root) { node in
                guard case .pane(let p) = node else { return node }
                if p.id == id { return .pane(dest) }
                if p.id == target { return .pane(moving) }
                return node
            }
        }
        focusedPaneID = id
        preset = nil
    }

    mutating func closePane(_ paneID: String) {
        guard panes.count > 1 else { return }
        root = LayoutModel.normalize(LayoutModel.remove(paneID, from: root) ?? root)
        if !panes.contains(where: { $0.id == focusedPaneID }) { focusedPaneID = panes[0].id }
        preset = nil
    }

    mutating func setSizes(splitID: String, _ sizes: [Double]) {
        root = LayoutModel.map(root) { node in
            if case .split(let id, let axis, _, let kids) = node, id == splitID {
                return .split(id: id, axis: axis, sizes: sizes, children: kids)
            }
            return node
        }
        preset = nil
    }

    /// Rebuilds the tree as a preset, keeping each pane's tab group; extra groups merge into the last pane.
    mutating func apply(_ preset: LayoutPreset, fillWith spare: [String] = []) {
        let n = preset.paneCount
        var groups = panes.filter { !$0.tabs.isEmpty }
        if groups.count > n {
            let overflow = groups[n...].flatMap(\.tabs)
            groups = Array(groups[..<n])
            groups[n - 1].tabs += overflow
        }
        var spareIDs = spare.filter { !openSessionIDs.contains($0) }.makeIterator()
        while groups.count < n {
            let sid = spareIDs.next()
            groups.append(Pane(id: "", tabs: sid.map { [$0] } ?? [], active: sid))
        }
        let newPanes = groups.map { g in
            Pane(id: LayoutModel.newID("p"), tabs: g.tabs, active: g.active.flatMap { g.tabs.contains($0) ? $0 : nil } ?? g.tabs.first)
        }
        let focusIndex = min(panes.firstIndex { $0.id == focusedPaneID } ?? 0, n - 1)
        switch preset {
        case .one:
            root = .pane(newPanes[0])
        case .grid:
            let top = LayoutNode.split(id: LayoutModel.newID("s"), axis: .horizontal, sizes: [1, 1], children: [.pane(newPanes[0]), .pane(newPanes[1])])
            let bottom = LayoutNode.split(id: LayoutModel.newID("s"), axis: .horizontal, sizes: [1, 1], children: [.pane(newPanes[2]), .pane(newPanes[3])])
            root = .split(id: LayoutModel.newID("s"), axis: .vertical, sizes: [1, 1], children: [top, bottom])
        default:
            root = .split(id: LayoutModel.newID("s"), axis: .horizontal, sizes: Array(repeating: 1, count: n), children: newPanes.map { .pane($0) })
        }
        focusedPaneID = newPanes[focusIndex].id
        self.preset = preset
    }

    /// Drops ids of sessions that no longer exist.
    mutating func prune(keeping valid: Set<String>) {
        for p in panes {
            updatePane(p.id) { p in
                p.tabs.removeAll { !valid.contains($0) }
                if let a = p.active, !valid.contains(a) { p.active = p.tabs.first }
            }
        }
    }

    // MARK: Tree helpers

    mutating func updatePane(_ id: String, _ body: (inout Pane) -> Void) {
        root = LayoutModel.map(root) { node in
            if case .pane(var p) = node, p.id == id { body(&p); return .pane(p) }
            return node
        }
    }

    static func map(_ n: LayoutNode, _ f: (LayoutNode) -> LayoutNode) -> LayoutNode {
        switch n {
        case .pane: return f(n)
        case .split(let id, let axis, let sizes, let kids):
            return f(.split(id: id, axis: axis, sizes: sizes, children: kids.map { map($0, f) }))
        }
    }

    static func insert(_ new: Pane, beside target: String, axis: LayoutNode.Axis, before: Bool, in n: LayoutNode) -> LayoutNode {
        switch n {
        case .pane(let p):
            guard p.id == target else { return n }
            let kids: [LayoutNode] = before ? [.pane(new), n] : [n, .pane(new)]
            return .split(id: newID("s"), axis: axis, sizes: [1, 1], children: kids)
        case .split(let id, let a, var sizes, var kids):
            // Same-axis parent: insert as a sibling instead of nesting.
            if a == axis, let i = kids.firstIndex(where: { if case .pane(let p) = $0 { return p.id == target }; return false }) {
                let half = sizes[i] / 2
                sizes[i] = half
                let at = before ? i : i + 1
                kids.insert(.pane(new), at: at)
                sizes.insert(half, at: at)
                return .split(id: id, axis: a, sizes: sizes, children: kids)
            }
            return .split(id: id, axis: a, sizes: sizes, children: kids.map { insert(new, beside: target, axis: axis, before: before, in: $0) })
        }
    }

    static func remove(_ paneID: String, from n: LayoutNode) -> LayoutNode? {
        switch n {
        case .pane(let p): return p.id == paneID ? nil : n
        case .split(let id, let axis, let sizes, let kids):
            var newKids: [LayoutNode] = [], newSizes: [Double] = []
            for (k, s) in zip(kids, sizes) {
                if let r = remove(paneID, from: k) { newKids.append(r); newSizes.append(s) }
            }
            if newKids.isEmpty { return nil }
            return .split(id: id, axis: axis, sizes: newSizes, children: newKids)
        }
    }

    /// Collapses single-child splits and flattens same-axis nesting.
    static func normalize(_ n: LayoutNode) -> LayoutNode {
        guard case .split(let id, let axis, let sizes, let kids) = n else { return n }
        var outKids: [LayoutNode] = [], outSizes: [Double] = []
        for (k, s) in zip(kids.map(normalize), sizes) {
            if case .split(_, let a2, let s2, let k2) = k, a2 == axis {
                let total = s2.reduce(0, +)
                for (kk, ss) in zip(k2, s2) { outKids.append(kk); outSizes.append(s * ss / total) }
            } else { outKids.append(k); outSizes.append(s) }
        }
        if outKids.count == 1 { return outKids[0] }
        return .split(id: id, axis: axis, sizes: outSizes, children: outKids)
    }
}
