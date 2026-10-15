// @purpose Tests that SessionWatcher reacts to new transcripts only, and really fires on a file created on disk.
// @role    XCTest for Model/SessionWatcher.swift.
// @deps    XCTest, CoreServices, Workbench (@testable)
// @gotcha  The live test uses a temp "home", never the real ~/.claude or ~/.codex. docs/modules/model/README.md
import CoreServices
import XCTest
@testable import Workbench

final class SessionWatcherTests: XCTestCase {
    func testOnlyNewTranscriptsAndTheCodexIndexMatter() {
        let claude = "/h/.claude/projects", codex = "/h/.codex"
        let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        func m(_ p: String, _ f: FSEventStreamEventFlags) -> Bool { SessionWatcher.matters(path: p, flags: f, claude: claude, codex: codex) }
        XCTAssertTrue(m("/h/.claude/projects/-Users-x-proj/abc.jsonl", created))
        XCTAssertFalse(m("/h/.claude/projects/-Users-x-proj/abc.jsonl", modified), "appends by a running agent do not rescan")
        XCTAssertFalse(m("/h/.claude/projects/-Users-x-proj/abc/subagents/agent-1.jsonl", created), "subagent transcripts are not sessions")
        XCTAssertTrue(m("/h/.codex/sessions/2026/10/15/rollout-1.jsonl", created))
        XCTAssertFalse(m("/h/.codex/log/codex-tui.log", created))
        XCTAssertTrue(m("/h/.codex/session_index.jsonl", modified), "Codex titles live in the index")
        XCTAssertTrue(m("/h/.codex", FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)))
    }

    @MainActor func testFiresWhenATranscriptAppears() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let proj = home.appendingPathComponent(".claude/projects/-tmp-p")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let fired = expectation(description: "refresh requested")
        fired.assertForOverFulfill = false
        let watcher = SessionWatcher(home: home.path) { fired.fulfill() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            FileManager.default.createFile(atPath: proj.appendingPathComponent("s1.jsonl").path, contents: Data("{}\n".utf8))
        }
        wait(for: [fired], timeout: 5)
        _ = watcher
    }
}
