import AppKit
import GhosttyKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let store = Store()
    private var main: MainWindowController?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        GhosttyRuntime.shared.start()
        GhosttyRuntime.shared.onSurfaceAction = { [weak self] view, action in
            self?.handleTerminalShortcut(from: view, action) ?? false
        }
        NSApp.mainMenu = makeMenu()

        let wc = MainWindowController(store: store)
        main = wc
        wc.showWindow(nil)
        wc.workspace.sync(structure: true)
        NSApp.activate(ignoringOtherApps: true)

        store.refresh()
        Updater.shared.start()
        #if DEBUG
        if ProcessInfo.processInfo.environment["WORKBENCH_DEMO"] != nil {
            // Dev aid: drive the demo instance from a shell without UI scripting permissions.
            DistributedNotificationCenter.default().addObserver(forName: .init("dev.seperate.debug"), object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    guard let self, let cmd = n.object as? String, let sb = self.main?.sidebar else { return }
                    if cmd.hasPrefix("ws:"), let i = Int(cmd.dropFirst(3)), i < self.store.workspaces.count {
                        self.store.switchWorkspace(to: self.store.workspaces[i].id)
                    } else if cmd.hasPrefix("toggle:") {
                        sb.debugToggle(String(cmd.dropFirst(7)))
                    } else if cmd == "rows" {
                        let dump = "active=\(self.store.active.name) workspaces=\(self.store.workspaces.map(\.name))\n" + sb.debugRows()
                        try? dump.write(toFile: NSTemporaryDirectory() + "seperate-rows.txt", atomically: true, encoding: .utf8)
                    }
                }
            }
            // Dev aid: shells from three projects side by side, the first pane with two tabs.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [store] in
                let wts = store.visibleProjects.prefix(3).compactMap { store.worktrees(of: $0).first }
                for (i, wt) in wts.enumerated() { store.newSession(.shell, in: wt, newPane: i > 0) }
                if let first = wts.first { store.focusPane(number: 1); store.newSession(.shell, in: first) }
                if store.workspaces.count == 1 { let cur = store.activeID; store.addWorkspace(name: "个人"); store.switchWorkspace(to: cur) }
                if let q = ProcessInfo.processInfo.environment["WORKBENCH_DEMO_PICKER"] {
                    store.showPalette()
                    func find(_ v: NSView) -> CommandPalette? { (v as? CommandPalette) ?? v.subviews.lazy.compactMap(find).first }
                    if !q.isEmpty, let root = NSApp.mainWindow?.contentView, let p = find(root) { p.debugType(q) }
                }
            }
        }
        #endif
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refresh() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { store.shutdown() }

    // MARK: Ghostty keybindings → our layout
    // A focused terminal sees ⌘D / ⌘T / ⌘1… first; Ghostty turns them into actions which we map
    // onto panes and tabs instead of Ghostty's own windows.

    private func handleTerminalShortcut(from view: TerminalView, _ action: ghostty_action_s) -> Bool {
        let paneID = store.layout.pane(containing: view.sessionID)?.id ?? store.layout.focusedPaneID
        switch action.tag {
        case GHOSTTY_ACTION_NEW_SPLIT:
            let edge: DropEdge
            switch action.action.new_split {
            case GHOSTTY_SPLIT_DIRECTION_LEFT: edge = .left
            case GHOSTTY_SPLIT_DIRECTION_UP: edge = .top
            case GHOSTTY_SPLIT_DIRECTION_DOWN: edge = .bottom
            default: edge = .right
            }
            store.splitFocused(paneID, edge: edge)
        case GHOSTTY_ACTION_NEW_TAB:
            store.focus(pane: paneID)
            store.newShellInFocusedPane()
        case GHOSTTY_ACTION_CLOSE_TAB:
            store.closeTab(view.sessionID)
        case GHOSTTY_ACTION_GOTO_TAB:
            let n = Int(action.action.goto_tab.rawValue)
            if n > 0 { store.focusPane(number: n) }
            else if n == Int(GHOSTTY_GOTO_TAB_LAST.rawValue) { store.focusPane(number: store.layout.panes.count) }
            else { cyclePane(n == Int(GHOSTTY_GOTO_TAB_NEXT.rawValue) ? 1 : -1) }
        case GHOSTTY_ACTION_GOTO_SPLIT:
            cyclePane(action.action.goto_split == GHOSTTY_GOTO_SPLIT_PREVIOUS ? -1 : 1)
        case GHOSTTY_ACTION_NEW_WINDOW, GHOSTTY_ACTION_TOGGLE_FULLSCREEN, GHOSTTY_ACTION_CLOSE_WINDOW:
            return true   // single-window app; swallow
        default:
            return false
        }
        return true
    }

    private func cyclePane(_ step: Int) {
        let ps = store.layout.panes
        guard let i = ps.firstIndex(where: { $0.id == store.layout.focusedPaneID }) else { return }
        store.focus(pane: ps[(i + step + ps.count) % ps.count].id)
    }

    // MARK: Menu actions

    @objc func toggleSidebar(_ sender: Any?) { store.toggleSidebar() }
    @objc func addProject(_ sender: Any?) { store.pickProject() }
    @objc func newProject(_ sender: Any?) { store.promptNewProject() }
    @objc func newShell(_ sender: Any?) { store.newShellInFocusedPane() }
    @objc func splitRight(_ sender: Any?) { store.splitFocused(store.layout.focusedPaneID, edge: .right) }
    @objc func splitDown(_ sender: Any?) { store.splitFocused(store.layout.focusedPaneID, edge: .bottom) }
    @objc func closeTab(_ sender: Any?) { store.closeActiveTab() }
    @objc func focusPaneN(_ sender: NSMenuItem) { store.focusPane(number: sender.tag) }
    @objc func applyPreset(_ sender: NSMenuItem) { store.apply(LayoutPreset.allCases[sender.tag]) }
    @objc func refreshSessions(_ sender: Any?) { store.refresh() }
    @objc func toggleInbox(_ sender: Any?) { store.toggleInbox() }

    /// ⌥⌘O: the focused tab's worktree in the default editor.
    @objc func openInEditor(_ sender: Any?) {
        guard let id = store.layout.focusedPane?.active, let s = store.session(id) else { return }
        let path = store.worktree(for: s)?.path ?? s.cwd
        if let e = store.preferredEditor { e.open(path) }
    }
    @objc func switchWorkspaceN(_ sender: NSMenuItem) {
        let ws = store.workspaces
        if sender.tag >= 1, sender.tag <= ws.count { store.switchWorkspace(to: ws[sender.tag - 1].id) }
    }
    @objc func nextWorkspace(_ sender: Any?) { store.switchWorkspace(offset: 1) }
    @objc func previousWorkspace(_ sender: Any?) { store.switchWorkspace(offset: -1) }
    @objc func newWorkspace(_ sender: Any?) { store.promptNewWorkspace() }
    @objc func showPalette(_ sender: Any?) { store.showPalette() }

    // MARK: Updates

    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkForUpdates() }
    @objc func toggleAutoCheck(_ sender: Any?) { Updater.shared.automaticallyChecks.toggle() }
    @objc func toggleAutoInstall(_ sender: Any?) { Updater.shared.automaticallyDownloads.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let u = Updater.shared
        switch item.action {
        case #selector(checkForUpdates(_:)):
            return u.canCheckForUpdates
        case #selector(toggleAutoCheck(_:)):
            item.state = u.automaticallyChecks ? .on : .off
        case #selector(toggleAutoInstall(_:)):
            item.state = u.automaticallyDownloads ? .on : .off
            return u.automaticallyChecks
        default: break
        }
        return true
    }

    private func makeMenu() -> NSMenu {
        let bar = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            host.submenu = m
            bar.addItem(host)
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }

        sub("Seperate", [
            item("关于 Seperate", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            item("检查更新…", #selector(checkForUpdates(_:)), ""),
            item("自动检查更新", #selector(toggleAutoCheck(_:)), ""),
            item("自动下载并安装更新", #selector(toggleAutoInstall(_:)), ""),
            .separator(),
            item("隐藏 Seperate", #selector(NSApplication.hide(_:)), "h"),
            item("退出 Seperate", #selector(NSApplication.terminate(_:)), "q"),
        ])
        sub("文件", [
            item("命令面板", #selector(showPalette(_:)), "k"),
            item("命令面板", #selector(showPalette(_:)), "p"),
            .separator(),
            item("新建终端 Tab", #selector(newShell(_:)), "t"),
            item("新建项目…", #selector(newProject(_:)), "n"),
            item("添加项目…", #selector(addProject(_:)), "o"),
            item("用默认编辑器打开 Worktree", #selector(openInEditor(_:)), "o", [.command, .option]),
            item("收件箱", #selector(toggleInbox(_:)), "i"),
            item("重新扫描会话", #selector(refreshSessions(_:)), "r", [.command, .shift]),
            .separator(),
            item("关闭 Tab", #selector(closeTab(_:)), "w"),
        ])
        sub("编辑", [
            item("复制", #selector(TerminalView.copy(_:)), "c"),
            item("粘贴", #selector(TerminalView.paste(_:)), "v"),
            item("全选", #selector(NSResponder.selectAll(_:)), "a"),
        ])
        var layoutItems = [
            item("切换侧栏", #selector(toggleSidebar(_:)), "b"),
            .separator(),
            item("向右分屏", #selector(splitRight(_:)), "d"),
            item("向下分屏", #selector(splitDown(_:)), "d", [.command, .shift]),
            .separator(),
        ]
        for (i, p) in LayoutPreset.allCases.enumerated() {
            layoutItems.append(item(p == .grid ? "2×2 布局" : "\(p.paneCount) 栏布局", #selector(applyPreset(_:)), "\(i + 1)", [.command, .control], tag: i))
        }
        layoutItems.append(.separator())
        for n in 1...9 { layoutItems.append(item("聚焦第 \(n) 栏", #selector(focusPaneN(_:)), "\(n)", tag: n)) }
        sub("布局", layoutItems)
        var wsItems = [
            item("新建 Workspace…", #selector(newWorkspace(_:)), "n", [.command, .shift]),
            item("下一个 Workspace", #selector(nextWorkspace(_:)), "]", [.control]),
            item("上一个 Workspace", #selector(previousWorkspace(_:)), "[", [.control]),
            .separator(),
        ]
        for n in 1...9 { wsItems.append(item("切换到第 \(n) 个 Workspace", #selector(switchWorkspaceN(_:)), "\(n)", [.control], tag: n)) }
        sub("Workspace", wsItems)
        let window = NSMenu(title: "窗口")
        window.addItem(item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"))
        let wi = NSMenuItem(title: "窗口", action: nil, keyEquivalent: ""); wi.submenu = window
        bar.addItem(wi)
        NSApp.windowsMenu = window
        return bar
    }
}
