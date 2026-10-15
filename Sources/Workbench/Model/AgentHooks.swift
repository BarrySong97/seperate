// @purpose Installs per-launch Claude/Codex wrapper scripts + hooks file + the `seperate` CLI link, and builds
//          each terminal's env (PATH with the CLI, the one-launch system prompt for agents).
// @role    install() at Store init; environment()/terminalCommand() used when Store starts a TerminalView;
//          the hooks it installs run the SeperateHook helper, which reports back to Store.
// @deps    Foundation, Store.dataDir, bundled seperate-hook executable, ~/.codex/config.toml (read only)
// @gotcha  Never edit the user's Claude/Codex config; without the bundled helper agents start plain (no status).
//          Only <dataDir>/cli goes on PATH, never bin/ (nested agents would report as their parent).
//          docs/modules/model/README.md, docs/topics/agent-hooks.md
import Foundation

/// How Seperate learns what an agent is doing, without touching the user's own Claude/Codex config.
///
/// Agents are started through two small wrapper scripts (in the app's data folder) that add our
/// hooks for that one launch only:
///   claude → `claude --settings <our hooks file>`: UserPromptSubmit / PostToolUse = working,
///            PermissionRequest / Notification (permission) = needs you, Stop = done, SessionEnd = ended.
///   codex  → `codex -c notify=[seperate-hook]` (turn complete = done) plus Codex's own terminal
///            notifications, always on, which carry approvals, plan prompts and questions (= needs you; Store.codexNeed).
/// Every hook runs `seperate-hook`, which forwards the event to the app (see Sources/SeperateHook).
enum AgentHooks {
    static let eventName = Notification.Name("dev.seperate.agent-event")

