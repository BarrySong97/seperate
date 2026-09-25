import XCTest
@testable import Workbench

/// The pieces between an agent and the app: wrapper scripts, the hook helper, the notify chain.
final class AgentHooksTests: XCTestCase {
    private var dir: URL!
    override func setUp() { dir = useTempDataDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func run(_ exe: String, _ args: [String], env: [String: String], stdin: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        let out = Pipe(); p.standardOutput = out
        let input = Pipe(); p.standardInput = input
        try p.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// Fake `claude` / `codex` that print their arguments, first on PATH.
    private func fakeAgents() throws -> String {
        let bin = dir.appendingPathComponent("fake").path
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for name in ["claude", "codex"] {
            let f = bin + "/" + name
            try "#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done\n".write(toFile: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f)
        }
        return bin
    }

    func testWrappersAddHooksAndPassArguments() throws {
        AgentHooks.install(helper: "/opt/hook")
        let env = AgentHooks.environment(session: "s1", helper: "/opt/hook")
        let path = try fakeAgents() + ":/usr/bin:/bin"
        let bin = try XCTUnwrap(env["SEPERATE_BIN"])

        let codex = try run(bin + "/codex", ["resume", "abc"], env: env.merging(["PATH": path]) { $1 })
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(codex, ["-c", "notify=[\"/opt/hook\",\"codex-notify\"]", "-c", "tui.notifications=true",
                               "-c", "tui.notification_method=\"osc9\"", "-c", "tui.notification_condition=\"always\"",
                               "resume", "abc"])

        let claude = try run(bin + "/claude", ["--resume", "x y"], env: env.merging(["PATH": path]) { $1 })
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(claude, ["--settings", try XCTUnwrap(env["SEPERATE_CLAUDE_SETTINGS"]), "--resume", "x y"])
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: claude[1]))) as? [String: Any]
        let hooks = try XCTUnwrap(settings?["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["UserPromptSubmit", "PostToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd", "PreToolUse"])
        let pre = try XCTUnwrap((hooks["PreToolUse"] as? [[String: Any]])?.first)
        XCTAssertEqual(pre["matcher"] as? String, "AskUserQuestion|ExitPlanMode", "only questions and plans, not every tool call")
    }

    func testTerminalCommandUsesWrapperOnlyForAgents() {
        let codex = AgentSession(id: "a", kind: .codex, agentSessionID: "abc", cwd: "/", title: "", lastActivity: Date())
        let shell = AgentSession(id: "b", kind: .shell, agentSessionID: nil, cwd: "/", title: "", lastActivity: Date())
        XCTAssertEqual(codex.launchCommand, "codex resume abc", "copy-resume stays the plain command")
        XCTAssertNil(AgentHooks.terminalCommand(for: shell))
    }

    func testUserCodexNotifyIsReadFromTopLevelOnly() throws {
        let f = dir.appendingPathComponent("config.toml").path
        try """
        model = "gpt-5"
        notify = ["/Apps/Tool", "turn-ended"]
        [profiles.x]
        notify = ["/other"]
        """.write(toFile: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentHooks.userCodexNotify(configPath: f), "[\"/Apps/Tool\", \"turn-ended\"]")
        try "[tui]\nnotify = [\"/x\"]\n".write(toFile: f, atomically: true, encoding: .utf8)
        XCTAssertNil(AgentHooks.userCodexNotify(configPath: f))
    }

    /// The real helper binary: Claude's stdin JSON and Codex's argument both arrive as app events.
    func testHelperForwardsEvents() throws {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SeperateHook").path
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("helper not built") }
        var got: [[AnyHashable: Any]] = []
        let token = DistributedNotificationCenter.default().addObserver(forName: AgentHooks.eventName, object: nil, queue: .main) {
            if ($0.userInfo?["session"] as? String) == "test-session" { got.append($0.userInfo ?? [:]) }
        }
        defer { DistributedNotificationCenter.default().removeObserver(token) }

        let chainOut = dir.appendingPathComponent("chain.txt").path
        let chain = dir.appendingPathComponent("chain.sh").path
        try "#!/bin/sh\necho \"$1 $2\" > \(chainOut)\n".write(toFile: chain, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chain)
        let env = ["SEPERATE_SESSION_ID": "test-session", "SEPERATE_CODEX_NOTIFY": "[\"\(chain)\",\"turn-ended\"]"]

        let out = try run(helper, ["claude"], env: env,
                          stdin: #"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#)
        XCTAssertEqual(out, "", "a Claude hook must print nothing")
        _ = try run(helper, ["codex-notify", #"{"type":"agent-turn-complete","last-assistant-message":"Fixed it."}"#], env: env)
        _ = try run(helper, ["claude"], env: env,
                    stdin: #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"pnpm test"}}"#)

        _ = try run(helper, ["claude"], env: env,
                    stdin: #"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"要不要一起删掉旧路由？"}]}}"#)

        let deadline = Date().addingTimeInterval(3)
        while got.count < 4, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(got.count, 4)
        XCTAssertEqual(got.last?["kind"] as? String, "AskUserQuestion")
        XCTAssertEqual(got.last?["message"] as? String, "要不要一起删掉旧路由？")
        got.removeLast()
        XCTAssertEqual(got.last?["event"] as? String, "PermissionRequest")
        XCTAssertEqual(got.last?["message"] as? String, "Bash: pnpm test")
        got.removeLast()
        XCTAssertEqual(got.first?["event"] as? String, "Notification")
        XCTAssertEqual(got.first?["kind"] as? String, "permission_prompt")
        XCTAssertEqual(got.last?["event"] as? String, "Stop")
        XCTAssertEqual(got.last?["message"] as? String, "Fixed it.")
        while !FileManager.default.fileExists(atPath: chainOut), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(try? String(contentsOfFile: chainOut, encoding: .utf8).hasPrefix("turn-ended {"), true, "the user's own notify still runs")
    }
}
