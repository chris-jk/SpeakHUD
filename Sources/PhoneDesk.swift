import Foundation
import ImageIO

/// phone.json. `token` is what a paired phone holds: it opens the page, and the page
/// types into your terminals. It never goes in the log.
struct PhoneConfig: Equatable {
    static let defaultPort: UInt16 = 4778
    static var path: String { NSString(string: "~/.config/speakhud/phone.json").expandingTildeInPath }

    var port = PhoneConfig.defaultPort
    var token: String
    /// How the phone reaches the page ("https://my-mac.my-tailnet.ts.net"). Pushes link here.
    var url: String? = nil
    /// The ntfy topic pushes go to ("https://ntfy.example.com/terminals"), and its access token.
    var ntfy: String? = nil
    var ntfyToken: String? = nil

    static func newToken() -> String {
        // The system's secure generator; SecRandomCopyBytes could fail and leave all zeros.
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /// nil when the file is missing or its token is no good: the page stays off rather
    /// than open. Anything else that doesn't look right is left out.
    static func load(_ path: String = PhoneConfig.path) -> PhoneConfig? {
        guard let data = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = o["token"] as? String, token.count >= 32,
              token.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        else { return nil }
        var c = PhoneConfig(token: token)
        if let p = o["port"] as? NSNumber, CFGetTypeID(p) != CFBooleanGetTypeID(),
           p.doubleValue == p.doubleValue.rounded(), (1024...65535).contains(p.intValue) {
            c.port = UInt16(p.intValue)
        }
        c.url = web(o["url"])
        c.ntfy = web(o["ntfy"])
        if let t = o["ntfy_token"] as? String, !t.isEmpty { c.ntfyToken = t }
        return c
    }

    /// An http(s) address with a host, without its trailing slash.
    static func web(_ raw: Any?) -> String? {
        guard var s = raw as? String, let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", u.host?.isEmpty == false else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Written for you alone (0600): it holds the token and the push server's.
    @discardableResult
    func save(to path: String = PhoneConfig.path) -> Bool {
        var o: [String: Any] = ["port": Int(port), "token": token]
        if let url = url { o["url"] = url }
        if let ntfy = ntfy { o["ntfy"] = ntfy }
        if let t = ntfyToken { o["ntfy_token"] = t }
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]),
              var text = String(data: data, encoding: .utf8) else { return false }
        text = text.replacingOccurrences(of: "\\/", with: "/") + "\n"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard fm.createFile(atPath: path, contents: text.data(using: .utf8), attributes: [.posixPermissions: 0o600])
        else { return false }
        return (try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)) != nil
    }

    /// The link that pairs a phone: opened once, it leaves the token there as a cookie.
    var pairLink: String? { url.map { "\($0)/pair?k=\(token)" } }
}

/// Pictures, video and sound for the phone to show under a turn: files the turn made or
/// named, found by the hook (`turn_media` in read-summary.py). The page never names a
/// path. It asks for a turn's nth file, and only a file of these kinds is ever sent.
enum PhoneMedia {
    static let limit = 12   // MAX_MEDIA in the hook
    /// By extension: what the page does with it, and what it's sent as. Must match
    /// MEDIA_EXT in the hook (tests/PhoneTests.swift pins both).
    static let types: [String: (kind: String, type: String)] = [
        "png": ("image", "image/png"), "jpg": ("image", "image/jpeg"), "jpeg": ("image", "image/jpeg"),
        "gif": ("image", "image/gif"), "webp": ("image", "image/webp"), "heic": ("image", "image/heic"),
        "svg": ("image", "image/svg+xml"),
        "mp4": ("video", "video/mp4"), "m4v": ("video", "video/x-m4v"), "mov": ("video", "video/quicktime"),
        "webm": ("video", "video/webm"),
        "mp3": ("audio", "audio/mpeg"), "m4a": ("audio", "audio/mp4"), "wav": ("audio", "audio/wav"),
        "aac": ("audio", "audio/aac"),
        "pdf": ("file", "application/pdf")]
    /// A picture is sent smaller than it is, for a phone on a slow line, unless it's
    /// already light or would lose something by it (a GIF its movement, an SVG its lines).
    static let lightEnough: UInt64 = 300_000
    static let keptWhole: Set<String> = ["gif", "svg"]
    /// Not every browser draws one of these, so it always goes as the smaller copy.
    static let alwaysRedrawn: Set<String> = ["heic"]

