// @purpose Worktree dialogs: remove from Seperate, delete from disk (git worktree remove / prune), new-worktree sheet.
// @role    Called from Menus and Store.promptNewWorktree; runs git work through Store / Core.
// @deps    AppKit (NSAlert, NSPanel), Store, Core (worktreeStatus, listBranches).
// @gotcha  Deleting refuses uncommitted work unless explicitly forced; hide keeps files and git records.
//          See docs/modules/ui/README.md

import AppKit

/// Confirmations for removing a worktree (from Seperate only, or from disk) and the "new worktree" sheet.
@MainActor
enum WorktreeDialogs {
    // MARK: Remove from Seperate

    static func confirmHide(_ store: Store, _ wt: Worktree) {
        let running = store.openSessions(in: wt).filter { store.terminals[$0] != nil }.count
        let a = NSAlert()
        a.messageText = tr("从 Seperate 移除「\(wt.alias)」？", "Remove “\(wt.alias)” from Seperate?")
        a.informativeText = tr("只是不再在 Seperate 里显示。文件夹、Git 里的 worktree 登记和会话记录都会保留，Codex / Claude 仍然可以在里面工作。", "It just stops showing in Seperate. The folder, its Git worktree entry and the session history are kept, and Codex / Claude can still work in it.")
            + (running > 0 ? tr("\n\n它有 \(running) 个 Session 正在运行，会一起结束。", "\n\n\(running) of its sessions are running and will be stopped.") : "")
            + tr("\n\n以后可以在项目菜单「已隐藏的 Worktree」里恢复。", "\n\nYou can bring it back later from “Hidden Worktrees” in the project menu.")
        a.addButton(withTitle: tr("移除", "Remove"))
        a.addButton(withTitle: tr("取消", "Cancel"))
        if a.runModal() == .alertFirstButtonReturn { store.hideWorktree(wt) }
    }

    // MARK: Delete from disk

