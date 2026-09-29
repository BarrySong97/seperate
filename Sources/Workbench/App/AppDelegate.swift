// @purpose App lifecycle, the main menu bar, and mapping Ghostty keybindings onto panes/tabs.
// @role    Starts GhosttyRuntime, Store, MainWindowController and Updater; menu actions call Store.
// @deps    AppKit, GhosttyKit, Store, MainWindowController, Updater, TerminalView
// @gotcha  Single-window app: Ghostty new-window/fullscreen actions are swallowed; the DEBUG
//          WORKBENCH_DEMO hooks are dev-only. docs/modules/app/README.md
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
                if store.workspaces.count == 1 { let cur = store.activeID; store.addWorkspace(name: tr("个人", "Personal")); store.switchWorkspace(to: cur) }
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

    /// Language menu: saved right away, applied on the next launch (offers to restart now).
    @objc func setLanguage(_ sender: NSMenuItem) {
        let lang = AppLanguage.allCases[sender.tag]
        guard lang != L10n.choice else { return }
        L10n.set(lang)
        guard L10n.resolves(lang) != L10n.isChinese else { return }   // same language as now: nothing to restart for
        let a = NSAlert()
        a.messageText = tr("重启 Seperate 以切换语言？", "Restart Seperate to switch the language?")
        a.informativeText = tr("正在运行的终端会被结束；Codex / Claude 会话之后可以从侧栏恢复。也可以稍后自己重启。",
                               "Running terminals will be stopped; Codex / Claude sessions can be reopened from the sidebar. You can also restart later yourself.")
        a.addButton(withTitle: tr("现在重启", "Restart Now"))
        a.addButton(withTitle: tr("稍后", "Later"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // Reopen once this process has exited; give up after 30 s if quitting was cancelled.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "for i in $(seq 150); do kill -0 $1 2>/dev/null || { open \"$0\"; exit 0; }; sleep 0.2; done",
                              Bundle.main.bundlePath, "\(ProcessInfo.processInfo.processIdentifier)"]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let u = Updater.shared
        switch item.action {
        case #selector(setLanguage(_:)):
            item.state = AppLanguage.allCases[item.tag] == L10n.choice ? .on : .off
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

    private func languageMenu() -> NSMenuItem {
        let m = NSMenu()
        for (i, lang) in AppLanguage.allCases.enumerated() {
            let it = NSMenuItem(title: lang.title, action: #selector(setLanguage(_:)), keyEquivalent: "")
            it.tag = i
            m.addItem(it)
            if lang == .system { m.addItem(.separator()) }
        }
        let host = NSMenuItem(title: tr("语言", "Language"), action: nil, keyEquivalent: "")
        host.submenu = m
        return host
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
            item(tr("关于 Seperate", "About Seperate"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            item(tr("检查更新…", "Check for Updates…"), #selector(checkForUpdates(_:)), ""),
            item(tr("启动时检查更新", "Check for Updates at Launch"), #selector(toggleAutoCheck(_:)), ""),
            item(tr("自动下载并安装更新", "Automatically Download and Install Updates"), #selector(toggleAutoInstall(_:)), ""),
            .separator(),
            languageMenu(),
            .separator(),
            item(tr("隐藏 Seperate", "Hide Seperate"), #selector(NSApplication.hide(_:)), "h"),
            item(tr("退出 Seperate", "Quit Seperate"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        sub(tr("文件", "File"), [
            item(tr("命令面板", "Command Palette"), #selector(showPalette(_:)), "k"),
            item(tr("命令面板", "Command Palette"), #selector(showPalette(_:)), "p"),
            .separator(),
            item(tr("新建终端 Tab", "New Terminal Tab"), #selector(newShell(_:)), "t"),
            item(tr("新建项目…", "New Project…"), #selector(newProject(_:)), "n"),
            item(tr("添加项目…", "Add Project…"), #selector(addProject(_:)), "o"),
            item(tr("用默认编辑器打开 Worktree", "Open Worktree in Default Editor"), #selector(openInEditor(_:)), "o", [.command, .option]),
            item(tr("收件箱", "Inbox"), #selector(toggleInbox(_:)), "i"),
            item(tr("重新扫描会话", "Rescan Sessions"), #selector(refreshSessions(_:)), "r", [.command, .shift]),
            .separator(),
            item(tr("关闭 Tab", "Close Tab"), #selector(closeTab(_:)), "w"),
        ])
        sub(tr("编辑", "Edit"), [
            item(tr("复制", "Copy"), #selector(TerminalView.copy(_:)), "c"),
            item(tr("粘贴", "Paste"), #selector(TerminalView.paste(_:)), "v"),
            item(tr("全选", "Select All"), #selector(NSResponder.selectAll(_:)), "a"),
        ])
        var layoutItems = [
            item(tr("切换侧栏", "Toggle Sidebar"), #selector(toggleSidebar(_:)), "b"),
            .separator(),
            item(tr("向右分屏", "Split Right"), #selector(splitRight(_:)), "d"),
            item(tr("向下分屏", "Split Down"), #selector(splitDown(_:)), "d", [.command, .shift]),
            .separator(),
        ]
        for (i, p) in LayoutPreset.allCases.enumerated() {
            layoutItems.append(item(p == .grid ? tr("2×2 布局", "2×2 Grid") : tr("\(p.paneCount) 栏布局", "\(p.paneCount)-Pane Layout"), #selector(applyPreset(_:)), "\(i + 1)", [.command, .control], tag: i))
        }
        layoutItems.append(.separator())
        for n in 1...9 { layoutItems.append(item(tr("聚焦第 \(n) 栏", "Focus Pane \(n)"), #selector(focusPaneN(_:)), "\(n)", tag: n)) }
        sub(tr("布局", "Layout"), layoutItems)
        var wsItems = [
            item(tr("新建 Workspace…", "New Workspace…"), #selector(newWorkspace(_:)), "n", [.command, .shift]),
            item(tr("下一个 Workspace", "Next Workspace"), #selector(nextWorkspace(_:)), "]", [.control]),
            item(tr("上一个 Workspace", "Previous Workspace"), #selector(previousWorkspace(_:)), "[", [.control]),
            .separator(),
        ]
        for n in 1...9 { wsItems.append(item(tr("切换到第 \(n) 个 Workspace", "Switch to Workspace \(n)"), #selector(switchWorkspaceN(_:)), "\(n)", [.control], tag: n)) }
        sub("Workspace", wsItems)
        let window = NSMenu(title: tr("窗口", "Window"))
        window.addItem(item(tr("最小化", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        let wi = NSMenuItem(title: tr("窗口", "Window"), action: nil, keyEquivalent: ""); wi.submenu = window
        bar.addItem(wi)
        NSApp.windowsMenu = window
        return bar
    }
}
