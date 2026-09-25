import AppKit

/// "新建项目": a name, a parent folder (remembered), and whether to start a Git repo.
/// Creates the folder, adds it to the active workspace and opens a terminal in it.
@MainActor
final class NewProjectSheet: NSObject, NSTextFieldDelegate {
    private let store: Store
    private var parent: String

    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
    private let name = NSTextField()
    private let parentLabel = NSTextField.label(font: NSFont.systemFont(ofSize: 12), color: .labelColor)
    private let gitBox = NSButton(checkboxWithTitle: "初始化 Git 仓库（main 分支 + 首次提交，之后可以开 Worktree）", target: nil, action: nil)
    private let location = NSTextField.label(font: NSFont.systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let error = NSTextField.label(font: NSFont.systemFont(ofSize: 11), color: .systemRed)
    private let create = NSButton(title: "创建", target: nil, action: nil)
    private static var current: NewProjectSheet?   // keeps the sheet alive while it is open
    private static let parentKey = "NewProjectParent"
    private static let gitKey = "NewProjectGit"

    init(store: Store) {
        self.store = store
        self.parent = Self.defaultParent(store)
        super.init()
    }

    /// Last folder used, else where the active workspace's first project lives, else ~/Developer or ~.
    private static func defaultParent(_ store: Store) -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if let saved = UserDefaults.standard.string(forKey: parentKey), fm.fileExists(atPath: saved, isDirectory: &isDir), isDir.boolValue {
            return saved
        }
        if let root = store.active.projectRoots.first { return (root as NSString).deletingLastPathComponent }
        let dev = NSHomeDirectory() + "/Developer"
        return fm.fileExists(atPath: dev) ? dev : NSHomeDirectory()
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
        let title = NSTextField.label("新建项目，加入「\(store.active.name)」", font: NSFont.systemFont(ofSize: 14, weight: .semibold))
        let nameLabel = NSTextField.label("项目名称", font: NSFont.systemFont(ofSize: 12), color: .secondaryLabelColor)
        name.placeholderString = "也是文件夹名，比如 my-app"
        name.delegate = self
        let whereLabel = NSTextField.label("放在", font: NSFont.systemFont(ofSize: 12), color: .secondaryLabelColor)
        parentLabel.lineBreakMode = .byTruncatingMiddle
        let choose = NSButton(title: "选择…", target: self, action: #selector(chooseParent))
        gitBox.state = UserDefaults.standard.object(forKey: Self.gitKey) as? Bool == false ? .off : .on
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelSheet))
        cancel.keyEquivalent = "\u{1b}"
        create.target = self; create.action = #selector(createProject)
        create.keyEquivalent = "\r"

        let w: CGFloat = 480, pad: CGFloat = 20, inner = w - pad * 2
        func place(_ view: NSView, _ y: CGFloat, _ h: CGFloat, x: CGFloat = 20, width: CGFloat? = nil) {
            view.frame = NSRect(x: x, y: y, width: width ?? inner - (x - pad), height: h); v.addSubview(view)
        }
        // Frames from the bottom (AppKit's default coordinates).
        place(title, 218, 18)
        place(nameLabel, 192, 15)
        place(name, 164, 24)
        place(whereLabel, 138, 15)
        place(parentLabel, 112, 18, width: inner - 90)
        place(choose, 106, 30, x: w - pad - 84, width: 84)
        place(gitBox, 80, 20)
        place(location, 58, 15)
        place(error, 40, 15)
        cancel.frame = NSRect(x: w - pad - 90 - 8 - 90, y: 8, width: 90, height: 30); v.addSubview(cancel)
        create.frame = NSRect(x: w - pad - 90, y: 8, width: 90, height: 30); v.addSubview(create)
        update()
    }

    // MARK: Behaviour

    private var trimmedName: String { name.stringValue.trimmingCharacters(in: .whitespaces) }

    private func update() {
        let n = trimmedName
        parentLabel.stringValue = parent.abbreviatingHome
        location.stringValue = "位置：" + (parent as NSString).appendingPathComponent(n.isEmpty ? "<名称>" : n).abbreviatingHome
        let problem: String? = {
            if n.isEmpty { return nil }
            if n.contains("/") || n.contains(":") || n == "." || n == ".." || n.hasPrefix(".") { return "名称里不能有 / 或 :，也不能以 . 开头" }
            let dir = (parent as NSString).appendingPathComponent(n)
            if let items = try? FileManager.default.contentsOfDirectory(atPath: dir), !items.isEmpty { return "这个位置已经有同名文件夹了" }
            return nil
        }()
        error.stringValue = problem ?? ""
        create.isEnabled = !n.isEmpty && problem == nil
    }

    func controlTextDidChange(_ obj: Notification) { update() }

    @objc private func chooseParent() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: parent)
        p.prompt = "选择"
        p.message = "新项目的文件夹会建在这里"
        p.beginSheetModal(for: panel) { [weak self] r in
            guard let self, r == .OK, let url = p.url else { return }
            self.parent = url.path
            self.update()
        }
    }

    @objc private func cancelSheet() { panel.sheetParent?.endSheet(panel) }

    @objc private func createProject() {
        guard create.isEnabled else { return }
        let git = gitBox.state == .on
        do {
            try store.createProject(name: trimmedName, in: parent, git: git)
            UserDefaults.standard.set(parent, forKey: Self.parentKey)
            UserDefaults.standard.set(git, forKey: Self.gitKey)
            panel.sheetParent?.endSheet(panel)
        } catch {
            self.error.stringValue = error.localizedDescription
        }
    }
}
