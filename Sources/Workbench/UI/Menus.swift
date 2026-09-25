import AppKit

/// Context and "+" menus, built only when opened.
@MainActor
enum Menus {
    static func kinds(_ store: Store, wt: Worktree, into menu: NSMenu, before: (() -> Void)? = nil) {
        for k in AgentKind.allCases {
            let item = ActionItem(k.displayName) { before?(); store.newSession(k, in: wt) }
            item.image = Icons.agent(k, size: 12)
            menu.addItem(item)
        }
    }

    /// Start Codex / Claude / a shell in any worktree of the active workspace's projects.
    static func newSession(_ store: Store, paneID: String? = nil) -> NSMenu {
        let m = NSMenu()
        for p in store.visibleProjects {
            let wts = store.worktrees(of: p)
            let sub = NSMenu()
            if wts.count > 1 {
                for wt in wts {
                    let h = NSMenuItem(title: wt.alias, action: nil, keyEquivalent: ""); h.isEnabled = false
                    sub.addItem(h)
                    kinds(store, wt: wt, into: sub) { if let paneID { store.focus(pane: paneID) } }
                    sub.addItem(.separator())
                }
            } else if let wt = wts.first {
                kinds(store, wt: wt, into: sub) { if let paneID { store.focus(pane: paneID) } }
            }
            let item = NSMenuItem(title: p.name, action: nil, keyEquivalent: "")
            item.submenu = sub
            m.addItem(item)
        }
        if store.visibleProjects.isEmpty {
            m.addItem(ActionItem("添加项目…") { store.pickProject() })
        }
        return m
    }

