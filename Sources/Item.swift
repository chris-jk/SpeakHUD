import Foundation

// ---------------------------------------------------------------------------
// The unit of speech: one thing to read, and where it came from.
// ---------------------------------------------------------------------------

struct SpeechItem {
    let text: String
    let source: String   // a project name, or the frontmost app
    let key: String      // coalescing key: one Claude Code session == one terminal
    let created: Date
    /// The spool file backing this item. Deleted only once the item has actually been
    /// spoken, so an agent restart can't swallow a queue. Nil for hotkey reads and the
    /// standalone reader, which have nothing on disk to recover.
    var file: String? = nil
    /// Where it came from, for clicking the source pill to go back there. Nil when unknown.
    var origin: Origin? = nil
    /// Paths and commands in `text` to make clickable. Only the hook finds these.
    var links: [TextLink] = []
    /// The directory the turn ran in, where a clicked command is typed. Nil when unknown.
    var cwd: String? = nil
    /// Code blocks to show but never speak. Only the hook sends these.
    var blocks: [CodeBlock] = []
    /// A finished Claude Code turn, whose terminal is back at Claude's prompt: an answer
    /// said out loud can go there (Reply). Only the Stop hook says so.
    var answerable = false
    /// The whole reply is "Nothing": kept and shown like any turn, never read aloud.
    var quiet = false
    /// A question box's choices, read out by the question hook: the answer said out loud
    /// after them picks one (`SpokenChoice`), pressed as its number (`Reply.press`).
    struct Choices: Equatable {
        let asked: String      // the question as the hook has it, which says whose box it is
        let options: [String]  // each choice's label, in the box's order: the first is 1
    }
    var choices: Choices? = nil
    /// Pictures, video and sound the turn made or named, for the phone page to show
    /// under it (PhoneMedia). Only the hook finds these.
    var media: [String] = []
}

/// A fenced code block from the turn: never spoken, but shown where it was, with its
/// command lines as links. `at` is a paragraph end in the spoken text (0: before it all).
struct CodeBlock: Equatable {
    let at: Int
    let code: String
    let links: [TextLink]   // ranges within `code`

    /// From the spool's `blocks`. One that doesn't fit the text is left out.
    static func parse(_ json: Any?, in text: String) -> [CodeBlock] {
        guard let list = json as? [Any] else { return [] }
        let length = (text as NSString).length
        var out: [CodeBlock] = []
        for case let o as [String: Any] in list {
            guard let n = o["at"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue >= 0, n.doubleValue <= Double(length), n.doubleValue == n.doubleValue.rounded(),
                  let code = o["code"] as? String, !code.isEmpty, code.utf16.count <= 8000
            else { continue }
            out.append(CodeBlock(at: n.intValue, code: code, links: TextLink.parse(o["links"], in: code)))
        }
        return out
    }
}

/// What the HUD shows for an item: the spoken text with its code blocks put back. The
/// voice and the hook's links count in spoken offsets; a block moves everything at or
/// after its `at` along by its own length, and nothing else moves.
struct Transcript: Equatable {
    let shown: String
    let links: [TextLink]        // the item's and its blocks', in shown offsets
    let code: [NSRange]          // where the blocks landed
    private let inserts: [(at: Int, length: Int)]

    init(_ item: SpeechItem) { self.init(text: item.text, links: item.links, blocks: item.blocks) }

    init(text: String, links: [TextLink] = [], blocks: [CodeBlock] = []) {
        let spoken = text as NSString
        let out = NSMutableString()
        var cursor = 0, inserts: [(at: Int, length: Int)] = [], all: [TextLink] = [], code: [NSRange] = []
        // Sorted, stably, so two blocks in a row keep their order.
        for b in blocks.enumerated().sorted(by: { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }).map(\.element)
        where b.at <= spoken.length {
            out.append(spoken.substring(with: NSRange(location: cursor, length: b.at - cursor)))
            cursor = b.at
            // A block goes in as a paragraph: after the one before it, or ahead of the first.
            let piece = b.at > 0 ? "\n\n" + b.code : b.code + "\n\n"
            let start = out.length + (b.at > 0 ? 2 : 0)
            out.append(piece)
            inserts.append((b.at, (piece as NSString).length))
            code.append(NSRange(location: start, length: (b.code as NSString).length))
            for l in b.links {
                all.append(TextLink(range: NSRange(location: start + l.range.location, length: l.range.length), action: l.action))
            }
        }
        out.append(spoken.substring(from: cursor))
        shown = out as String
        self.inserts = inserts
        self.code = code
        // Spoken ranges never straddle a block: blocks sit between paragraphs.
        func move(_ r: NSRange) -> NSRange {
            NSRange(location: r.location + inserts.filter { $0.at <= r.location }.reduce(0) { $0 + $1.length }, length: r.length)
        }
        self.links = all + links.map { TextLink(range: move($0.range), action: $0.action) }
    }