    static func sendsSmaller(_ file: File) -> Bool {
        let kind = ext(file.path)
        return file.kind == "image" && !keptWhole.contains(kind) && (file.size > lightEnough || alwaysRedrawn.contains(kind))
    }

    struct File: Equatable {
        let path: String      // where it really is, links followed
        let size: UInt64
        let changed: Date
        let kind: String
        let type: String
        var name: String { (path as NSString).lastPathComponent }
        /// Changes when the file does, so the phone never shows a kept copy of the last one.
        var version: String {
            var h: UInt64 = 0xcbf29ce484222325
            for byte in "\(path)|\(changed.timeIntervalSince1970)|\(size)".utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
            return String(h, radix: 16)
        }
    }

    static func ext(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }

    /// From the spool's `media`, or the list kept between runs: absolute paths of a kind
    /// the page shows, no more than `limit`.
    static func parse(_ json: Any?) -> [String] {
        var out: [String] = []
        for raw in json as? [Any] ?? [] {
            guard let path = TextLink.absolutePath(raw), types[ext(path)] != nil, !out.contains(path) else { continue }
            out.append(path)
            if out.count == limit { break }
        }
        return out
    }

    /// `path` as it is now: nil once it's gone, or if it leads to anything but a file of
    /// one of these kinds (a link is followed, and what it leads to is what's judged).
    static func file(_ path: String) -> File? {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let type = types[ext(real)], let found = try? FileManager.default.attributesOfItem(atPath: real),
              found[.type] as? FileAttributeType == .typeRegular, let size = (found[.size] as? NSNumber)?.uint64Value
        else { return nil }
        return File(path: real, size: size, changed: found[.modificationDate] as? Date ?? .distantPast,
                    kind: type.kind, type: type.type)
    }

    /// The picture at `path` no more than `side` pixels a side: a JPEG, or a PNG when it
    /// has see-through parts. nil if it can't be read as a picture.
    static func small(_ path: String, side: Int) -> (data: Data, type: String)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: side]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let opaque: [CGImageAlphaInfo] = [.none, .noneSkipFirst, .noneSkipLast]
        let clear = !opaque.contains(image.alphaInfo)
        let out = NSMutableData()
        guard let to = CGImageDestinationCreateWithData(out, (clear ? "public.png" : "public.jpeg") as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(to, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(to) else { return nil }
        return (out as Data, clear ? "image/png" : "image/jpeg")
    }

    /// "2 pictures", "1 video", "3 files": what a push says came with a turn.
    static func said(_ paths: [String]) -> String? {
        let kinds = Set(paths.compactMap { types[ext($0)]?.kind })
        guard !paths.isEmpty, let kind = kinds.first else { return nil }
        let word = kinds.count > 1 ? "file" : ["image": "picture", "video": "video", "audio": "recording"][kind] ?? "file"
        return "\(paths.count) \(word)\(paths.count == 1 ? "" : "s")"
    }
}

/// What the page shows: the last turn of each terminal, the newest first.
struct PhoneDesk {
    static let keep = 30
    /// The question hook's key is its session's with this on the end (read-question.py).
    static let questionSuffix = ":question"
    /// A question comes in pieces (the question, a pause, its options). Pieces this
    /// close together are one box; later than that it's the next question.
    static let questionGap: TimeInterval = 90

