import Foundation

// Agent Terminal (~/GitHub/mac-apps/agent-terminal) is our own terminal app. It answers
// on a Unix socket what iTerm2 answers by AppleScript: one line of JSON in, one out.
// Its sessions pass as iTerm2's to the hooks, through ITERM_SESSION_ID, and are told
// apart by the first group of their id.
enum AgentLink {
    static let term = "AgentTerminal"
    static let bundleID = "com.chris.agent-terminal"
    private static let prefix = "A6E47E00"
    static let path = NSHomeDirectory() + "/Library/Application Support/AgentTerminal/link.sock"

    static func owns(_ session: String) -> Bool { session.uppercased().hasPrefix(prefix) }

    /// A new session in `folder` with `line` typed into it. False when the app isn't open:
    /// then the caller opens iTerm2.
    static func open(folder: String, line: String) -> Bool {
        call(["op": "new", "folder": folder, "line": line])?["ok"] as? Bool == true
    }

    /// One request and its answer. Nil when the app isn't there or doesn't answer in time.
    static func call(_ request: [String: Any]) -> [String: Any]? {
        guard var body = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        body.append(10)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var limit = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8.prefix(capacity - 1)) }
        let joined = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard joined == 0, body.withUnsafeBytes({ write(fd, $0.baseAddress, body.count) }) == body.count else { return nil }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while reply.last != 10 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            reply.append(contentsOf: chunk[0..<n])
        }
        return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    }
}