    static func project(_ store: Store, _ p: Project) -> NSMenu {
        let m = NSMenu()
        let wts = store.worktrees(of: p)
        for wt in wts {
            if wts.count > 1 {
                let h = NSMenuItem(title: wt.alias, action: nil, keyEquivalent: ""); h.isEnabled = false
                m.addItem(h)
            }
            kinds(store, wt: wt, into: m)
            if wts.count > 1 { m.addItem(.separator()) }
        }
        if wts.count <= 1 { m.addItem(.separator()) }
        if p.isGit { m.addItem(ActionItem("新建 Worktree…") { store.promptNewWorktree(in: p) }) }
        // Every worktree's own menu, including ones the sidebar does not list (no sessions yet).
        if wts.count > 1 {
            let manage = NSMenuItem(title: "管理 Worktree", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for wt in wts {
                let it = NSMenuItem(title: wt.alias + (wt.isMain ? "（主目录）" : ""), action: nil, keyEquivalent: "")
                it.submenu = worktree(store, wt)
                sub.addItem(it)
            }
            manage.submenu = sub
            m.addItem(manage)
        }
        if let hidden = WorktreeDialogs.hiddenMenu(store, p) { m.addItem(hidden) }
        m.addItem(ActionItem("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.rootPath)]) })
        m.addItem(.separator())
        let others = store.workspaces.filter { $0.id != store.activeID }
        let move = NSMenuItem(title: "移到 Workspace", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for w in others { sub.addItem(ActionItem(w.name) { store.moveProject(p, to: w.id) }) }
        move.submenu = sub
        move.isEnabled = !others.isEmpty
        m.addItem(move)
        if store.active.projectRoots.first != p.id { m.addItem(ActionItem("移到最上面") { store.reorderProject(p.id, to: 0) }) }
        m.addItem(.separator())
        m.addItem(ActionItem("从 Seperate 移除…") { store.promptRemoveProject(p) })
        return m
    }

    static func worktree(_ store: Store, _ wt: Worktree) -> NSMenu {
        let m = NSMenu()
        kinds(store, wt: wt, into: m)
        m.addItem(.separator())
        if let p = store.project(wt.projectID) {
            let paths = store.worktrees(of: p).map(\.path)
            if let i = paths.firstIndex(of: wt.path), paths.count > 1 {
                if i > 0 {
                    m.addItem(ActionItem("移到最上面") { store.reorderWorktree(wt.path, before: paths[0]) })
                    m.addItem(ActionItem("上移") { store.reorderWorktree(wt.path, before: paths[i - 1]) })
                }
                if i < paths.count - 1 { m.addItem(ActionItem("下移") { store.reorderWorktree(wt.path, before: i + 2 < paths.count ? paths[i + 2] : nil) }) }
                m.addItem(.separator())
            }
        }
        m.addItem(ActionItem("重命名…") { store.promptRename(wt) })
        m.addItem(.separator())
        openItems(store, path: wt.path, into: m)
        if !wt.isMain {
            m.addItem(.separator())
            m.addItem(ActionItem("从 Seperate 移除…") { WorktreeDialogs.confirmHide(store, wt) })
            let del = ActionItem("从磁盘删除…") { WorktreeDialogs.confirmDelete(store, wt) }
            del.attributedTitle = NSAttributedString(string: "从磁盘删除…", attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0)])
            m.addItem(del)
        }
        return m
    }

    /// Finder, the default editor, the other installed editors / terminals (with their icons), copy path.
    static func openItems(_ store: Store, path: String, into m: NSMenu) {
        let finder = ActionItem("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        finder.image = ExternalApp.finderIcon
        m.addItem(finder)
        let preferred = store.preferredEditor
        if let e = preferred {
            let it = ActionItem("用 \(e.name) 打开") { e.open(path) }
            it.image = e.icon()
            it.keyEquivalent = "o"; it.keyEquivalentModifierMask = [.command, .option]
            m.addItem(it)
        }
        let others = ExternalApp.installed.filter { $0 != preferred }
        if !others.isEmpty {
            let item = NSMenuItem(title: "用其他应用打开", action: nil, keyEquivalent: "")
            item.submenu = appsMenu(store, path: path, apps: others)
            m.addItem(item)
        }
        m.addItem(ActionItem("复制路径") { store.copyPath(path) })
    }

    /// Installed editors, then terminals, each with its icon; plus "set as default editor".
    static func appsMenu(_ store: Store, path: String, apps: [ExternalApp] = ExternalApp.installed) -> NSMenu {
        let m = NSMenu()
        let editors = apps.filter { !$0.isTerminal }, terms = apps.filter(\.isTerminal)
        for a in editors {
            let it = ActionItem(a.name) { a.open(path) }
            it.image = a.icon()
            if a == store.preferredEditor { it.title = a.name + "（默认）" }
            m.addItem(it)
        }
        if !editors.isEmpty && !terms.isEmpty { m.addItem(.separator()) }
        for a in terms {
            let it = ActionItem(a.name) { a.open(path) }
            it.image = a.icon()
            m.addItem(it)
        }
        let choices = ExternalApp.editors
        if choices.count > 1 {
            m.addItem(.separator())
            let def = NSMenuItem(title: "设为默认编辑器", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for a in choices {
                let it = ActionItem(a.name) { store.setDefaultEditor(a) }
                it.image = a.icon()
                it.state = a == store.preferredEditor ? .on : .off
                sub.addItem(it)
            }
            def.submenu = sub
            m.addItem(def)
        }
        return m
    }

    /// Right-click in a terminal: new sessions in this tab's worktree (as tabs of this pane), then the usual terminal actions.
    static func terminal(_ store: Store, sessionID id: String, view: TerminalView) -> NSMenu {
        let m = NSMenu()
        if let s = store.session(id), let wt = store.worktree(for: s) {
            let where_ = NSMenuItem(title: "\(store.projectName(of: wt)) / \(wt.alias)", action: nil, keyEquivalent: "")
            where_.isEnabled = false
            m.addItem(where_)
            kinds(store, wt: wt, into: m) { store.focusSession(id) }
            for item in m.items.dropFirst() { item.title = "新建" + (item.title.first?.isASCII == true ? " " : "") + item.title }
            m.addItem(.separator())
        }
        if view.hasSelection { m.addItem(ActionItem("复制") { view.copy(nil) }) }
        m.addItem(ActionItem("粘贴") { view.paste(nil) })
        m.addItem(.separator())
        if let pane = store.layout.pane(containing: id) {
            m.addItem(ActionItem("向右分屏") { store.focusSession(id); store.splitFocused(pane.id, edge: .right) })
            m.addItem(ActionItem("向下分屏") { store.focusSession(id); store.splitFocused(pane.id, edge: .bottom) })
        }
        return m
    }

    static func session(_ store: Store, _ s: AgentSession) -> NSMenu {
        let m = NSMenu()
        m.addItem(ActionItem("在新栏打开") { store.open(s.id, newPane: true) })
        m.addItem(ActionItem(store.isPinned(s.id) ? "取消置顶" : "置顶") { store.togglePin(s.id) })
        if store.status(of: s.id) != .history { m.addItem(ActionItem("结束会话") { store.closeTab(s.id) }) }
        if let cmd = s.launchCommand, s.agentSessionID != nil {
            m.addItem(ActionItem("复制恢复命令") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("cd \(s.cwd) && \(cmd)", forType: .string)
            })
        }
        return m
    }

    static func workspace(_ store: Store, _ w: Workspace) -> NSMenu {
        let m = NSMenu()
        m.addItem(ActionItem("重命名…") { store.promptRenameWorkspace(w) })
        // Order (also by dragging the squares); ⌃1…⌃9 follow it.
        if let i = store.workspaces.firstIndex(where: { $0.id == w.id }), store.workspaces.count > 1 {
            if i > 0 {
                m.addItem(ActionItem("移到最前") { store.reorderWorkspace(w.id, to: 0) })
                m.addItem(ActionItem("向前移") { store.reorderWorkspace(w.id, to: i - 1) })
            }
            if i < store.workspaces.count - 1 { m.addItem(ActionItem("向后移") { store.reorderWorkspace(w.id, to: i + 2) }) }
            m.addItem(.separator())
        }
        let color = NSMenuItem(title: "颜色", action: nil, keyEquivalent: "")
        let colors = NSMenu()
        for t in Workspace.tints {
            let it = ActionItem(t.name) { store.setColor(w.id, t.color) }
            it.image = swatch(t.color)
            it.state = w.tint == t.color ? .on : .off
            colors.addItem(it)
        }
        colors.addItem(.separator())
        let custom = ActionItem("自定义…") { WorkspaceColorPicker.shared.show(for: w, store: store) }
        if !Workspace.tints.contains(where: { $0.color == w.tint }) { custom.image = swatch(w.tint); custom.state = .on }
        colors.addItem(custom)
        color.submenu = colors
        m.addItem(color)
        if store.workspaces.count > 1 { m.addItem(ActionItem("删除…") { store.promptDeleteWorkspace(w) }) }
        return m
    }

    /// A round color chip for menu items.
    private static func swatch(_ hex: UInt32) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            NSColor(hex: hex).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

/// The system color panel, live-editing one workspace's color.
@MainActor
final class WorkspaceColorPicker: NSObject {
    static let shared = WorkspaceColorPicker()
    private weak var store: Store?
    private var workspaceID: String?

    func show(for w: Workspace, store: Store) {
        self.store = store
        workspaceID = w.id
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.isContinuous = true
        panel.color = NSColor(hex: w.tint)
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        guard let id = workspaceID, let c = panel.color.usingColorSpace(.sRGB) else { return }
        let hex = (UInt32((c.redComponent * 255).rounded()) << 16) | (UInt32((c.greenComponent * 255).rounded()) << 8) | UInt32((c.blueComponent * 255).rounded())
        store?.setColor(id, hex)
    }
}