    struct Turn: Equatable {
        let key: String              // the session: one terminal
        var name: String
        var text: String             // its last finished turn, as read aloud
        var at: Date
        var origin: Origin?
        var question: String? = nil  // a question box it has up, with its options
        var askedAt: Date? = nil
        var sent: String? = nil      // what the phone last sent it, until its next turn
        var note: String? = nil      // why a send didn't go
        var box: TerminalBox? = nil  // what its screen is asking right now, if anything
        var busy = false             // in the middle of a turn
        var doing: String? = nil     // and the newest thing it's put on its screen in it
        var status: String? = nil    // its status line as last seen: folder, model, context
        var context: Int? = nil      // how full its context is, in percent, if the line says
        var media: [String] = []     // pictures, video and sound that turn made or named
    }

    /// A terminal seen open that hasn't finished a turn since it was first seen: its key
    /// is this and its pane's id, until a turn of its own replaces it.
    static let paneKey = "pane:"
    /// A saved turn older than this isn't brought back.
    static let maxAge: TimeInterval = 7 * 86_400

    private(set) var turns: [Turn] = []

    init() {}

    func turn(_ key: String) -> Turn? { turns.first { $0.key == key } }

    /// Bring the list in line with the panes iTerm2 has `open`: a closed terminal's turn
    /// goes; an open one running Claude Code that has no turn here yet gets an empty
    /// window; and each is marked with whether it's working and what box, if any, its
    /// screen is showing. Returns the keys whose box has just come up.
    @discardableResult
    mutating func met(_ open: [Reply.Pane], now: Date = Date()) -> [String] {
        let ids = Set(open.map { $0.session })
        turns.removeAll { $0.origin?.session.map { !ids.contains($0) } ?? false }
        var asking: [String] = []
        for pane in open {
            let showing = pane.showing
            let box = showing.box, busy = showing.busy
            let doing = busy ? Reply.doing(pane.screen) : nil
            if let i = turns.firstIndex(where: { $0.origin?.session == pane.session }) {
                if turns[i].key.hasPrefix(Self.paneKey) { turns[i].name = Reply.paneName(pane.name) }
                if let box = box, turns[i].box?.ask != box.ask { asking.append(turns[i].key) }
                (turns[i].box, turns[i].busy, turns[i].doing) = (box, busy, doing)
                if let prompt = showing.prompt, let status = prompt.status { (turns[i].status, turns[i].context) = (status, prompt.context) }
            } else if showing.isClaude, turns.count < Self.keep {
                var t = Turn(key: Self.paneKey + pane.session, name: Reply.paneName(pane.name), text: "", at: now,
                             origin: Origin(term: "iTerm.app", session: pane.session))
                (t.box, t.busy, t.doing) = (box, busy, doing)
                if let prompt = showing.prompt, let status = prompt.status { (t.status, t.context) = (status, prompt.context) }
                if box != nil { asking.append(t.key) }
                turns.append(t)
            }
        }
        return asking
    }

    /// A fresh look at one terminal's screen: what box it shows now. A hook's question
    /// is over once the screen is back at Claude's prompt.
    mutating func saw(_ key: String, _ screen: String) {
        guard let i = turns.firstIndex(where: { $0.key == key }) else { return }
        let showing = Reply.showing(screen)
        turns[i].box = showing.box
        if turns[i].box != nil { (turns[i].busy, turns[i].doing) = (false, nil) }
        if let prompt = showing.prompt, let status = prompt.status { (turns[i].status, turns[i].context) = (status, prompt.context) }
        if turns[i].question != nil, showing.prompt != nil { (turns[i].question, turns[i].askedAt) = (nil, nil) }
    }

    /// The list as it's kept between runs of the agent.
    func snapshot() -> Data {
        let rows = turns.map { t -> [String: Any] in
            var o: [String: Any] = ["key": t.key, "name": t.name, "text": t.text, "at": t.at.timeIntervalSince1970]
            if let origin = t.origin { o["origin"] = origin.json }
            if let q = t.question { o["question"] = q }
            if let a = t.askedAt { o["asked_at"] = a.timeIntervalSince1970 }
            if let sent = t.sent { o["sent"] = sent }
            if let note = t.note { o["note"] = note }
            if let status = t.status { o["status"] = status }
            if let context = t.context { o["context"] = context }
            if !t.media.isEmpty { o["media"] = t.media }
            return o
        }
        return (try? JSONSerialization.data(withJSONObject: ["v": 1, "turns": rows])) ?? Data()
    }