    /// Where a range of the spoken text is on screen.
    func shown(_ spoken: NSRange) -> NSRange {
        NSRange(location: spoken.location + inserts.filter { $0.at <= spoken.location }.reduce(0) { $0 + $1.length },
                length: spoken.length)
    }

    static func == (a: Transcript, b: Transcript) -> Bool {
        a.shown == b.shown && a.links == b.links && a.code == b.code
    }
}

/// Something in an item's text to click: a file or folder to open, or a command to
/// type into a terminal and leave there, unrun. The hook finds them, since it has
/// Claude's PATH and working directory; URLs the HUD finds itself.
struct TextLink: Equatable {
    enum Action: Equatable { case open(String), load(String) }
    let range: NSRange
    let action: Action

    /// From the spool's `links`, against the text they point into. An entry that
    /// doesn't parse, doesn't fit the text, or overlaps an earlier one is left out.
    static func parse(_ json: Any?, in text: String) -> [TextLink] {
        guard let list = json as? [Any] else { return [] }
        let length = (text as NSString).length
        func count(_ raw: Any?) -> Int? {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue >= 0, n.doubleValue < Double(Int32.max),
                  n.doubleValue == n.doubleValue.rounded() else { return nil }
            return n.intValue
        }
        var out: [TextLink] = []
        for case let o as [String: Any] in list {
            guard let at = count(o["at"]), let len = count(o["len"]), len > 0, at + len <= length
            else { continue }
            let action: Action
            if let path = absolutePath(o["path"]) { action = .open(path) }
            else if let cmd = o["run"] as? String, LoadCommand.isLoadable(cmd) { action = .load(cmd) }
            else { continue }
            let range = NSRange(location: at, length: len)
            if out.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) { continue }
            out.append(TextLink(range: range, action: action))
        }
        return out
    }

    /// An absolute path, one line, of sane length — or nil.
    static func absolutePath(_ raw: Any?) -> String? {
        guard let p = raw as? String, p.hasPrefix("/"), LoadCommand.isLoadable(p) else { return nil }
        return p
    }
}

/// The terminal (or app) an item came from. The hook fills it in from Claude's
/// environment and process tree; hotkey reads record the frontmost app. Every field is
/// validated on the way in, because session and tty end up inside an AppleScript.
struct Origin: Equatable {
    var term: String? = nil     // TERM_PROGRAM: "iTerm.app", "Apple_Terminal", "vscode", …
    var session: String? = nil  // iTerm2 session id (the UUID in ITERM_SESSION_ID)
    var tty: String? = nil      // "/dev/ttys002"
    var appPID: pid_t? = nil    // the GUI app hosting the terminal
    var color: String? = nil    // "#rrggbb", the terminal's window frame, for the pill to match

    init(term: String? = nil, session: String? = nil, tty: String? = nil, appPID: pid_t? = nil,
         color: String? = nil) {
        self.term = term; self.session = session; self.tty = tty; self.appPID = appPID
        self.color = color
    }

    /// From the spool's `origin` object, or `--origin` JSON. A field that doesn't look
    /// right is left out rather than trusted; nothing usable at all is nil.
    init?(json: Any?) {
        guard let o = json as? [String: Any] else { return nil }
        if let t = o["term"] as? String, !t.isEmpty, t.count <= 64 { term = t }
        if let s = o["session"] as? String,
           s.range(of: #"^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$"#, options: .regularExpression) != nil {
            session = s
        }
        if let t = o["tty"] as? String,
           t.range(of: #"^/dev/ttys[0-9]{1,5}$"#, options: .regularExpression) != nil {
            tty = t
        }
        if let n = o["app_pid"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
           n.doubleValue > 1, n.doubleValue < Double(Int32.max), n.doubleValue == n.doubleValue.rounded() {
            appPID = pid_t(n.int32Value)
        }
        if let c = o["color"] as? String,
           c.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil {
            color = c.lowercased()
        }
        if session == nil, tty == nil, appPID == nil { return nil }
    }

    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        self.init(json: try? JSONSerialization.jsonObject(with: data))
    }

    /// As `init(json:)` reads it back.
    var json: [String: Any] {
        var o: [String: Any] = [:]
        if let term = term { o["term"] = term }
        if let session = session { o["session"] = session }
        if let tty = tty { o["tty"] = tty }
        if let appPID = appPID { o["app_pid"] = Int(appPID) }
        if let color = color { o["color"] = color }
        return o
    }
}
