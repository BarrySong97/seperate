// @purpose Tests for the agent → app pipe: wrapper scripts, Codex notify chaining, the hook helper's events, and
//          the `seperate` CLI's PATH entry, agent prompt and first-prompt launch command.
// @role    XCTest for AgentHooks and the SeperateHook executable (skipped if the helper is not built).
// @deps    XCTest, Workbench (@testable), SeperateHook build product, DistributedNotificationCenter
// @gotcha  Uses a temp SEPERATE_DATA_DIR (useTempDataDir); the helper must print nothing. docs/topics/agent-hooks.md
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

    /// With the CLI bundled: `seperate` goes on PATH (alone, never the wrappers' bin/), and agents get the
    /// one-launch note about it, unless the user has Codex developer_instructions of their own.
    func testCLIOnPathAndAgentPrompt() throws {
        AgentHooks.install(helper: "/opt/hook", cli: "/opt/seperate-cli")
        let link = dir.appendingPathComponent("cli/seperate").path
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "/opt/seperate-cli")
        let config = dir.appendingPathComponent("config.toml").path
        try "model = \"x\"\n".write(toFile: config, atomically: true, encoding: .utf8)
        let env = AgentHooks.environment(session: "s1", helper: "/opt/hook", cli: "/opt/seperate-cli", codexConfig: config)
        let pathDirs = try XCTUnwrap(env["PATH"]).split(separator: ":").map(String.init)
        XCTAssertEqual(pathDirs.first, dir.appendingPathComponent("cli").path)
        XCTAssertFalse(pathDirs.contains(try XCTUnwrap(env["SEPERATE_BIN"])), "nested agents must not pick up our wrappers")
        XCTAssertEqual(env["SEPERATE_SOCKET"], ControlServer.defaultPath)

        let fake = try fakeAgents() + ":/usr/bin:/bin"
        let bin = try XCTUnwrap(env["SEPERATE_BIN"])
        let claude = try run(bin + "/claude", ["--", "hi"], env: env.merging(["PATH": fake]) { $1 }).split(separator: "\n").map(String.init)
        XCTAssertEqual(claude, ["--settings", try XCTUnwrap(env["SEPERATE_CLAUDE_SETTINGS"]), "--append-system-prompt-file",
                                try XCTUnwrap(env["SEPERATE_AGENT_PROMPT"]), "--", "hi"])
        XCTAssertEqual(try String(contentsOfFile: claude[3], encoding: .utf8), AgentHooks.agentPromptText)

        let codex = try run(bin + "/codex", [], env: env.merging(["PATH": fake]) { $1 }).split(separator: "\n").map(String.init)
        let dev = try XCTUnwrap(codex.first { $0.hasPrefix("developer_instructions=") })
        let value = String(dev.dropFirst("developer_instructions=".count))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed) as? String, AgentHooks.agentPromptText)
        XCTAssertFalse(value.contains("\\/"), "TOML has no \\/ escape")

        try "developer_instructions = \"mine\"\n".write(toFile: config, atomically: true, encoding: .utf8)
        XCTAssertNil(AgentHooks.environment(session: "s1", helper: "/opt/hook", cli: "/opt/seperate-cli", codexConfig: config)["SEPERATE_CODEX_INSTRUCTIONS"],
                     "the user's own developer_instructions win")
    }

    func testFirstPromptIsReadFromItsFileOnFirstLaunchOnly() {
        var s = AgentSession(id: "new:1", kind: .claude, agentSessionID: nil, cwd: "/p", title: "t", lastActivity: Date())
        s.initialPromptFile = "/d/it's.txt"
        XCTAssertEqual(s.launchCommand, #"claude -- "$(cat '/d/it'\''s.txt')""#)
        s.kind = .codex
        XCTAssertEqual(s.launchCommand, #"codex -- "$(cat '/d/it'\''s.txt')""#)
        s.kind = .shell
        XCTAssertEqual(s.launchCommand, #"eval "$(cat '/d/it'\''s.txt')""#)
        s.kind = .claude; s.agentSessionID = "abc"
        XCTAssertEqual(s.launchCommand, "claude --resume abc", "a resume never sends the first prompt again")
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

    func testClaudeSkipPermissionsFlag() {
        var claude = AgentSession(id: "c", kind: .claude, agentSessionID: nil, cwd: "/", title: "", lastActivity: Date())
        XCTAssertEqual(claude.launchCommand, "claude")
        claude.skipPermissions = true
        XCTAssertEqual(claude.launchCommand, "claude --dangerously-skip-permissions")
        claude.agentSessionID = "abc"
        XCTAssertEqual(claude.launchCommand, "claude --resume abc --dangerously-skip-permissions", "resuming keeps the flag")
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

    /// Codex's TUI notifications: questions and plans need the user just like approvals (Claude gets these from hooks).
    func testCodexNotificationsThatNeedYou() {
        func need(_ t: String) -> String? { Store.codexNeed(t).map { "\($0.0)|\($0.1)" } }
        XCTAssertEqual(need("Question: Which database should I use?"), "question|Which database should I use?")
        XCTAssertEqual(need("Plan mode prompt: Ship the migration first?"), "plan|Ship the migration first?")
        XCTAssertEqual(need("Approval requested: cargo test"), "permission|Approval requested: cargo test")
        XCTAssertEqual(need("Approval requested by reviewer"), "permission|Approval requested by reviewer")
        XCTAssertEqual(need("Codex wants to edit src/app.ts"), "permission|Codex wants to edit src/app.ts")
        XCTAssertNil(need("Agent turn complete"))
        XCTAssertNil(need("I asked for approval earlier and it worked"), "a finished turn's text is not a request")
    }
}
