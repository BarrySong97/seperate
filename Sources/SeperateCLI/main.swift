// @purpose The `seperate` command: lets agents (and scripts) list, start, drive, read, wait for and close sessions in Seperate.
// @role    Sends one JSON request over the app's Unix socket (ControlServer) and prints the reply; agents find it on
//          PATH inside Seperate terminals (AgentHooks puts <dataDir>/cli first).
// @deps    Foundation, Darwin sockets; env SEPERATE_SOCKET / SEPERATE_DATA_DIR / SEPERATE_SESSION_ID
// @gotcha  Separate target: no app code linked in; the request shape (v, cmd, args, caller, cwd, origin) must match
//          ControlCommands. The help text is how models learn the tool: keep it accurate. docs/modules/cli/README.md
import Darwin
import Foundation

let help = """
seperate — control Seperate, the macOS workbench this terminal may be running in.

Seperate shows Claude Code, Codex and shell sessions side by side, grouped by project and git worktree.
With this command you can start other agents as visible panes the user can watch, give them work,
wait for them and read their output. Sessions are named by a short handle (first 8 characters of
their id, see `list`); any unique prefix works, and "self" is the session you are running in.

USAGE
  seperate list [--all]              Workspaces → projects → worktrees, with running/open sessions
                                     (--all: also the 5 most recent past sessions per worktree)
  seperate status <session>          State, place and last message of one session
  seperate new <claude|codex|shell> [options]
                                     Start a session in a new pane next to yours (focus stays put)
      --cwd DIR                      Where (default: current directory); must be in a known project
      --worktree NAME                An existing worktree of that project (alias or folder name)
      --new-worktree NAME            Create a git worktree first (--base REF, default HEAD; --branch B, default NAME)
      --prompt TEXT | --prompt-file F | --prompt -
                                     First message for the agent (- reads stdin); for shell: a command to run
      --skip-permissions             Claude only: --dangerously-skip-permissions
      --tab | --down                 Open as a tab in your pane / split below (default: split right)
      --focus                        Move keyboard focus to it
      --add-project                  Add --cwd as a project if Seperate does not know it
  seperate send <session> <text…>    Type text into a session and press Enter (- reads stdin; --no-enter)
  seperate key <session> <key…>      Press keys: enter esc tab shift-tab up down left right backspace
                                     space ctrl-c ctrl-d y n 1-9
  seperate read <session> [--lines N]
                                     Last N lines (default 80) of the session's terminal
  seperate wait <session> [--until any|done] [--timeout SEC]
                                     Block until the agent's turn ends (done / failed / exited) or it needs
                                     input (question, plan, permission). Prints its last message. Counts from
                                     your last send/new, so a turn that already ended is reported at once.
                                     Default timeout 110 s (exit code 2): run it again to keep waiting.
  seperate open <session>            Show it in Seperate (switches workspace, starts past sessions)
  seperate close <session> [--force] End a session (Claude/Codex conversations can be reopened later)
  seperate refresh                   Rescan sessions now
  Add --json to any command for machine-readable output.

TYPICAL FLOW
  seperate new codex --prompt "Fix the failing test in core/src/db.rs"     → prints its handle, e.g. 4f2a9c1e
  seperate wait 4f2a9c1e                 → "4f2a9c1e done: …" or "needs input (question): …"
  seperate read 4f2a9c1e --lines 200     → the full screen when the message is not enough
  seperate send 4f2a9c1e "Yes, go ahead" → answer, then wait again
  seperate close 4f2a9c1e

NOTES
  • Everything you do is visible to the user; panes you open show "opened by / typed by <you>".
  • Do not send to or close sessions you did not start unless the user asked you to.
  • Messages in wait/status are short; use read for details.
  • Exit codes: 0 ok, 1 error, 2 wait timed out, 3 Seperate is not running.
"""

let env = ProcessInfo.processInfo.environment
var argv = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("seperate: " + message + "\n").utf8))
    exit(code)
}

if argv.isEmpty || argv.contains("-h") || argv.contains("--help") || argv.first == "help" { print(help); exit(0) }
let json = argv.contains("--json")
argv.removeAll { $0 == "--json" }
let cmd = argv.removeFirst()

/// Pulls `--name value` out of argv.
func option(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name) else { return nil }
    guard i + 1 < argv.count else { fail("\(name) needs a value") }
    let v = argv[i + 1]
    argv.removeSubrange(i...(i + 1))
    return v
}

func flag(_ name: String) -> Bool {
    guard let i = argv.firstIndex(of: name) else { return false }
    argv.remove(at: i)
    return true
}

func stdinText() -> String {
    String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}

func positional(_ what: String) -> String {
    guard let i = argv.firstIndex(where: { !$0.hasPrefix("--") }) else { fail("\(cmd) needs \(what)") }
    return argv.remove(at: i)
}

