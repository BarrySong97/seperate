import Foundation

// Forwards an agent event to the running Seperate app. Must be quick, print nothing (Claude reads a
// hook's stdout as extra context) and always exit 0 so it can never block or break the agent.
//
//   seperate-hook claude                 Claude Code hook; the event JSON arrives on stdin
//   seperate-hook codex-notify '<json>'  Codex `notify`; the event JSON is the last argument
//
// The session comes from SEPERATE_SESSION_ID, which Seperate sets in every terminal it opens.

let env = ProcessInfo.processInfo.environment
let args = CommandLine.arguments
guard args.count >= 2, let session = env["SEPERATE_SESSION_ID"] else { exit(0) }

func json(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }

/// Last text the assistant wrote, from the tail of a Claude transcript (.jsonl).
func lastAssistantText(_ path: String) -> String? {
    guard let h = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
    guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n").reversed() {
        let o = json(Data(line.utf8))
        guard o["type"] as? String == "assistant", let m = o["message"] as? [String: Any],
              let parts = m["content"] as? [[String: Any]] else { continue }
        let t = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
        if !t.isEmpty { return t }
    }
    return nil
}

var info: [String: String] = ["session": session, "agent": "", "event": ""]
switch args[1] {
case "claude":
    let o = json(FileHandle.standardInput.readDataToEndOfFile())
    let event = o["hook_event_name"] as? String ?? ""
    info["agent"] = "claude"
    info["event"] = event
    info["kind"] = o["notification_type"] as? String ?? ""
    var message = o["message"] as? String ?? o["last_assistant_message"] as? String
    if message == nil, event == "Stop", let t = o["transcript_path"] as? String { message = lastAssistantText(t) }
    if event == "PreToolUse" || event == "PermissionRequest", let tool = o["tool_name"] as? String,
       tool == "AskUserQuestion" || tool == "ExitPlanMode" {
        info["kind"] = tool
        let input = o["tool_input"] as? [String: Any] ?? [:]
        if tool == "AskUserQuestion" {
            let q = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
            message = q ?? input["question"] as? String ?? "有问题要问你"
        } else {
            let firstLine = (input["plan"] as? String)?.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            message = "计划写好了，等你确认" + (firstLine.map { "：" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? "")
        }
    } else if event == "PermissionRequest", let tool = o["tool_name"] as? String {
        // "Bash: pnpm test", "Edit: src/app.ts" — what the agent wants to do.
        let input = o["tool_input"] as? [String: Any] ?? [:]
        let detail = ["command", "file_path", "url", "path", "pattern"].lazy.compactMap { input[$0] as? String }.first
        message = detail.map { "\(tool): \($0)" } ?? "\(tool)"
    }
    if let message { info["message"] = String(message.prefix(400)) }

case "codex-notify":
    let raw = args.count >= 3 ? args[args.count - 1] : ""
    let o = json(Data(raw.utf8))
    info["agent"] = "codex"
    info["event"] = (o["type"] as? String) == "agent-turn-complete" ? "Stop" : (o["type"] as? String ?? "")
    if let m = o["last-assistant-message"] as? String { info["message"] = String(m.prefix(400)) }
    // Keep whatever `notify` the user had configured working: run it too, with the same payload.
    if let chain = env["SEPERATE_CODEX_NOTIFY"], let cmd = (try? JSONSerialization.jsonObject(with: Data(chain.utf8))) as? [String],
       let exe = cmd.first {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(cmd.dropFirst()) + [raw]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

default:
    exit(0)
}

// A short trail of what arrived, for diagnosing (kept to the last ~200 lines).
if let dir = env["SEPERATE_BIN"].map({ URL(fileURLWithPath: $0).deletingLastPathComponent() }) {
    let log = dir.appendingPathComponent("hook-events.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(info["session"] ?? "") \(info["agent"] ?? "") \(info["event"] ?? "") \(info["kind"] ?? "") \(info["message"]?.prefix(80) ?? "")\n"
    let old = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    let kept = old.split(separator: "\n", omittingEmptySubsequences: true).suffix(199).joined(separator: "\n")
    try? ((kept.isEmpty ? "" : kept + "\n") + line).write(to: log, atomically: true, encoding: .utf8)
}

DistributedNotificationCenter.default().postNotificationName(.init("dev.seperate.agent-event"), object: nil,
                                                             userInfo: info, deliverImmediately: true)
exit(0)