    /// From `snapshot()`. Anything unreadable or too old is left behind.
    init(snapshot: Data?, now: Date = Date()) {
        guard let data = snapshot, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = o["turns"] as? [[String: Any]] else { return }
        for row in rows.prefix(Self.keep) {
            guard let key = row["key"] as? String, let name = row["name"] as? String, let text = row["text"] as? String,
                  let at = (row["at"] as? NSNumber)?.doubleValue, now.timeIntervalSince1970 - at < Self.maxAge,
                  !turns.contains(where: { $0.key == key }) else { continue }
            var t = Turn(key: key, name: name, text: text, at: Date(timeIntervalSince1970: at), origin: Origin(json: row["origin"]))
            t.question = row["question"] as? String
            t.askedAt = (row["asked_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            t.sent = row["sent"] as? String
            t.note = row["note"] as? String
            t.status = row["status"] as? String
            t.context = (row["context"] as? NSNumber)?.intValue
            t.media = PhoneMedia.parse(row["media"])
            turns.append(t)
        }
    }

    /// Whether `item` is a turn's first word: a finished turn, or the first piece of a
    /// question. (Its options follow by themselves and shouldn't ping twice.)
    @discardableResult
    mutating func took(_ item: SpeechItem, now: Date = Date()) -> Bool {
        let asking = item.key.hasSuffix(Self.questionSuffix)
        let key = asking ? String(item.key.dropLast(Self.questionSuffix.count)) : item.key
        var first = true
        var t: Turn
        if asking {
            t = turn(key) ?? Turn(key: key, name: item.source, text: "", at: now, origin: item.origin)
            if let had = t.question, let at = t.askedAt, now.timeIntervalSince(at) < Self.questionGap {
                t.question = had + "\n\n" + item.text
                first = false
            } else {
                t.question = item.text
            }
            t.askedAt = now
            t.origin = item.origin ?? t.origin
            (t.sent, t.note) = (nil, nil)
            // What the turn has made so far comes with its question ("which of these?").
            if !item.media.isEmpty { t.media = item.media }
        } else {
            t = Turn(key: key, name: item.source, text: item.text, at: now, origin: item.origin)
            t.media = item.media
            // What was last read off its pane's screen still stands.
            if let was = turns.first(where: { $0.origin?.session != nil && $0.origin?.session == item.origin?.session }) {
                (t.status, t.context) = (was.status, was.context)
            }
        }
        // Its own turn takes the place of the empty window its pane had.
        turns.removeAll { $0.key == key || ($0.key.hasPrefix(Self.paneKey) && $0.origin?.session != nil
                                            && $0.origin?.session == item.origin?.session) }
        turns.insert(t, at: 0)
        if turns.count > Self.keep { turns.removeLast(turns.count - Self.keep) }
        return first
    }

    /// Its question box has closed: answered here with a key, or at the Mac.
    mutating func questionClosed(_ key: String) {
        guard let i = turns.firstIndex(where: { $0.key == key }) else { return }
        (turns[i].question, turns[i].askedAt) = (nil, nil)
    }

    /// Its terminal has been closed from the phone.
    mutating func closed(_ key: String) { turns.removeAll { $0.key == key } }

    /// The phone sent `text` to `key`, and this is how it went.
    mutating func answered(_ key: String, with text: String, _ outcome: Reply.Outcome) {
        guard let i = turns.firstIndex(where: { $0.key == key }) else { return }
        if outcome == .sent {
            (turns[i].sent, turns[i].note, turns[i].question) = (text, nil, nil)
        } else {
            turns[i].note = outcome.description
        }
    }
}
