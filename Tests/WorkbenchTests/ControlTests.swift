// @purpose Tests for the `seperate` CLI path: ControlServer over a real socket, ControlCommands, and the CLI binary.
// @role    XCTest for Sources/Workbench/Control and Sources/SeperateCLI (binary tests skip if it is not built).
// @deps    XCTest, Darwin sockets, Workbench (@testable), SeperateCLI build product
// @gotcha  Temp data dir and a short temp socket path (sun_path holds ~104 bytes); socket I/O runs off the main
//          thread because the server answers on the main actor. docs/modules/cli/README.md
import AppKit
import Darwin
import XCTest
@testable import Workbench

final class ControlTests: XCTestCase {
    private var dir: URL!
    private var sock: String!
    private var server: ControlServer?

    override func setUp() {
        _ = NSApplication.shared   // agent phases touch NSApp (Dock badge, "is it in front")
        dir = useTempDataDir()
        sock = FileManager.default.temporaryDirectory.appendingPathComponent("sp-\(UUID().uuidString.prefix(8)).sock").path
    }

    override func tearDown() {
        server?.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    /// A store with one plain-folder project, served on `sock`.
    @MainActor private func serve() throws -> (Store, String) {
        let project = dir.appendingPathComponent("proj").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let store = Store()
        store.addProject(path: project)
        let commands = ControlCommands(store: store)
        server = ControlServer(path: sock) { req in await commands.handle(req) }
        XCTAssertTrue(server!.start())
        return (store, project)
    }

    /// One request line over the socket, off the main thread.
    private func call(_ cmd: String, _ args: [String: Any] = [:], caller: String? = nil, cwd: String? = nil, raw: Data? = nil) async -> [String: Any] {
        var req: [String: Any] = ["v": 1, "cmd": cmd, "args": args, "cwd": cwd ?? NSHomeDirectory(), "origin": "tests"]
        if let caller { req["caller"] = caller }
        var line = raw ?? (try! JSONSerialization.data(withJSONObject: req))
        line.append(0x0A)
        let path = sock!
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let s = socket(AF_UNIX, SOCK_STREAM, 0)
                var addr = ControlServer.address(path)
                _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                _ = line.withUnsafeBytes { write(s, $0.baseAddress!, $0.count) }
                var out = Data(), buf = [UInt8](repeating: 0, count: 65536)
                while true { let n = read(s, &buf, buf.count); if n <= 0 { break }; out.append(contentsOf: buf[0..<n]) }
                close(s)
                cont.resume(returning: (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] ?? [:])
            }
        }
    }

    private func data(_ r: [String: Any]) -> [String: Any] { r["data"] as? [String: Any] ?? [:] }

    @MainActor func testNewListStatusCloseOverTheSocket() async throws {
        let (store, project) = try serve()
        let made = await call("new", ["kind": "shell", "prompt": "echo hi"], cwd: project)
        XCTAssertEqual(made["ok"] as? Bool, true, "\(made)")
        let id = try XCTUnwrap(data(made)["id"] as? String)
        let handle = try XCTUnwrap(data(made)["handle"] as? String)
        XCTAssertEqual(store.layout.pane(containing: id)?.active, id, "shown in its pane, or its terminal never starts")
        XCTAssertEqual(store.remoteNotes[id]?.action, .opened)
        XCTAssertEqual(store.remoteNotes[id]?.by, "tests")
        let file = Store.promptFile(for: id).path
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "echo hi")
        XCTAssertEqual(store.session(id)?.initialPromptFile, file)

        let list = await call("list")
        XCTAssertTrue((list["text"] as? String ?? "").contains(handle), "\(list)")
        let status = await call("status", ["session": String(handle.prefix(5))])
        XCTAssertEqual(data(status)["id"] as? String, id, "a prefix of the handle finds it")

        let send = await call("send", ["session": handle, "text": "ls"])
        XCTAssertEqual(send["ok"] as? Bool, false, "no terminal in tests: refused, not dropped silently")
        XCTAssertTrue((send["error"] as? String ?? "").contains("not running"))

        let closed = await call("close", ["session": handle])
        XCTAssertEqual(closed["ok"] as? Bool, true)
        XCTAssertNil(store.layout.pane(containing: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "the first prompt goes with the session")
    }

    @MainActor func testNewOutsideAProjectNeedsAddProject() async throws {
        let (store, _) = try serve()
        let elsewhere = dir.appendingPathComponent("other").path
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        let refused = await call("new", ["kind": "shell"], cwd: elsewhere)
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertTrue((refused["error"] as? String ?? "").contains("--add-project"))
        let added = await call("new", ["kind": "shell", "addProject": true], cwd: elsewhere)
        XCTAssertEqual(added["ok"] as? Bool, true, "\(added)")
        XCTAssertNotNil(store.project(elsewhere))
    }

    @MainActor func testWaitReportsTurnsAfterTheLastSend() async throws {
        let (store, project) = try serve()
        let made = await call("new", ["kind": "claude"], cwd: project)
        let id = try XCTUnwrap(data(made)["id"] as? String)
        _ = store.terminal(for: id)   // a live terminal (no surface without a window, which is fine here)

        // The turn ends before anyone waits: wait still reports it.
        store.shotsSetPhase(id, .working)
        store.shotsSetPhase(id, .done("All tests pass"))
        let first = await call("wait", ["session": id])
        XCTAssertEqual(data(first)["state"] as? String, "done", "\(first)")
        XCTAssertEqual(data(first)["message"] as? String, "All tests pass")

        // Nothing new since: times out (exit code 2 in the CLI).
        let none = await call("wait", ["session": id, "timeout": 0.3])
        XCTAssertEqual(data(none)["timedOut"] as? Bool, true)

        // A question while waiting wakes it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { store.shotsSetPhase(id, .needsInput("Which database?"), need: .question) }
        let asked = await call("wait", ["session": id, "timeout": 5])
        XCTAssertEqual(data(asked)["state"] as? String, "needs-input")
        XCTAssertEqual(data(asked)["need"] as? String, "question")
        XCTAssertEqual(data(asked)["message"] as? String, "Which database?")

        // Closing it ends the wait too.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { store.endSession(id) }
        let gone = await call("wait", ["session": id, "timeout": 5])
        XCTAssertEqual(data(gone)["state"] as? String, "closed")
    }

    @MainActor func testRefusesSelfAndBadRequests() async throws {
        let (store, project) = try serve()
        let made = await call("new", ["kind": "claude"], cwd: project)
        let id = try XCTUnwrap(data(made)["id"] as? String)
        _ = store.terminal(for: id)
        let me = await call("send", ["session": "self", "text": "x"], caller: id)
        XCTAssertTrue((me["error"] as? String ?? "").contains("your own session"))
        let closeMe = await call("close", ["session": id], caller: id)
        XCTAssertEqual(closeMe["ok"] as? Bool, false, "closing yourself needs --force")
        let unknown = await call("frobnicate")
        XCTAssertEqual(unknown["ok"] as? Bool, false)
        let garbage = await call("", raw: Data("not json".utf8))
        XCTAssertEqual(garbage["ok"] as? Bool, false)
        let old = await call("", raw: try JSONSerialization.data(withJSONObject: ["v": 99, "cmd": "list"]))
        XCTAssertTrue((old["error"] as? String ?? "").contains("restart Seperate"))
        let missing = await call("status", ["session": "zzzzzzzz"])
        XCTAssertTrue((missing["error"] as? String ?? "").contains("no session matches"))
    }

    @MainActor func testASecondServerLeavesALiveSocketAlone() throws {
        _ = try serve()
        let other = ControlServer(path: sock) { _ in [:] }
        XCTAssertFalse(other.start(), "a demo run must not take the socket from the running app")
        XCTAssertTrue(ControlServer.answers(sock))
    }

    // MARK: The CLI binary

    private var cliBinary: String? {
        let p = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SeperateCLI").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    private func runCLI(_ args: [String], env extra: [String: String] = [:]) async throws -> (code: Int32, out: String, err: String) {
        let exe = try XCTUnwrap(cliBinary)
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"].merging(extra) { $1 }
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err
                try? p.run(); p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                                        String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)))
            }
        }
    }

    @MainActor func testCLIBinaryEndToEnd() async throws {
        guard cliBinary != nil else { throw XCTSkip("SeperateCLI not built (swift build first)") }
        let help = try await runCLI(["--help"])
        XCTAssertEqual(help.code, 0)
        for cmd in ["seperate new", "seperate send", "seperate wait", "seperate read", "seperate close", "seperate key"] {
            XCTAssertTrue(help.out.contains(cmd), "help documents \(cmd)")
        }
        let down = try await runCLI(["list"], env: ["SEPERATE_SOCKET": sock + ".missing"])
        XCTAssertEqual(down.code, 3, "not running has its own exit code")

        let (_, project) = try serve()
        let made = try await runCLI(["new", "shell", "--cwd", project, "--prompt", "echo hi", "--json"], env: ["SEPERATE_SOCKET": sock])
        XCTAssertEqual(made.code, 0, made.err)
        let handle = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(made.out.utf8)) as? [String: Any])?["handle"] as? String)
        let list = try await runCLI(["list"], env: ["SEPERATE_SOCKET": sock])
        XCTAssertTrue(list.out.contains(handle), list.out)
        let bad = try await runCLI(["status", "nope-nope"], env: ["SEPERATE_SOCKET": sock])
        XCTAssertEqual(bad.code, 1)
        XCTAssertTrue(bad.err.contains("no session matches"), bad.err)
    }
}