    /// The helper inside the app bundle; nil when running outside a bundle (then agents start plain).
    static var helper: String? {
        let p = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/seperate-hook").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// The `seperate` CLI inside the app bundle (named apart from the app binary: the disk is case-insensitive).
    static var cli: String? {
        let p = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/seperate-cli").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    private static var binDir: URL { Store.dataDir.appendingPathComponent("bin", isDirectory: true) }
    /// Holds only `seperate`, so it can go on PATH. Never put binDir there: an agent's own `claude` would then
    /// run through our wrapper and report its events as the parent session's.
    static var cliDir: URL { Store.dataDir.appendingPathComponent("cli", isDirectory: true) }
    private static var claudeSettings: URL { Store.dataDir.appendingPathComponent("claude-hooks.json") }
    static var agentPrompt: URL { Store.dataDir.appendingPathComponent("agent-prompt.md") }

    /// Appended to the system prompt of agents Seperate starts (Claude: --append-system-prompt-file; Codex:
    /// developer_instructions), for that launch only. Short: `seperate --help` has the details.
    static let agentPromptText = """
    You are running inside Seperate, a macOS workbench that shows Claude Code, Codex and shell sessions side by side, \
    grouped by project and git worktree. The `seperate` command (on PATH) controls it: list sessions, start new \
    Claude / Codex / shell sessions as panes the user can watch, send them input, wait for their turn to end, read \
    their screen and close them. When you hand work to another agent, prefer `seperate new` so the user can see it. \
    Run `seperate --help` before first use.
    """

    /// Writes the wrappers and the Claude hooks file. Cheap and idempotent; called at launch.
    static func install(helper: String? = AgentHooks.helper, cli: String? = AgentHooks.cli) {
        guard helper != nil else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        if let cli {
            try? fm.createDirectory(at: cliDir, withIntermediateDirectories: true)
            let link = cliDir.appendingPathComponent("seperate")
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != cli {
                try? fm.removeItem(at: link)
                try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: cli)
            }
            try? agentPromptText.write(to: agentPrompt, atomically: true, encoding: .utf8)
        }
        let hook = ["type": "command", "command": "\"$SEPERATE_HOOK\" claude", "timeout": 5] as [String: Any]
        let events = ["UserPromptSubmit", "PostToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"]
        var hooks: [String: Any] = Dictionary(uniqueKeysWithValues: events.map { ($0, [["hooks": [hook]]]) })
        // Claude asking you something, or waiting for you to approve its plan.
        hooks["PreToolUse"] = [["matcher": "AskUserQuestion|ExitPlanMode", "hooks": [hook]]]
        let settings = ["hooks": hooks]
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: claudeSettings, options: .atomic)
        }
        let scripts = [
            "claude": """
            #!/bin/sh
            # Seperate: Claude Code with Seperate's status hooks for this launch (your settings still apply),
            # plus a note that the `seperate` command can control the app.
            [ -n "$SEPERATE_CLI_DIR" ] && export PATH="$SEPERATE_CLI_DIR:$PATH"
            [ -f "$SEPERATE_AGENT_PROMPT" ] && set -- --append-system-prompt-file "$SEPERATE_AGENT_PROMPT" "$@"
            exec claude --settings "$SEPERATE_CLAUDE_SETTINGS" "$@"
            """,
            "codex": """
            #!/bin/sh
            # Seperate: Codex reporting turn completion and approval requests to Seperate for this launch,
            # plus a note that the `seperate` command can control the app (only if you set no developer_instructions).
            [ -n "$SEPERATE_CLI_DIR" ] && export PATH="$SEPERATE_CLI_DIR:$PATH"
            [ -n "$SEPERATE_CODEX_INSTRUCTIONS" ] && set -- -c "developer_instructions=$SEPERATE_CODEX_INSTRUCTIONS" "$@"
            exec codex -c "notify=[\\"$SEPERATE_HOOK\\",\\"codex-notify\\"]" \\
              -c tui.notifications=true -c 'tui.notification_method="osc9"' -c 'tui.notification_condition="always"' "$@"
            """,
        ]
        for (name, body) in scripts {
            let url = binDir.appendingPathComponent(name)
            try? (body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// Environment for a terminal of session `id`.
    static func environment(session id: String, helper: String? = AgentHooks.helper, cli: String? = AgentHooks.cli,
                            codexConfig: String = NSHomeDirectory() + "/.codex/config.toml") -> [String: String] {
        var env = ["SEPERATE_SESSION_ID": id, "WORKBENCH_SESSION": id]
        guard let helper else { return env }
        env["SEPERATE_HOOK"] = helper
        env["SEPERATE_BIN"] = binDir.path
        env["SEPERATE_CLAUDE_SETTINGS"] = claudeSettings.path
        if let chain = userCodexNotify(configPath: codexConfig) { env["SEPERATE_CODEX_NOTIFY"] = chain }
        if cli != nil {
            env["SEPERATE_SOCKET"] = ControlServer.defaultPath
            env["SEPERATE_CLI_DIR"] = cliDir.path
            env["SEPERATE_AGENT_PROMPT"] = agentPrompt.path
            env["PATH"] = cliDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            // Codex takes it as a TOML string; JSON's string escapes are valid TOML (slashes left alone).
            if !userSetsDeveloperInstructions(configPath: codexConfig),
               let data = try? JSONSerialization.data(withJSONObject: agentPromptText, options: [.fragmentsAllowed, .withoutEscapingSlashes]) {
                env["SEPERATE_CODEX_INSTRUCTIONS"] = String(decoding: data, as: UTF8.self)
            }
        }
        return env
    }

    /// The user's own top-level `developer_instructions` in ~/.codex/config.toml: then we leave Codex's alone.
    static func userSetsDeveloperInstructions(configPath: String) -> Bool {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { return false }
            if t.hasPrefix("developer_instructions") { return true }
        }
        return false
    }

    /// The command typed into a new terminal: the agent through its wrapper, or the plain command.
    static func terminalCommand(for s: AgentSession) -> String? {
        guard var plain = s.launchCommand else { return nil }
        // Website screenshots: the user's own status line (usage meters etc.) stays out of the picture.
        if Core.shotsRoot != nil, s.kind == .claude {
            plain += #" --settings '{"statusLine":{"type":"command","command":"true"}}'"#
        }
        guard helper != nil, s.kind != .shell else { return plain }
        return "\"$SEPERATE_BIN\"/" + plain   // "$SEPERATE_BIN"/codex resume <id>
    }

    /// The user's own top-level `notify = [...]` from ~/.codex/config.toml, as JSON, so it keeps running.
    static func userCodexNotify(configPath: String = NSHomeDirectory() + "/.codex/config.toml") -> String? {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { break }   // past the top-level table
            guard t.hasPrefix("notify"), let eq = t.firstIndex(of: "=") else { continue }
            let value = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // A TOML array of basic strings is also valid JSON; anything fancier is skipped.
            if let data = value.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) as? [String] != nil { return value }
            return nil
        }
        return nil
    }
}
