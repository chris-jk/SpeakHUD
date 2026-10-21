import Foundation
import Network

/// Just enough HTTP for one page, a few JSON calls and a file: a request read whole,
/// one response, connection closed.
enum HTTP {
    static let maxHead = 16 * 1024
    static let maxBody = 64 * 1024
    /// A recording to be turned into words is the one body allowed to be bigger: three
    /// minutes of what the page records (16-bit sound, 16,000 samples a second).
    static let maxUpload = 6 * 1024 * 1024
    static let uploads: Set<String> = ["/api/hear", "/api/picture"]

    struct Request: Equatable {
        var method = "GET"
        var path = "/"
        var query: [String: String] = [:]
        var headers: [String: String] = [:]   // names lowercased
        var body = Data()

        var cookies: [String: String] {
            var out: [String: String] = [:]
            for pair in (headers["cookie"] ?? "").split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2 { out[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces) }
            }
            return out
        }
        var json: [String: Any]? {
            guard headers["content-type"]?.lowercased().hasPrefix("application/json") == true else { return nil }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }

    enum Parsed: Equatable { case incomplete, bad, request(Request) }

    /// `data` is everything received so far. `.incomplete` means keep reading.
    static func parse(_ data: Data) -> Parsed {
        guard let gap = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHead ? .bad : .incomplete
        }
        guard gap.lowerBound - data.startIndex <= maxHead,
              let head = String(data: data[data.startIndex..<gap.lowerBound], encoding: .utf8) else { return .bad }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2].hasPrefix("HTTP/1."), first[1].hasPrefix("/") else { return .bad }
        var r = Request()
        r.method = String(first[0])
        let target = first[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        r.path = String(target[0])
        if target.count > 1 {
            for pair in target[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let k = String(kv[0]).removingPercentEncoding else { return .bad }
                r.query[k] = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? "") : ""
            }
        }
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .bad }
            r.headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard r.headers["transfer-encoding"] == nil else { return .bad }   // nothing here sends chunks
        var length = 0
        if let raw = r.headers["content-length"] {
            let most = r.method == "POST" && uploads.contains(r.path) ? maxUpload : maxBody
            guard let n = Int(raw), (0...most).contains(n) else { return .bad }
            length = n
        }
        guard data.endIndex - gap.upperBound >= length else { return .incomplete }
        r.body = data.subdata(in: gap.upperBound..<(gap.upperBound + length))
        return .request(r)
    }

    /// Which bytes of a file a `Range` header asks for.
    enum Ranged: Equatable { case whole, part(ClosedRange<UInt64>), none }

    /// `header` against a file of `size` bytes. No header, or one this doesn't read
    /// (several ranges at once), is the whole file; a start past the end is `.none`.
    static func range(_ header: String?, of size: UInt64) -> Ranged {
        guard let h = header?.trimmingCharacters(in: .whitespaces), h.lowercased().hasPrefix("bytes="), !h.contains(",")
        else { return .whole }
        let ends = h.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard ends.count == 2 else { return .whole }
        if ends[0].isEmpty {   // "-500": the last 500 bytes
            guard let n = UInt64(ends[1]) else { return .whole }
            return n > 0 && size > 0 ? .part((size - min(n, size))...(size - 1)) : .none
        }
        guard let from = UInt64(ends[0]) else { return .whole }
        guard from < size else { return .none }
        if ends[1].isEmpty { return .part(from...(size - 1)) }
        guard let to = UInt64(ends[1]), to >= from else { return .whole }
        return .part(from...min(to, size - 1))
    }

    struct Response {
        /// Part of a file, sent in place of `body` a piece at a time (PhoneServer).
        struct Slice: Equatable {
            let path: String
            let offset: UInt64
            let length: UInt64
        }

        var status = 200
        var type = "application/json"
        var headers: [(String, String)] = []
        var body = Data()
        var file: Slice? = nil

        static func json(_ o: Any, status: Int = 200) -> Response {
            Response(status: status, body: (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8))
        }
        static func text(_ s: String, type: String = "text/plain; charset=utf-8", status: Int = 200) -> Response {
            Response(status: status, type: type, body: Data(s.utf8))
        }

        /// A file of `size` bytes, or the part of it `range` asks for: a phone only ever
        /// asks for a video in parts. The phone may keep it for an hour; the page asks
        /// for a changed file under a new address. `save` says it's to be kept, not
        /// shown: a browser then downloads it under its name.
        static func file(_ path: String, size: UInt64, type: String, range: String?, save: Bool = false) -> Response {
            let name = (path as NSString).lastPathComponent
                .addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))) ?? "file"
            var r = Response(type: type, headers: [("Accept-Ranges", "bytes"), ("Cache-Control", "private, max-age=3600"),
                                                   ("Content-Disposition", "\(save ? "attachment" : "inline"); filename*=UTF-8''\(name)")])
            switch HTTP.range(range, of: size) {
            case .whole:
                r.file = Slice(path: path, offset: 0, length: size)
            case .part(let part):
                r.status = 206
                r.headers.append(("Content-Range", "bytes \(part.lowerBound)-\(part.upperBound)/\(size)"))
                r.file = Slice(path: path, offset: part.lowerBound, length: part.upperBound - part.lowerBound + 1)
            case .none:
                r.status = 416
                r.headers.append(("Content-Range", "bytes */\(size)"))
            }
            return r
        }

        private static let reasons = [200: "OK", 206: "Partial Content", 303: "See Other", 400: "Bad Request",
                                      401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 409: "Conflict",
                                      416: "Range Not Satisfiable", 500: "Internal Server Error", 501: "Not Implemented",
                                      503: "Service Unavailable"]

        /// The status line and headers. Every response says what it is, that nothing may
        /// frame it, that the page loads nothing from anywhere else, and (unless it says
        /// otherwise itself) that nothing may keep it.
        func head() -> Data {
            var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "OK")\r\n"
            let fixed = [("Content-Type", type), ("Content-Length", String(file?.length ?? UInt64(body.count))),
                         ("Connection", "close"),
                         ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"),
                         ("X-Frame-Options", "DENY"), ("Referrer-Policy", "no-referrer"),
                         ("Content-Security-Policy",
                          "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; media-src 'self'; base-uri 'none'; form-action 'none'")]
            let own = Set(headers.map { $0.0.lowercased() })
            for (k, v) in fixed.filter({ !own.contains($0.0.lowercased()) }) + headers { head += "\(k): \(v)\r\n" }
            return Data((head + "\r\n").utf8)
        }

        /// The bytes to send, for a response with no file.
        func wire() -> Data { head() + body }
    }
}

