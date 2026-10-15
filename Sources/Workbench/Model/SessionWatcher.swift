// @purpose Watches the Claude / Codex transcript folders so sessions started outside Seperate show up within ~1 s.
// @role    Created by AppDelegate next to the 60 s refresh timer; calls back (debounced) to Store.refresh().
// @deps    CoreServices (FSEvents), Foundation
// @gotcha  Only new transcripts (and Codex's title index) trigger a scan: a running agent appends to its
//          transcript all the time, and rescanning on every append would read every head again and again.
//          Folders missing at launch are not watched; the timer covers them. docs/modules/model/README.md
import CoreServices
import Foundation

/// FSEvents on `~/.claude/projects` and `~/.codex`; fires `onChange` once things settle.
@MainActor
final class SessionWatcher {
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void
    private let claudeRoot: String
    private let codexRoot: String

    init(home: String = NSHomeDirectory(), onChange: @escaping () -> Void) {
        self.onChange = onChange
        // FSEvents reports resolved paths (/private/var/…, symlinked homes), so compare against those.
        func real(_ p: String) -> String {
            guard let r = realpath(p, nil) else { return p }
            defer { free(r) }
            return String(cString: r)
        }
        claudeRoot = real(home + "/.claude/projects")
        codexRoot = real(home + "/.codex")
        let roots = [claudeRoot, codexRoot].filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let watcher = Unmanaged<SessionWatcher>.fromOpaque(info).takeUnretainedValue()
            let events = (0..<count).map { (paths[$0], flags[$0]) }
            MainActor.assumeIsolated { watcher.received(events) }
        }, &ctx, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    isolated deinit {
        pending?.cancel()
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }

    private func received(_ events: [(String, FSEventStreamEventFlags)]) {
        guard events.contains(where: { Self.matters(path: $0.0, flags: $0.1, claude: claudeRoot, codex: codexRoot) }) else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// Whether an event can change the session list: a new transcript where the scanner looks
    /// (`<claude>/<dir>/<id>.jsonl`, `<codex>/sessions/**/rollout-*.jsonl`) or Codex's title index.
    nonisolated static func matters(path: String, flags: FSEventStreamEventFlags, claude: String, codex: String) -> Bool {
        if flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 { return true }   // events were dropped
        if path == codex + "/session_index.jsonl" { return true }
        let born = flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
        guard born, path.hasSuffix(".jsonl") else { return false }
        if path.hasPrefix(claude + "/") {
            return path.dropFirst(claude.count + 1).split(separator: "/").count == 2   // subagent transcripts nest deeper
        }
        return path.hasPrefix(codex + "/sessions/") && (path as NSString).lastPathComponent.hasPrefix("rollout-")
    }
}