    static func confirmDelete(_ store: Store, _ wt: Worktree) {
        let st = Core.worktreeStatus(wt.path)
        if st.missing { return confirmPrune(store, wt) }
        if st.dirty > 0 { return blockedByChanges(store, wt, st) }

        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = tr("从磁盘删除「\(wt.alias)」？", "Delete “\(wt.alias)” from disk?")
        var info = tr("会执行 git worktree remove，删除这个文件夹。主仓库不受影响。\n\n路径：\(wt.path.abbreviatingHome)", "Runs git worktree remove and deletes this folder. The main repository is not affected.\n\nPath: \(wt.path.abbreviatingHome)")
        if let b = st.branch { info += tr("\n分支：\(b)", "\nBranch: \(b)") }
        info += tr("\n状态：没有未提交的改动", "\nStatus: no uncommitted changes")
        if let ahead = st.ahead, ahead > 0 { info += tr("，但有 \(ahead) 个提交还没推送到远端", ", but \(ahead) commits are not pushed yet") }
        let running = store.openSessions(in: wt).filter { store.terminals[$0] != nil }.count
        if running > 0 { info += tr("\n\n它有 \(running) 个 Session 正在运行，会一起结束。", "\n\n\(running) of its sessions are running and will be stopped.") }
        a.informativeText = info
        var branchBox: NSButton?
        if let b = st.branch {
            let box = NSButton(checkboxWithTitle: tr("同时删除分支 \(b)", "Also delete branch \(b)"), target: nil, action: nil)
            let hint = NSTextField.label(tr("只删已合并的分支；还没合并的会保留并告诉你。", "Only a merged branch is deleted; an unmerged one is kept and you are told."), font: NSFont.systemFont(ofSize: 11), color: .secondaryLabelColor)
            let v = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
            box.frame = NSRect(x: 0, y: 18, width: 320, height: 20)
            hint.frame = NSRect(x: 20, y: 0, width: 300, height: 15)
            v.addSubview(box); v.addSubview(hint)
            a.accessoryView = v
            branchBox = box
        }
        a.addButton(withTitle: tr("删除", "Delete")).hasDestructiveAction = true
        a.addButton(withTitle: tr("取消", "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        run(store, wt, force: false, branch: branchBox?.state == .on ? st.branch : nil)
    }

    /// Uncommitted work: refuse by default, offer to look at it, allow a deliberate force.
    private static func blockedByChanges(_ store: Store, _ wt: Worktree, _ st: Core.WorktreeStatus) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = tr("「\(wt.alias)」里有 \(st.dirty) 个未提交的改动", "“\(wt.alias)” has \(st.dirty) uncommitted changes")
        var info = tr("为了不丢掉工作，默认不会删除。可以先在终端里提交或丢弃这些改动再删。\n\n", "So no work is lost, it is not deleted. Commit or discard these changes in a terminal first, then delete it.\n\n")
        info += st.changed.joined(separator: "\n")
        if st.dirty > st.changed.count { info += tr("\n…还有 \(st.dirty - st.changed.count) 个", "\n…and \(st.dirty - st.changed.count) more") }
        var meta: [String] = []
        if let b = st.branch { meta.append(tr("分支 \(b)", "branch \(b)")) }
        if let ahead = st.ahead, ahead > 0 { meta.append(tr("比远端多 \(ahead) 个提交", "\(ahead) commits ahead of the remote")) }
        if !meta.isEmpty { info += "\n\n" + meta.joined(separator: " · ") }
        a.informativeText = info
        a.addButton(withTitle: tr("好", "OK"))
        a.addButton(withTitle: tr("在终端里查看", "View in Terminal"))
        a.addButton(withTitle: tr("仍然删除（丢弃改动）", "Delete Anyway (Discard Changes)")).hasDestructiveAction = true
        switch a.runModal() {
        case .alertSecondButtonReturn: store.newSession(.shell, in: wt)
        case .alertThirdButtonReturn: run(store, wt, force: true, branch: nil)
        default: break
        }
    }

    /// The folder is already gone: only git's record (and Seperate's) is left to clean up.
    private static func confirmPrune(_ store: Store, _ wt: Worktree) {
        let a = NSAlert()
        a.messageText = tr("「\(wt.alias)」的文件夹已经不在了", "The folder of “\(wt.alias)” is gone")
        a.informativeText = tr("\(wt.path.abbreviatingHome)\n\n可以清理掉 Git 里残留的 worktree 登记（git worktree prune）。", "\(wt.path.abbreviatingHome)\n\nYou can clean up the leftover worktree entry in Git (git worktree prune).")
        a.addButton(withTitle: tr("清理", "Clean Up"))
        a.addButton(withTitle: tr("取消", "Cancel"))
        if a.runModal() == .alertFirstButtonReturn { run(store, wt, force: false, branch: nil) }
    }

    private static func run(_ store: Store, _ wt: Worktree, force: Bool, branch: String?) {
        do {
            if let kept = try store.deleteWorktree(wt, force: force, deleteBranch: branch), let branch {
                let a = NSAlert()
                a.messageText = tr("Worktree 已删除，分支 \(branch) 保留了", "Worktree deleted; branch \(branch) was kept")
                a.informativeText = kept.contains("not fully merged") ? tr("这个分支还没有合并，为了不丢提交没有删除。", "This branch is not merged yet, so it was kept to avoid losing commits.") : kept
                a.runModal()
            }
        } catch {
            let a = NSAlert(error: error)
            a.messageText = tr("没能删除「\(wt.alias)」", "Couldn’t delete “\(wt.alias)”")
            a.runModal()
        }
    }

    // MARK: Hidden worktrees, restored from the project menu

    static func hiddenMenu(_ store: Store, _ p: Project) -> NSMenuItem? {
        let hidden = store.hiddenWorktrees(of: p)
        guard !hidden.isEmpty else { return nil }
        let item = NSMenuItem(title: tr("已隐藏的 Worktree（\(hidden.count)）", "Hidden Worktrees (\(hidden.count))"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for h in hidden {
            let name = store.aliases[h.path] ?? (h.path as NSString).lastPathComponent
            let it = ActionItem(tr("恢复「\(name)」", "Restore “\(name)”")) { store.unhideWorktree(h.path) }
            it.toolTip = h.path.abbreviatingHome + " · " + tr("\(RelativeTime.short(h.at))前隐藏", "hidden \(RelativeTime.short(h.at))")
            sub.addItem(it)
        }
        if hidden.count > 1 {
            sub.addItem(.separator())
            sub.addItem(ActionItem(tr("全部恢复", "Restore All")) { hidden.forEach { store.unhideWorktree($0.path) } })
        }
        item.submenu = sub
        return item
    }
}

// MARK: - New worktree sheet

/// Name, base branch (local / remote, searchable), new branch or detached, where it will live.
@MainActor
final class NewWorktreeSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: Store
    private let project: Project
    private let branches: Core.Branches
    private var remote = false
    private var shown: [Core.Branch] = []
    private var selected: String?

    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
    private let name = NSTextField()
    private let tabs = NSSegmentedControl()
    private let search = NSSearchField()
    private let table = NSTableView()
    private let newBranch = NSButton(radioButtonWithTitle: tr("新建分支", "New branch"), target: nil, action: nil)
    private let detached = NSButton(radioButtonWithTitle: tr("不建分支（detached，分支在终端里自己切）", "No branch (detached; switch branches in the terminal yourself)"), target: nil, action: nil)
    private let branchName = NSTextField()
    private let location = NSTextField.label(font: NSFont.systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let error = NSTextField.label(font: NSFont.systemFont(ofSize: 11), color: .systemRed)
    private let create = NSButton(title: tr("创建", "Create"), target: nil, action: nil)
    private var branchEdited = false
    private static var current: NewWorktreeSheet?   // keeps the sheet alive while it is open

    init(store: Store, project: Project) {
        self.store = store
        self.project = project
        self.branches = Core.listBranches(root: project.rootPath)
        super.init()
    }

    func present(on window: NSWindow) {
        Self.current = self
        build()
        window.beginSheet(panel) { _ in Self.current = nil }
        panel.makeFirstResponder(name)
    }

    private func build() {
        let v = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = v
        let title = NSTextField.label(tr("在 \(project.name) 新建 Worktree", "New Worktree in \(project.name)"), font: NSFont.systemFont(ofSize: 14, weight: .semibold))
        let nameLabel = NSTextField.label(tr("名称", "Name"), font: NSFont.systemFont(ofSize: 12), color: .secondaryLabelColor)
        name.placeholderString = tr("按用途起名，比如 测试 / 导出分页", "Name it for its purpose, like tests / export-paging")
        name.delegate = self
        let baseLabel = NSTextField.label(tr("基于分支", "Base branch"), font: NSFont.systemFont(ofSize: 12), color: .secondaryLabelColor)
        tabs.segmentCount = 2
        tabs.setLabel(tr("本地 \(branches.local.count)", "Local \(branches.local.count)"), forSegment: 0)
        tabs.setLabel(tr("远程 \(branches.remote.count)", "Remote \(branches.remote.count)"), forSegment: 1)
        tabs.selectedSegment = 0
        tabs.target = self; tabs.action = #selector(tabChanged)
        search.placeholderString = tr("搜索分支…", "Search branches…")
        search.delegate = self
        table.addTableColumn(NSTableColumn(identifier: .init("b")))
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(branchClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let modeLabel = NSTextField.label(tr("检出方式", "Checkout"), font: NSFont.systemFont(ofSize: 12), color: .secondaryLabelColor)
        newBranch.state = .on
        newBranch.target = self; newBranch.action = #selector(modeChanged)
        detached.target = self; detached.action = #selector(modeChanged)
        branchName.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        branchName.delegate = self
        let cancel = NSButton(title: tr("取消", "Cancel"), target: self, action: #selector(cancelSheet))
        cancel.keyEquivalent = "\u{1b}"
        create.target = self; create.action = #selector(createWorktree)
        create.keyEquivalent = "\r"

        let w: CGFloat = 520, pad: CGFloat = 20, inner = w - pad * 2
        func place(_ view: NSView, _ y: CGFloat, _ h: CGFloat, x: CGFloat = 20, width: CGFloat? = nil) {
            view.frame = NSRect(x: x, y: y, width: width ?? inner - (x - pad), height: h); v.addSubview(view)
        }
        // Frames from the bottom (AppKit's default coordinates).
        place(title, 488, 18)
        place(nameLabel, 462, 15)
        place(name, 434, 24)
        place(baseLabel, 406, 15)
        place(tabs, 376, 24, width: 170)
        place(search, 376, 24, x: 200, width: inner - 180)
        place(scroll, 196, 172)
        place(modeLabel, 170, 15)
        place(newBranch, 144, 20, width: 90)
        place(branchName, 142, 24, x: 110, width: inner - 90)
        place(detached, 118, 20)
        place(location, 88, 15)
        place(error, 66, 15)
        cancel.frame = NSRect(x: w - pad - 90 - 8 - 90, y: 18, width: 90, height: 30); v.addSubview(cancel)
        create.frame = NSRect(x: w - pad - 90, y: 18, width: 90, height: 30); v.addSubview(create)

        let main = branches.local.first { ["main", "master"].contains($0.name) } ?? branches.local.first
        selected = main?.name
        filter()
        update()
    }

    // MARK: Behaviour

    private func filter() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let list = remote ? branches.remote : branches.local
        shown = q.isEmpty ? list : list.filter { $0.name.lowercased().contains(q) }
        table.reloadData()
        if let s = selected, let i = shown.firstIndex(where: { $0.name == s }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
            table.scrollRowToVisible(i)
        } else {
            table.deselectAll(nil)
        }
    }

    private var trimmedName: String { name.stringValue.trimmingCharacters(in: .whitespaces) }

    private func update() {
        let n = trimmedName
        if !branchEdited { branchName.stringValue = n.isEmpty ? "" : "wt/" + n }
        branchName.isEnabled = newBranch.state == .on
        location.stringValue = tr("位置：", "Location: ") + store.newWorktreeDir(in: project, name: n.isEmpty ? tr("<名称>", "<name>") : n).abbreviatingHome
        let problem: String? = {
            if n.isEmpty { return nil }
            if n.contains("/") || n.contains("..") { return tr("名称里不能有 / 或 ..", "The name can’t contain / or ..") }
            if FileManager.default.fileExists(atPath: store.newWorktreeDir(in: project, name: n)) { return tr("这个位置已经有文件夹了", "A folder already exists there") }
            if selected == nil { return tr("选一个基于的分支", "Choose a base branch") }
            if newBranch.state == .on {
                let b = branchName.stringValue.trimmingCharacters(in: .whitespaces)
                if b.isEmpty { return tr("填写新分支名", "Enter a new branch name") }
                if branches.local.contains(where: { $0.name == b }) { return tr("分支 \(b) 已经存在", "Branch \(b) already exists") }
            }
            return nil
        }()
        error.stringValue = problem ?? ""
        create.isEnabled = !n.isEmpty && problem == nil
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === branchName { branchEdited = true }
        if (obj.object as? NSSearchField) === search { filter() }
        update()
    }

    @objc private func tabChanged() { remote = tabs.selectedSegment == 1; filter(); update() }
    @objc private func modeChanged(_ sender: NSButton) {
        newBranch.state = sender === newBranch ? .on : .off
        detached.state = sender === detached ? .on : .off
        update()
    }
    @objc private func branchClicked() {
        guard table.clickedRow >= 0, table.clickedRow < shown.count else { return }
        selected = shown[table.clickedRow].name
        update()
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if table.selectedRow >= 0, table.selectedRow < shown.count { selected = shown[table.selectedRow].name; update() }
    }

    @objc private func cancelSheet() { panel.sheetParent?.endSheet(panel) }

    @objc private func createWorktree() {
        guard create.isEnabled, let base = selected else { return }
        let branch = newBranch.state == .on ? branchName.stringValue.trimmingCharacters(in: .whitespaces) : nil
        do {
            try store.createWorktree(in: project, name: trimmedName, base: base, branch: branch)
            panel.sheetParent?.endSheet(panel)
        } catch {
            self.error.stringValue = error.localizedDescription
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let b = shown[row]
        let cell = NSTableCellView()
        let n = NSTextField.label(b.name, font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), color: .labelColor)
        let t = NSTextField.label(RelativeTime.short(Date(timeIntervalSince1970: TimeInterval(b.updated))), font: NSFont.systemFont(ofSize: 11), color: .secondaryLabelColor)
        t.alignment = .right
        cell.addSubview(n); cell.addSubview(t)
        n.frame = NSRect(x: 6, y: 4, width: 330, height: 16)
        t.frame = NSRect(x: 340, y: 4, width: 110, height: 16)
        return cell
    }
}