/// The page's server: this Mac only. Connections and the handler run on the main queue.
final class PhoneServer {
    private let listener: NWListener
    private let handle: (HTTP.Request) -> HTTP.Response
    /// Asked first: a request it takes (true) is answered when it calls back, on the
    /// main queue, however long that is. Turning a recording into words takes a moment.
    var slow: ((HTTP.Request, @escaping (HTTP.Response) -> Void) -> Bool)?
    /// The port it's on, once it is (0 asks for any free one; tests do).
    private(set) var port: UInt16?
    /// How long a request may take to arrive; one still arriving that is already bigger
    /// than any ordinary request (a recording) gets this long again from each piece,
    /// up to `longest` in all. And how long a slow answer may take.
    static let patience: TimeInterval = 10
    static let longest: TimeInterval = 120

    init(port: UInt16, handle: @escaping (HTTP.Request) -> HTTP.Response) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: params)
        self.handle = handle
    }

    func start(failed: @escaping (String) -> Void = { _ in }) {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.port = self?.listener.port?.rawValue
            case .failed(let error): failed(error.localizedDescription)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] in self?.serve($0) }
        listener.start(queue: .main)
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        var buffer = Data()
        // A connection that never finishes its request doesn't get to sit there.
        var giveUp = DispatchWorkItem { connection.cancel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience, execute: giveUp)
        let began = Date()
        func wait(_ seconds: TimeInterval) {
            giveUp.cancel()
            giveUp = DispatchWorkItem { connection.cancel() }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: giveUp)
        }
        func answer(_ response: HTTP.Response) {
            if let slice = response.file {
                giveUp.cancel()
                return Self.stream(slice, after: response.head(), over: connection)
            }
            connection.send(content: response.wire(), completion: .contentProcessed { _ in
                giveUp.cancel()
                connection.cancel()
            })
        }
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
                guard let self = self else { return connection.cancel() }
                if let data = data { buffer.append(data) }
                switch HTTP.parse(buffer) {
                case .request(let r):
                    var answered = false
                    let later: (HTTP.Response) -> Void = { response in
                        guard !answered else { return }
                        answered = true
                        answer(response)
                    }
                    if let slow = self.slow, slow(r, later) {
                        // Its answer is on its way: the connection waits for that, not for more of a request.
                        if !answered { wait(Self.longest) }
                    } else {
                        answer(self.handle(r))
                    }
                case .bad: answer(.json(["error": "bad request"], status: 400))
                case .incomplete:
                    if done || error != nil { giveUp.cancel(); connection.cancel(); return }
                    let left = Self.longest - Date().timeIntervalSince(began)
                    if buffer.count > HTTP.maxBody, left > 0 { wait(min(Self.patience, left)) }
                    read()
                }
            }
        }
        connection.start(queue: .main)
        read()
    }

    /// How much of a file is read and sent at a time, and how long one piece may take
    /// to leave before the phone is taken to have gone.
    static let piece = 256 * 1024
    static let stall: TimeInterval = 30

    /// Send `head`, then the slice of the file a piece at a time, each read only once
    /// the last has left: a video is never all in memory, and a phone that stops
    /// listening stops the reading.
    private static func stream(_ slice: HTTP.Response.Slice, after head: Data, over connection: NWConnection) {
        guard let file = FileHandle(forReadingAtPath: slice.path), (try? file.seek(toOffset: slice.offset)) != nil else {
            connection.send(content: HTTP.Response.json(["error": "that file isn't there any more"], status: 404).wire(),
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        var left = slice.length
        var watch = DispatchWorkItem {}
        func finish() {
            watch.cancel()
            try? file.close()
            connection.cancel()
        }
        func send(_ data: Data, then next: @escaping () -> Void) {
            watch.cancel()
            watch = DispatchWorkItem { connection.cancel() }   // the send then fails, and finishes
            DispatchQueue.main.asyncAfter(deadline: .now() + stall, execute: watch)
            connection.send(content: data, completion: .contentProcessed { error in
                if error == nil { next() } else { finish() }
            })
        }
        func more() {
            // A file that has shrunk since it was measured can't keep the length promised.
            guard left > 0, let data = try? file.read(upToCount: Int(min(UInt64(piece), left))), !data.isEmpty
            else { return finish() }
            left -= UInt64(data.count)
            send(data, then: more)
        }
        send(head, then: more)
    }
}
