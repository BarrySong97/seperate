import Foundation

/// The install itself, separate from the window so it can run headless (`--install-to`) in tests.
struct Installation {
    static let appName = "Seperate.app"
    static let bundleID = "dev.workbench.app"

    let payload: URL          // Seperate.app carried inside the installer
    let destinationDir: URL

    var destination: URL { destinationDir.appendingPathComponent(Self.appName) }

    /// /Applications when this user can write to it, otherwise ~/Applications (no admin password needed).
    static func defaultDestinationDir() -> URL {
        let system = URL(fileURLWithPath: "/Applications")
        if FileManager.default.isWritableFile(atPath: system.path) { return system }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    }

    static func info(_ app: URL) -> (version: String, build: Int)? {
        guard let d = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        let version = d["CFBundleShortVersionString"] as? String ?? "?"
        let build = Int(d["CFBundleVersion"] as? String ?? "") ?? 0
        return (version, build)
    }

    var payloadInfo: (version: String, build: Int) { Self.info(payload) ?? ("?", 0) }
    var installedInfo: (version: String, build: Int)? { Self.info(destination) }

    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// Copies into a staging folder next to the destination, clears quarantine, then swaps it in,
    /// so a failed copy never leaves a half-installed app behind.
    /// `staging` receives the staging URL up front so a caller can watch the copy's progress.
    func run(staging: ((URL) -> Void)? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let stage = destinationDir.appendingPathComponent(".Seperate-installing-\(UUID().uuidString).app")
        staging?(stage)
        defer { try? fm.removeItem(at: stage) }

        try fm.copyItem(at: payload, to: stage)
        // A DMG downloaded from the web is quarantined, and so is every file copied out of it.
        // The user already chose to run this installer, so the installed app should open without a second prompt.
        let x = Process()
        x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        x.arguments = ["-dr", "com.apple.quarantine", stage.path]
        try x.run(); x.waitUntilExit()

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: stage)
        } else {
            try fm.moveItem(at: stage, to: destination)
        }
    }
}