var args: [String: Any] = [:]
switch cmd {
case "list":
    args["all"] = flag("--all")
case "status", "open", "refresh":
    if cmd != "refresh" { args["session"] = positional("a session") }
case "new":
    args["kind"] = positional("claude, codex or shell")
    if let v = option("--cwd") { args["cwd"] = v }
    if let v = option("--worktree") { args["worktree"] = v }
    if let v = option("--new-worktree") { args["newWorktree"] = v }
    if let v = option("--base") { args["base"] = v }
    if let v = option("--branch") { args["branch"] = v }
    if let v = option("--prompt") { args["prompt"] = v == "-" ? stdinText() : v }
    if let f = option("--prompt-file") {
        guard let t = try? String(contentsOfFile: f, encoding: .utf8) else { fail("cannot read \(f)") }
        args["prompt"] = t
    }
    args["skipPermissions"] = flag("--skip-permissions")
    args["focus"] = flag("--focus")
    args["addProject"] = flag("--add-project")
    args["place"] = flag("--tab") ? "tab" : flag("--down") ? "down" : (_ = flag("--right"), "right").1
case "send":
    args["enter"] = !flag("--no-enter")
    args["session"] = positional("a session")
    let words = argv.filter { !$0.hasPrefix("--") }
    argv.removeAll { !$0.hasPrefix("--") }
    args["text"] = words == ["-"] ? stdinText() : words.joined(separator: " ")
case "key":
    args["session"] = positional("a session")
    args["keys"] = argv.filter { !$0.hasPrefix("--") }
    argv.removeAll { !$0.hasPrefix("--") }
case "read":
    if let v = option("--lines") { guard let n = Int(v) else { fail("--lines needs a number") }; args["lines"] = n }
    args["session"] = positional("a session")
case "wait":
    if let v = option("--until") { guard ["any", "done"].contains(v) else { fail("--until is any or done") }; args["until"] = v }
    if let v = option("--timeout") { guard let n = Double(v) else { fail("--timeout needs seconds") }; args["timeout"] = n }
    if let v = option("--since") { args["since"] = Int(v) }
    args["session"] = positional("a session")
case "close":
    args["force"] = flag("--force")
    args["session"] = positional("a session")
default:
    fail("unknown command \"\(cmd)\"; see seperate --help")
}
if let extra = argv.first { fail("unexpected \"\(extra)\" for \(cmd); see seperate --help") }

// MARK: Who is asking

/// The nearest ancestor that is not a shell: shown as "typed by …" when the caller is outside Seperate.
func origin() -> String {
    let skip: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "env", "login", "timeout", "xargs", "seperate", "sudo"]
    var pid = getppid()
    for _ in 0..<8 where pid > 1 {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let name = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? (String(cString: buf) as NSString).lastPathComponent : ""
        if !name.isEmpty, !skip.contains(name), !name.hasPrefix("-") { return name }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { break }
        pid = info.kp_eproc.e_ppid
    }
    return ""
}

// MARK: Talking to the app

let dataDir = env["SEPERATE_DATA_DIR"] ?? (NSHomeDirectory() + "/Library/Application Support/Workbench")
let socketPath = env["SEPERATE_SOCKET"] ?? (dataDir + "/seperate.sock")

var request: [String: Any] = ["v": 1, "cmd": cmd, "args": args, "cwd": FileManager.default.currentDirectoryPath, "origin": origin()]
if let s = env["SEPERATE_SESSION_ID"] { request["caller"] = s }
guard var line = try? JSONSerialization.data(withJSONObject: request) else { fail("could not encode the request") }
line.append(0x0A)

let s = socket(AF_UNIX, SOCK_STREAM, 0)
guard s >= 0 else { fail("no socket") }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { fail("socket path too long: \(socketPath)") }
withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    let bytes = Array(socketPath.utf8)
    buf.copyBytes(from: bytes)
    buf[bytes.count] = 0
}
let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
guard connected == 0 else { fail("Seperate is not running (nothing at \(socketPath))", code: 3) }
var on: Int32 = 1
setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
line.withUnsafeBytes { buf in
    var off = 0
    while off < buf.count {
        let n = write(s, buf.baseAddress! + off, buf.count - off)
        if n <= 0 { fail("lost the connection to Seperate") }
        off += n
    }
}

var reply = Data()
var chunk = [UInt8](repeating: 0, count: 64 * 1024)
while true {
    let n = read(s, &chunk, chunk.count)
    if n <= 0 { break }
    reply.append(contentsOf: chunk[0..<n])
}
close(s)

guard let obj = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else { fail("no reply from Seperate") }
guard obj["ok"] as? Bool == true else { fail(obj["error"] as? String ?? "failed") }
let data = obj["data"] as? [String: Any] ?? [:]
if json {
    let out = (try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    print(String(decoding: out, as: UTF8.self))
} else if let text = obj["text"] as? String, !text.isEmpty {
    print(text)
}
exit(data["timedOut"] as? Bool == true ? 2 : 0)
