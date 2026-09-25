import AppKit

// "安装 Seperate.app": the double-click installer shown in the DMG. It carries Seperate.app in its Resources.
//   --install-to DIR   install without a window (used by CI and tests)
//   --payload APP      install this Seperate.app instead of the bundled one
//   --snapshot DIR     render each installer step to a PNG for design review

let args = CommandLine.arguments
func option(_ name: String) -> String? {
    args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

let payload = option("--payload").map { URL(fileURLWithPath: $0) }
    ?? Bundle.main.resourceURL!.appendingPathComponent(Installation.appName)

if let dir = option("--install-to") {
    let install = Installation(payload: payload, destinationDir: URL(fileURLWithPath: dir))
    do {
        try install.run()
        print(install.destination.path)
        exit(0)
    } catch {
        FileHandle.standardError.write("install failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let install = Installation(payload: payload, destinationDir: Installation.defaultDestinationDir())
    let controller = InstallerController(install: install)
    if let dir = option("--snapshot") {
        try! controller.snapshot(to: URL(fileURLWithPath: dir))
        exit(0)
    }
    final class Delegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    }
    let delegate = Delegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    let menu = NSMenu()
    let appItem = NSMenuItem(); appItem.submenu = NSMenu()
    appItem.submenu?.addItem(NSMenuItem(title: "退出安装", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    menu.addItem(appItem)
    app.mainMenu = menu
    controller.show()
    withExtendedLifetime((delegate, controller)) { app.run() }
}
