// @purpose Unix socket the `seperate` CLI talks to: one JSON request line in, one JSON reply line out.
// @role    Started by AppDelegate (stopped at quit); hands each request to ControlCommands on the main actor.
// @deps    Darwin sockets, Dispatch, ControlCommands
// @gotcha  Same-user peers only (getpeereid); the socket file is 0600. If another live Seperate already owns the
//          socket (a demo run next to the real app), this one does not take it over. docs/modules/cli/README.md
import Darwin
import Foundation
import os

/// Listens on `<dataDir>/seperate.sock`. Each connection carries one request; `wait` keeps its connection
/// open until the agent reports or the timeout passes.
final class ControlServer: @unchecked Sendable {
    static let log = Logger(subsystem: "dev.seperate", category: "control")
    nonisolated static var defaultPath: String { ProcessInfo.processInfo.environment["SEPERATE_SOCKET"] ?? Store.dataDir.appendingPathComponent("seperate.sock").path }

    let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dev.seperate.control")
    private let handle: @Sendable ([String: Any]) async -> [String: Any]

    init(path: String = ControlServer.defaultPath, handle: @escaping @Sendable ([String: Any]) async -> [String: Any]) {
        self.path = path
        self.handle = handle
    }

    /// Binds and listens. Returns false when the path is unusable or another live server owns it.
    @discardableResult
    func start() -> Bool {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            Self.log.error("socket path too long: \(self.path, privacy: .public)"); return false
        }
        if Self.answers(path) { Self.log.info("another Seperate owns \(self.path, privacy: .public)"); return false }
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = Self.address(path)
        let old = umask(0o177)   // the file is created 0600
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        umask(old)
        guard bound == 0, listen(s, 16) == 0 else { close(s); return false }
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
        return true
    }

    func stop() {
        source?.cancel(); source = nil
        if fd >= 0 { close(fd); fd = -1; unlink(path) }
    }

    deinit { stop() }

    private func acceptOne() {
        let c = accept(fd, nil, nil)
        guard c >= 0 else { return }
        var on: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { close(c); return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in serve(c) }
    }

    private func serve(_ c: Int32) {
        var timeout = timeval(tv_sec: 10, tv_usec: 0)   // for reading the request only
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let line = Self.readLine(c) else { close(c); return }
        let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let handle = self.handle
        Task {
            let reply = request == nil ? ["ok": false, "error": "bad request: expected one JSON object per line"] : await handle(request!)
            var data = (try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes])) ?? Data(#"{"ok":false,"error":"unencodable reply"}"#.utf8)
            data.append(0x0A)
            data.withUnsafeBytes { buf in
                var off = 0
                while off < buf.count {
                    let n = write(c, buf.baseAddress! + off, buf.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
            close(c)
        }
    }

    // MARK: Helpers (also used by tests)

    static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(path.utf8.prefix(buf.count - 1))
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return addr
    }

    /// True when something is accepting connections on `path`.
    static func answers(_ path: String) -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var addr = address(path)
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    }

    /// One line (up to 4 MB), without its newline; nil on EOF before any data or on timeout.
    static func readLine(_ c: Int32) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < 4 << 20 {
            let n = read(c, &buf, buf.count)
            if n <= 0 { return data.isEmpty ? nil : data }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) { data.append(contentsOf: buf[0..<nl]); return data }
            data.append(contentsOf: buf[0..<n])
        }
        return nil
    }
}
