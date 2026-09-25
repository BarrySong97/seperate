import Foundation

/// How Seperate learns what an agent is doing, without touching the user's own Claude/Codex config.
///
/// Agents are started through two small wrapper scripts (in the app's data folder) that add our
/// hooks for that one launch only:
///   claude → `claude --settings <our hooks file>`: UserPromptSubmit / PostToolUse = working,
///            PermissionRequest / Notification (permission) = needs you, Stop = done, SessionEnd = ended.
///   codex  → `codex -c notify=[seperate-hook]` (turn complete = done) plus Codex's own terminal
///            notifications, always on, which carry "Approval requested" (= needs you).
/// Every hook runs `seperate-hook`, which forwards the event to the app (see Sources/SeperateHook).
enum AgentHooks {
    static let eventName = Notification.Name("dev.seperate.agent-event")

    /// The helper inside the app bundle; nil when running outside a bundle (then agents start plain).
    static var helper: String? {
        let p = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/seperate-hook").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    private static var binDir: URL { Store.dataDir.appendingPathComponent("bin", isDirectory: true) }
    private static var claudeSettings: URL { Store.dataDir.appendingPathComponent("claude-hooks.json") }

    /// Writes the wrappers and the Claude hooks file. Cheap and idempotent; called at launch.
    static func install(helper: String? = AgentHooks.helper) {
        guard helper != nil else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
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
            # Seperate: Claude Code with Seperate's status hooks for this launch (your settings still apply).
            exec claude --settings "$SEPERATE_CLAUDE_SETTINGS" "$@"
            """,
            "codex": """
            #!/bin/sh
            # Seperate: Codex reporting turn completion and approval requests to Seperate for this launch.
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
    static func environment(session id: String, helper: String? = AgentHooks.helper) -> [String: String] {
        var env = ["SEPERATE_SESSION_ID": id, "WORKBENCH_SESSION": id]
        guard let helper else { return env }
        env["SEPERATE_HOOK"] = helper
        env["SEPERATE_BIN"] = binDir.path
        env["SEPERATE_CLAUDE_SETTINGS"] = claudeSettings.path
        if let chain = userCodexNotify() { env["SEPERATE_CODEX_NOTIFY"] = chain }
        return env
    }

    /// The command typed into a new terminal: the agent through its wrapper, or the plain command.
    static func terminalCommand(for s: AgentSession) -> String? {
        guard let plain = s.launchCommand else { return nil }
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
