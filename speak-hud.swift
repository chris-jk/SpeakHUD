import Cocoa
import AVFoundation
import Speech
import ApplicationServices
import Carbon.HIToolbox
import CoreAudio
import Network
import ImageIO

// Shared prefs domain so the speed setting is the same no matter how the reader
// was launched (double-click app, Claude Code hook, or the global hotkey).
// NB: the suite name must NOT equal the app's bundle id, or macOS rejects it.
let prefs = UserDefaults(suiteName: "com.chris.speakhud.shared") ?? .standard

// Text source priority: explicit arg → piped stdin (the Claude Code hook) →
// clipboard. The clipboard fallback is what makes the .app useful when launched
// on its own (double-click / Spotlight / a hotkey), where there's no stdin pipe.
func resolveText(_ args: [String]) -> String {
    var i = 1
    while i < args.count {
        let a = args[i]
        if a == "--source" || a == "--origin" { i += 2; continue }   // flag + its value
        if a.hasPrefix("--") { i += 1; continue }
        if !a.isEmpty { return a }
        i += 1
    }
    // Only drain stdin when it's a pipe/file; reading an interactive TTY would block.
    if isatty(FileHandle.standardInput.fileDescriptor) == 0 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        if let s = String(data: data, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
    }
    return NSPasteboard.general.string(forType: .string) ?? ""
}

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

// Clicking the source pill: bring the terminal that's talking to the front, on
// whichever desktop it's on. iTerm2 and Terminal.app are asked by AppleScript for the
// exact pane or tab; anything else gets its app activated.
enum Reveal {
    static let iTerm = "com.googlecode.iterm2"
    static let terminal = "com.apple.Terminal"

    /// How both scripts keep hold of the window they found. The loop's `w` is "window N",
    /// counted from the front, and bringing a window forward makes it window 1: from then
    /// on `w`, and any tab or session reached through it, is whichever window was in
    /// front before. `win` finds it by id every time it's used.
    private static let holdWindow = """
    set wid to id of w
    set win to a reference to (first window whose id is wid)
    """

    /// How both scripts answer once they've picked the window `win`: "ok", then its
    /// bounds if it will give them, so the HUD can point at it (Spotlight).
    private static let replyWithBounds = """
    try
        set b to bounds of win
        return "ok " & (item 1 of b) & " " & (item 2 of b) & " " & (item 3 of b) & " " & (item 4 of b)
    end try
    return "ok"
    """

    /// The window's bounds out of a script's reply, as AppleScript counts them: left,
    /// top, right, bottom, down from the top of the main screen. Nil for a bare "ok".
    static func bounds(inReply reply: String?) -> NSRect? {
        let parts = (reply ?? "").split(separator: " ")
        guard parts.count == 5, parts[0] == "ok" else { return nil }
        let n = parts.dropFirst().compactMap { Double($0) }
        guard n.count == 4, n[2] > n[0], n[3] > n[1] else { return nil }
        return NSRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1])
    }

    /// The AppleScript that selects the pane `origin` names, and the app it talks to.
    /// Nil when it can't name one. Only validated ids and ttys are ever interpolated.
    static func script(for origin: Origin) -> (bundleID: String, source: String)? {
        let term = origin.term ?? ""
        if term == "iTerm.app" || (term.isEmpty && origin.session != nil) {
            let test: String
            if let s = origin.session { test = "(id of s) is \"\(s)\"" }
            else if let t = origin.tty { test = "(tty of s) is \"\(t)\"" }
            else { return nil }
            // Activate first, then select. Activating lands on whatever desktop iTerm2
            // already has a window on; only a window brought forward by an app that's
            // already active pulls macOS over to the desktop that window is on.
            return (iTerm, """
            tell application id "\(iTerm)"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if \(test) then
                                \(holdWindow)
                                select t
                                select s
                                select win
                                \(replyWithBounds)
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "missing"
            """)
        }
        if term == "Apple_Terminal", let tty = origin.tty {
            return (terminal, """
            tell application id "\(terminal)"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        if (tty of t) is "\(tty)" then
                            \(holdWindow)
                            set selected of t to true
                            set index of win to 1
                            \(replyWithBounds)
                        end if
                    end repeat
                end repeat
            end tell
            return "missing"
            """)
        }
        return nil
    }

    enum Outcome: Equatable, CustomStringConvertible {
        case pane(NSRect?) // the exact pane or tab, and its window's bounds if known
        case app           // only its app
        case gone          // the terminal or app has since closed
        case denied        // Automation permission refused
        case failed(String)

        var description: String {
            switch self {
            case .pane: return "went to its terminal"
            case .app: return "activated its app"
            case .gone: return "its terminal is gone"
            case .denied: return "not allowed to control the terminal — grant it in System Settings › Privacy & Security › Automation › SpeakHUD"
            case .failed(let why): return "failed: \(why)"
            }
        }
    }

    static func go(_ origin: Origin) -> Outcome {
        if let (bundleID, source) = script(for: origin) {
            // `tell application` would launch a terminal that's been quit. Don't.
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                if #available(macOS 14.0, *) { NSApp.yieldActivation(to: app) }
                var err: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
                if let err = err {
                    let code = err[NSAppleScript.errorNumber] as? Int ?? 0
                    if code == -1743 { return .denied }   // errAEEventNotPermitted
                    let msg = err[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code)"
                    return .failed(msg)
                }
                if let reply = result?.stringValue, reply.hasPrefix("ok") {
                    app.activate(options: [])   // belt and braces: the script's own activate
                    return .pane(bounds(inReply: reply))   // can lose out to activation rules on macOS 14+
                }
                // Pane closed; fall through to whatever app is left.
            }
        }
        if let pid = origin.appPID, let app = NSRunningApplication(processIdentifier: pid),
           !app.isTerminated, app.activationPolicy == .regular {
            if #available(macOS 14.0, *) { NSApp.yieldActivation(to: app) }
            return app.activate(options: []) ? .app : .failed("activate refused")
        }
        return .gone
    }
}

// Clicking a path in the transcript. A folder is shown selected in the folder above it,
// so you see where it lives and can still click in. A file opens in its default app —
// unless that app would run it rather than show it (a script or bare executable opens
// in Terminal and executes), in which case Finder shows it instead. A path that's gone
// opens the nearest folder above it that's still there.
enum OpenPath {
    enum Plan: Equatable { case open(String), reveal(String) }

    /// Default apps that execute what they're handed.
    static let runners: Set<String> = [Reveal.terminal, Reveal.iTerm, "org.python.PythonLauncher"]

    static func plan(_ path: String, defaultApp: (URL) -> String? = OpenPath.defaultApp) -> Plan {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        var p = (path as NSString).standardizingPath
        if fm.fileExists(atPath: p, isDirectory: &isDir) {
            if isDir.boolValue { return .reveal(p) }
            // No default app at all would put up a "choose an app" dialog; Finder is kinder.
            guard let app = defaultApp(URL(fileURLWithPath: p)), !runners.contains(app) else { return .reveal(p) }
            return .open(p)
        }
        while p != "/" {
            p = (p as NSString).deletingLastPathComponent
            if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { return .open(p) }
        }
        return .open("/")
    }

    static func defaultApp(_ url: URL) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    @discardableResult
    static func go(_ path: String) -> Plan {
        let plan = plan(path)
        switch plan {
        case .open(let p): NSWorkspace.shared.open(URL(fileURLWithPath: p))
        case .reveal(let p): NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        }
        return plan
    }
}

// Clicking a command in the transcript: a new iTerm2 window opens in the turn's working
// directory with the command typed at the prompt, waiting for Return. `write text …
// newline no` types without pressing it. Without iTerm2 the command goes on the
// clipboard and Terminal opens there instead: Terminal's `do script` can only run things.
enum LoadCommand {
    /// One line with nothing a terminal would take as a keypress of its own — a newline
    /// would run it, an escape could do anything.
    static func isLoadable(_ s: String) -> Bool {
        !s.trimmingCharacters(in: .whitespaces).isEmpty && s.utf16.count <= 1000
            && !s.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }

    /// An AppleScript string literal of `s`, which must already be isLoadable.
    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func script(_ command: String, cwd: String?) -> String? {
        guard isLoadable(command) else { return nil }
        var cd = ""
        if let cwd = cwd, isLoadable(cwd) {
            cd = "write text \(literal("cd " + shellQuote(cwd) + " && clear"))"
        }
        return """
        tell application id "\(Reveal.iTerm)"
            activate
            set w to (create window with default profile)
            tell current session of w
                \(cd)
                write text \(literal(command)) newline no
            end tell
        end tell
        """
    }

    enum Outcome: Equatable, CustomStringConvertible {
        case loaded        // typed into a new iTerm2 window
        case copied        // no iTerm2: on the clipboard, Terminal opened
        case denied
        case failed(String)

        var description: String {
            switch self {
            case .loaded: return "typed into a new iTerm2 window"
            case .copied: return "copied, Terminal opened (no iTerm2)"
            case .denied: return "not allowed to control iTerm2 — grant it in System Settings › Privacy & Security › Automation › SpeakHUD"
            case .failed(let why): return "failed: \(why)"
            }
        }
    }

    static func go(_ command: String, cwd: String?) -> Outcome {
        var isDir: ObjCBool = false
        let dir = cwd.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue ? $0 : nil }
        let ws = NSWorkspace.shared
        if ws.urlForApplication(withBundleIdentifier: Reveal.iTerm) != nil {
            guard let source = script(command, cwd: dir) else { return .failed("not a single line") }
            if #available(macOS 14.0, *),
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: Reveal.iTerm).first {
                NSApp.yieldActivation(to: app)
            }
            var err: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&err)
            if let err = err {
                let code = err[NSAppleScript.errorNumber] as? Int ?? 0
                if code == -1743 { return .denied }   // errAEEventNotPermitted
                return .failed(err[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code)")
            }
            return .loaded
        }
        guard isLoadable(command) else { return .failed("not a single line") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        if let terminal = ws.urlForApplication(withBundleIdentifier: Reveal.terminal) {
            ws.open([URL(fileURLWithPath: dir ?? NSHomeDirectory())], withApplicationAt: terminal,
                    configuration: NSWorkspace.OpenConfiguration())
        }
        return .copied
    }
}

// Answering a turn out loud: what was heard goes into the prompt of the terminal that
// spoke, and Return is pressed once it shows there. iTerm2 only, which can be asked for
// a pane's screen and written to by AppleScript without coming forward.
//
// Pasted, never typed. A question or permission box takes a typed digit as its answer
// on the spot, and ignores a paste (both tried against Claude Code 2.1.293: a typed "2"
// picked the second option, a pasted "2" did nothing). So the words go in as a bracketed
// paste, only into a pane whose screen shows Claude's prompt box and no such box, and
// Return follows only when the prompt box then shows them. It counts as sent once they
// have left the box again.
enum Reply {
    static let maxLength = 4000
    /// How often, and how far apart, the screen is read again for the paste to show.
    static let looks = 8
    static let lookGap: TimeInterval = 0.1

    /// Whether an item from `origin` can be answered: an iTerm2 pane, by its id.
    static func canReach(_ origin: Origin?) -> Bool {
        guard let o = origin, o.session != nil else { return false }
        let term = o.term ?? ""
        return term == "iTerm.app" || term.isEmpty
    }

    /// What was heard as one line a terminal can take: no line breaks or control
    /// characters (either could be a keypress, or end the paste early), space closed up,
    /// and nothing ahead of the first word that Claude's prompt would take as a mode
    /// ("!" runs a shell command, "/" a slash command). Nil if nothing is left.
    static func clean(_ heard: String) -> String? {
        let breaks = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        var line = heard.components(separatedBy: breaks).filter { !$0.isEmpty }.joined(separator: " ")
        while let first = line.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first),
              first != "\"", first != "'", first != "(" {
            line = String(line.unicodeScalars.dropFirst())
            line = line.trimmingCharacters(in: .whitespaces)
        }
        return line.isEmpty ? nil : String(line.prefix(maxLength))
    }

    /// What a box that takes keys as answers says about itself.
    static let boxHints = ["Esc to cancel", "Enter to select", "Enter to confirm", "(esc)"]

    private static func isRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("─") && t.hasSuffix("─") && t.filter({ $0 == "─" }).count >= 10
    }

    /// What Claude Code's prompt box holds, if `screen` (a pane's visible text) shows one
    /// that would take a paste as a message: a line starting "❯" with a rule right above
    /// it and a rule below, after any wrapped lines. Nil for anything else, and then
    /// nothing is pasted: a question or permission box (their options sit under the
    /// question, not under a rule, and say how to answer underneath), shell mode ("!"),
    /// a pane that isn't running Claude at all.
    static func promptText(in screen: String) -> String? {
        let lines = screen.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
        guard let bottom = lines.lastIndex(where: isRule) else { return nil }
        // A box that takes keys as answers says so under itself.
        let under = lines[(bottom + 1)...].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if under.contains(where: { l in boxHints.contains { l.contains($0) } }) { return nil }
        // The prompt box sits at the foot of the screen, over a status line or two. A
        // rule with more than that under it belongs to something else.
        guard under.count <= 5 else { return nil }
        var top = bottom - 1
        while top >= 0, !lines[top].hasPrefix("❯"), !isRule(lines[top]) { top -= 1 }
        guard top >= 1, lines[top].hasPrefix("❯"), isRule(lines[top - 1]) else { return nil }
        var parts = [String(lines[top].dropFirst())]
        parts += lines[(top + 1)..<bottom]
        let text = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
        // "1. Yes": an option list that happens to sit between rules is still not a prompt.
        if text.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil { return nil }
        return text
    }

    /// Whether the prompt box now holds what was pasted and nothing ahead of it: it
    /// starts with the first stretch of it (wrapping aside), or, for a long paste, with
    /// the marker Claude Code folds one into. Text you had already typed there fails
    /// this, and Return is left to you.
    ///
    /// A picture's path doesn't stay in the words: Claude Code takes it out and puts
    /// "[Image #1]" at the front of the box instead (seen in 2.1.294: a paste of
    /// "Look at this picture from my phone: /…/a.jpg" shows as "[Image #1]Look at this
    /// picture from my phone:"). So those markers at the front aren't something typed
    /// ahead, and the paths aren't looked for.
    static func shows(_ text: String, inPrompt box: String) -> Bool {
        func squash(_ s: String) -> String { String(s.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }) }
        let words = text.replacingOccurrences(of: #"\s?/\S+\.(?:jpe?g|png|gif|webp|heic)(?=\s|$)"#, with: "",
                                              options: [.regularExpression, .caseInsensitive])
        let held = box.replacingOccurrences(of: #"^(\s*\[Image #\d+\])+"#, with: "", options: .regularExpression)
        let want = squash(words), have = squash(held)
        guard !want.isEmpty else { return false }
        return have.hasPrefix(String(want.prefix(40))) || have.hasPrefix("[Pastedtext#")
    }

    /// What iTerm2 said to one script: its reply, or the AppleScript error.
    struct Answer: Equatable {
        var reply: String? = nil
        var errorCode: Int? = nil
        var errorMessage: String? = nil
    }

    /// An AppleScript that finds the pane `session` and does `action` with it as `s`.
    /// `action` ends by returning something starting "ok"; "missing" comes back when the
    /// pane is gone. Only a validated id (Origin) and a cleaned line are ever put in.
    static func script(_ session: String, _ action: String) -> String {
        """
        tell application id "\(Reveal.iTerm)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (id of s) is "\(session)" then
                            \(action)
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    static func screenScript(_ session: String) -> String {
        script(session, "return \"ok\" & linefeed & (contents of s)")
    }

    /// The line as a bracketed paste: Claude's prompt takes it as one paste, and a box
    /// that answers to keys doesn't take it at all.
    static func pasteScript(_ session: String, _ line: String) -> String {
        script(session, """
        tell s to write text ((character id 27) & "[200~" & \(LoadCommand.literal(line)) & (character id 27) & "[201~") newline no
                            return "ok"
        """)
    }

    /// Return, as the key sends it (a carriage return; a line feed is Claude's "new line").
    static func returnScript(_ session: String) -> String {
        script(session, """
        tell s to write text (character id 13) newline no
                            return "ok"
        """)
    }

    /// What the phone's key buttons send: the bytes the keys send themselves.
    static let keys: [String: [Int]] = [
        "enter": [13], "esc": [27], "tab": [9], "space": [32],
        "up": [27, 91, 65], "down": [27, 91, 66],
        "1": [49], "2": [50], "3": [51], "4": [52], "5": [53], "6": [54], "7": [55], "8": [56], "9": [57],
    ]

    static func keyScript(_ session: String, _ codes: [Int]) -> String {
        let chars = codes.map { "(character id \($0))" }.joined(separator: " & ")
        return script(session, """
        tell s to write text (\(chars)) newline no
                            return "ok"
        """)
    }

    /// Press one named key in the pane `origin` names: how a question or permission
    /// box, which takes no paste, is answered from the phone.
    static func press(_ key: String, in origin: Origin, ask: (String) -> Answer = Reply.ask) -> Outcome {
        guard canReach(origin), let session = origin.session else { return .gone }
        guard let codes = keys[key] else { return .failed("no such key") }
        let a = ask(keyScript(session, codes))
        if let code = a.errorCode {
            return code == -1743 ? .denied : .failed(a.errorMessage ?? "AppleScript error \(code)")
        }
        return a.reply?.hasPrefix("ok") == true ? .sent : .gone
    }

    /// The foot of the pane's screen as text, for the phone to show. Nil when it's gone.
    static func screen(of origin: Origin, lines: Int = 40, ask: (String) -> Answer = Reply.ask) -> String? {
        guard canReach(origin), let session = origin.session,
              let reply = ask(screenScript(session)).reply, reply.hasPrefix("ok") else { return nil }
        return foot(String(reply.dropFirst(2)), lines: lines)
    }

    /// A pane iTerm2 has open: its id, its title, and the foot of its screen.
    struct Pane: Equatable {
        var session: String
        var name: String
        var screen: String
    }

    /// Every pane, in one ask. The separators are control characters spelled as
    /// character ids: a title or a screen can hold anything else, and inside iTerm2's
    /// `tell` the word `tab` means one of its tabs.
    static let surveyScript = """
        tell application id "\(Reveal.iTerm)"
            set out to "ok"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set out to out & (character id 30) & (id of s) & (character id 31) & (name of s) & (character id 31) & (contents of s)
                    end repeat
                end repeat
            end repeat
            return out
        end tell
        """

    /// The open panes, or nil when iTerm2 isn't running or won't say (then nothing is
    /// known, which is not the same as nothing being open).
    static func survey(ask: (String) -> Answer = Reply.ask) -> [Pane]? {
        guard let reply = ask(surveyScript).reply, reply.hasPrefix("ok") else { return nil }
        return reply.components(separatedBy: "\u{1E}").dropFirst().compactMap { record in
            let fields = record.components(separatedBy: "\u{1F}")
            guard fields.count == 3, Origin(json: ["session": fields[0]]) != nil else { return nil }
            return Pane(session: fields[0], name: fields[1], screen: foot(fields[2]))
        }
    }

    /// The last `lines` lines of a screen, without the blank ones under them.
    static func foot(_ contents: String, lines: Int = 40) -> String {
        let all = contents.components(separatedBy: .newlines)
        var end = all.count
        while end > 0, all[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return all[max(0, end - lines)..<end].joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// Whether a pane is in the middle of a turn. Claude Code spins a glyph at the front
    /// of the title while it works and leaves ✳ there when it's waiting for you.
    static func working(title: String, screen: String) -> Bool {
        if screen.contains("esc to interrupt") { return true }
        let name = title.replacingOccurrences(of: "\u{00A0}", with: " ")
        guard let first = name.unicodeScalars.first, name.dropFirst().hasPrefix(" ") else { return false }
        return first != "✳" && !CharacterSet.alphanumerics.contains(first)
    }

    /// What Claude Code's status line says under its prompt box (yours to set: a folder,
    /// the model, how full the context is), and the context figure if it gives one.
    /// Nil when the prompt box isn't showing. Whatever sits far to the right of it, a
    /// notice with a gap before it, is left off.
    static func status(in screen: String) -> (line: String, context: Int?)? {
        guard promptText(in: screen) != nil else { return nil }
        let lines = screen.components(separatedBy: .newlines).map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
        guard let rule = lines.lastIndex(where: isRule),
              let raw = lines[(rule + 1)...].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let left = raw.trimmingCharacters(in: .whitespaces).components(separatedBy: "   ").first ?? ""
        let line = left.components(separatedBy: " ").filter { !$0.isEmpty }.joined(separator: " ")
        guard !line.isEmpty else { return nil }
        var context: Int?
        if let m = line.range(of: #"(?i)(ctx|context)\D{0,3}(\d{1,3})\s?%|(\d{1,3})\s?%\s*(ctx|context)"#, options: .regularExpression),
           let n = Int(line[m].filter { $0.isNumber }), (0...100).contains(n) {
            context = n
        }
        return (line, context)
    }

    /// Close the pane: Claude Code is asked to exit first if it's at its prompt (so the
    /// session ends cleanly and iTerm2 has no running job to ask about), then the pane goes.
    static func close(_ origin: Origin, ask: (String) -> Answer = Reply.ask,
                      wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Outcome {
        guard canReach(origin), let session = origin.session else { return .gone }
        if let screen = screen(of: origin, ask: ask), let typed = promptText(in: screen), typed.isEmpty {
            _ = type("/exit", in: origin, ask: ask)
            wait(0.3)
            _ = press("enter", in: origin, ask: ask)
            wait(1.5)
        }
        let a = ask(script(session, """
        tell s to close
                            return "ok"
        """))
        if let code = a.errorCode {
            return code == -1743 ? .denied : .failed(a.errorMessage ?? "AppleScript error \(code)")
        }
        // "missing" here means the pane had already gone when Claude exited: closed all the same.
        return .sent
    }

    /// Type `line` into the pane as keys (not a paste: a question's own text field takes
    /// no paste), with no Return.
    static func type(_ line: String, in origin: Origin, ask: (String) -> Answer = Reply.ask) -> Outcome {
        guard canReach(origin), let session = origin.session else { return .gone }
        let a = ask(script(session, """
        tell s to write text \(LoadCommand.literal(line)) newline no
                            return "ok"
        """))
        if let code = a.errorCode {
            return code == -1743 ? .denied : .failed(a.errorMessage ?? "AppleScript error \(code)")
        }
        return a.reply?.hasPrefix("ok") == true ? .sent : .gone
    }

    /// A pane's title as Claude Code sets it ("✳ Grow guide replies — ~/some/dir"), down
    /// to the name a turn from it goes by.
    static func paneName(_ title: String) -> String {
        var name = title.replacingOccurrences(of: "\u{00A0}", with: " ")   // it's set with no-break spaces
        if let dir = name.range(of: " — ", options: .backwards) { name = String(name[..<dir.lowerBound]) }
        if let first = name.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first),
           let space = name.firstIndex(of: " ") {
            name = String(name[name.index(after: space)...])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? title.trimmingCharacters(in: .whitespaces) : name
    }

    /// Whether `screen` is Claude Code's: at its prompt, working, or showing a box that
    /// takes keys. A pane sitting in a shell isn't one to answer.
    static func showsClaude(_ screen: String) -> Bool {
        promptText(in: screen) != nil || (boxHints + ["esc to interrupt"]).contains { screen.contains($0) }
    }

    enum Outcome: Equatable, CustomStringConvertible {
        case sent
        case notAtPrompt   // nothing pasted: a question or permission box is up, or no prompt in sight
        case unconfirmed   // pasted, but it didn't show at the start of the prompt (Return not pressed), or it's still there after Return
        case gone          // its terminal has closed
        case denied        // Automation permission refused
        case failed(String)

        var description: String {
            switch self {
            case .sent: return "sent"
            case .notAtPrompt: return "its terminal isn't at Claude's prompt"
            case .unconfirmed: return "pasted, but Return is yours to press"
            case .gone: return "its terminal is gone"
            case .denied: return "not allowed to control iTerm2 — grant it in System Settings › Privacy & Security › Automation › SpeakHUD"
            case .failed(let why): return why
            }
        }
    }

    /// Runs a script against iTerm2 if it's running. `tell application` would launch one
    /// that's been quit; a quit iTerm2 has no pane to answer in.
    static func ask(_ source: String) -> Answer {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Reveal.iTerm).isEmpty else {
            return Answer(reply: "missing")
        }
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err = err {
            return Answer(errorCode: err[NSAppleScript.errorNumber] as? Int ?? 0,
                          errorMessage: err[NSAppleScript.errorMessage] as? String)
        }
        return Answer(reply: result?.stringValue)
    }

    /// Paste `heard` into the prompt of the pane `origin` names and press Return.
    /// `ask` and `wait` are the seams tests drive it through.
    static func send(_ heard: String, to origin: Origin,
                     ask: (String) -> Answer = Reply.ask,
                     wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Outcome {
        guard canReach(origin), let session = origin.session else { return .gone }
        guard let line = clean(heard) else { return .failed("nothing to send") }

        /// The pane's screen, or why there isn't one to act on.
        func screen() -> (text: String?, stop: Outcome?) {
            let a = ask(screenScript(session))
            if let code = a.errorCode {
                return (nil, code == -1743 ? .denied : .failed(a.errorMessage ?? "AppleScript error \(code)"))
            }
            guard let reply = a.reply, reply.hasPrefix("ok") else { return (nil, .gone) }
            return (String(reply.dropFirst(2)), nil)
        }
        func done(_ a: Answer) -> Outcome? {
            if let code = a.errorCode {
                return code == -1743 ? .denied : .failed(a.errorMessage ?? "AppleScript error \(code)")
            }
            return a.reply?.hasPrefix("ok") == true ? nil : .gone
        }

        let before = screen()
        if let stop = before.stop { return stop }
        guard promptText(in: before.text ?? "") != nil else { return .notAtPrompt }
        if let stop = done(ask(pasteScript(session, line))) { return stop }
        for _ in 0..<looks {
            wait(lookGap)
            let now = screen()
            if let stop = now.stop { return stop }
            if let box = promptText(in: now.text ?? ""), shows(line, inPrompt: box) {
                if let stop = done(ask(returnScript(session))) { return stop }
                // Sent means gone from the box. Still sitting there, Return didn't take.
                for _ in 0..<looks {
                    wait(lookGap)
                    let after = screen()
                    if let stop = after.stop { return stop }
                    guard let left = promptText(in: after.text ?? ""), shows(line, inPrompt: left) else { return .sent }
                }
                return .unconfirmed
            }
        }
        return .unconfirmed
    }
}

/// The few things said that are for the HUD and not for Claude.
///
/// In a reply window, whole phrases only, and ones you wouldn't say to Claude: a reply
/// taken for a command never arrives, and nothing tells you. (Said to Claude by mistake,
/// "say that again" just gets you an answer.) "Skip", or saying nothing at all, is how
/// you don't reply.
///
/// While a turn is being read nothing you say is for Claude, so the short forms count
/// too: "skip", "later", "again", "pause". They still have to be said on their own.
enum SpokenCommand: Equatable {
    case again     // read it to me once more
    case later     // put it at the end of the line and ask me then
    case skip      // after a turn: no reply, move on now. During one: drop it and move on
    case scratch   // forget what was just heard and listen again a little while (reply window only)
    case pause     // stop talking (this and the two below: while reading only)
    case resume    // carry on
    case stopAll   // stop, and throw the queue away

    /// Said at the end of anything, these throw away all of it: the mic heard something
    /// it wasn't meant to (the room, a video, a thought you've dropped). It then listens
    /// again for a little while, in case you want to say it properly.
    private static let takeBacks = ["scratch that", "clear that", "cancel that", "don't send that",
                                    "never mind", "nevermind"]

    private static let phrases: [String: SpokenCommand] = {
        var table: [String: SpokenCommand] = [:]
        for p in ["say that again", "say it again", "read that again", "read it again", "repeat that",
                  "remind me again", "one more time"] { table[p] = .again }
        for p in ["come back to this", "come back to this later", "come back to that later",
                  "come back to it later", "put this off", "put that off", "put it off",
                  "put this off to the end", "put that off to the end", "put it off to the end",
                  "put off to the end", "ask me later", "remind me later"] { table[p] = .later }
        // "Skip" is the one short form that counts here too: it's the word people reach
        // for when they've nothing to say (Chris's first two tries, 10-07).
        for p in ["no reply", "no answer", "nothing to say", "skip", "skip it", "skip this", "skip that",
                  "skip this part"] { table[p] = .skip }
        for p in takeBacks + ["start over", "clear", "clear it", "don't send"] {
            table[words(p)] = .scratch
        }
        return table
    }()

    /// Said while a turn is being read: the reply window's ways of saying again and
    /// later, and the short ones. "Stop" is a pause, which "go on" undoes; only "stop
    /// everything" throws the queue away.
    private static let reading: [String: SpokenCommand] = {
        var table = phrases.filter { $0.value == .again || $0.value == .later }
        for p in ["again", "repeat", "replay", "start over", "from the top"] { table[p] = .again }
        for p in ["later", "not now"] { table[p] = .later }
        for p in ["skip", "skip it", "skip this", "skip that", "skip this one", "next", "next one",
                  "move on"] { table[p] = .skip }
        for p in ["pause", "stop", "wait", "hold on", "hang on", "quiet", "be quiet"] { table[p] = .pause }
        for p in ["resume", "go on", "continue", "keep going", "carry on", "go ahead"] { table[p] = .resume }
        for p in ["stop everything", "stop all", "clear the queue"] { table[p] = .stopAll }
        return table
    }()
    /// A word of lead-in that doesn't stop a phrase being a command while reading.
    private static let leadIns = ["ok", "okay", "hey", "uh", "um", "and", "so", "please"]

    /// The words alone: lower case, no punctuation, single spaces. The transcriber
    /// re-punctuates as it goes, and "Later." is the same thing said as "later".
    static func words(_ heard: String) -> String {
        heard.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `whileReading`: the voice is mid-turn, so the short forms count, and "okay, skip"
    /// or "skip, please" is still "skip".
    static func parse(_ heard: String, whileReading: Bool = false) -> SpokenCommand? {
        let said = words(heard)
        guard whileReading else {
            if let c = phrases[said] { return c }
            // "…no wait, scratch that" takes back everything before it.
            return takeBacks.contains { said.hasSuffix(" " + words($0)) } ? .scratch : nil
        }
        if let c = reading[said] { return c }
        var bare = said.split(separator: " ").map(String.init)
        if let first = bare.first, leadIns.contains(first) { bare.removeFirst() }
        if bare.last == "please" { bare.removeLast() }
        return reading[bare.joined(separator: " ")]
    }
}

// Claude Code turns arrive as files here rather than as processes, so a finished
// turn can never interrupt one that's already speaking. The hook writes `<name>.tmp`
// and renames it to `<name>.json`, which is atomic within a filesystem — the agent
// therefore never observes a half-written item.
//
// The contract with hook/read-summary.py (pinned by tests/SpoolTests.swift, which runs
// the real Python `enqueue()` against the real `drain`):
//   v        schema version, optional → legacy (read as 1); anything but 1 → dropped,
//            so a newer hook's items are never misread by an older agent
//   text     string, required; blank after trimming → dropped
//   source   string, optional → "Claude Code"
//   key      string, optional → the file stem (unique, so that item never coalesces)
//   created  epoch seconds, optional → the file's mtime (when the hook wrote it);
//            present but not a number → dropped. Either way older than maxAge → dropped.
//   origin   object, optional: {term, session, tty, app_pid}, where the turn came from.
//            Unusable fields are ignored, never a reason to drop the item.
//   links    array, optional: [{at, len, path} | {at, len, run}], UTF-16 ranges of `text`
//            to click — a path to open, a command to type into a terminal. Entries
//            that don't fit are ignored (TextLink.parse).
//   cwd      string, optional: the turn's working directory, where commands are typed.
//   blocks   array, optional: [{at, code, links}], fenced code shown but never spoken —
//            `at` is where in `text` it goes back, `links` as above but within `code`.
//   reply    string, optional: "prompt" when the turn left its terminal waiting at
//            Claude's prompt, so an answer said out loud can be pasted there (Reply).
//            Anything else, or missing, is an item nobody can answer.
// Every dropped item comes back as a `Drop` with its reason, for the agent to log.
//
// Liveness: the agent touches `heartbeatName` in the spool dir at startup and every
// `heartbeatInterval`; the hook queues only while that mtime is fresh, and otherwise
// speaks the turn itself (tests/HookTests.swift pins both sides).
enum Spool {
    static let maxAge: TimeInterval = 600   // a stopped agent shouldn't wake up and read you the backlog
    static let version = 1                  // the `v` this agent reads
    /// Deliberately not .json/.tmp/.taken, so drain and recover never touch it.
    static let heartbeatName = "agent.heartbeat"
    static let heartbeatInterval: TimeInterval = 3
    /// Points both sides at another queue — the hook reads the same variable. For tests;
    /// set it for one side only and the hook writes where nobody reads.
    static let dirEnv = "SPEAKHUD_QUEUE_DIR"
    static var dir: String {
        let override = ProcessInfo.processInfo.environment[dirEnv] ?? ""
        return NSString(string: override.isEmpty ? "~/.local/state/speakhud/queue" : override)
            .expandingTildeInPath
    }

    enum DropReason: Equatable, CustomStringConvertible {
        case malformed        // unreadable, or not a JSON object
        case emptyText        // text missing, not a string, or only whitespace
        case invalidCreated   // created present but not a number
        case tooOld           // waited longer than maxAge
        case staleTmp         // a hook died between writing and renaming
        case unsupportedVersion  // `v` present but not the version this agent reads

        var description: String {
            switch self {
            case .unsupportedVersion: return "unsupported schema version (this agent reads v\(Spool.version)) — update SpeakHUD"
            case .malformed: return "malformed JSON"
            case .emptyText: return "no text"
            case .invalidCreated: return "created is not a number"
            case .tooOld: return "older than \(Int(Spool.maxAge))s"
            case .staleTmp: return "abandoned .tmp"
            }
        }
    }
    struct Drop: Equatable { let name: String; let reason: DropReason }
    struct Batch { var items: [SpeechItem] = []; var dropped: [Drop] = [] }

    static func ensure(_ dir: String = Spool.dir) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    /// Items a previous agent had picked up but never finished speaking — it was
    /// restarted or crashed mid-queue. Hand them back so they get another turn.
    static func recover(in dir: String = Spool.dir) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in names where name.hasSuffix(".taken") {
            let stem = String(name.dropLast(6))
            try? fm.moveItem(atPath: dir + "/" + name, toPath: dir + "/" + stem + ".json")
        }
    }

    /// Take every queued item, in arrival order. A taken item is renamed rather than
    /// deleted, so it still exists on disk until it has actually been spoken; `done()`
    /// is what finally removes it. Also sweeps `.tmp` files older than maxAge: a hook
    /// killed between open and rename leaves one, and nothing else ever would.
    static func drain(in dir: String = Spool.dir, now: Date = Date()) -> Batch {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return Batch() }
        var batch = Batch()
        func mtime(_ path: String) -> Date? {
            (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        for name in names where name.hasSuffix(".tmp") {
            let path = dir + "/" + name
            // Young ones are a hook mid-write; leave those alone.
            guard let m = mtime(path), now.timeIntervalSince(m) >= maxAge,
                  (try? fm.removeItem(atPath: path)) != nil else { continue }
            batch.dropped.append(Drop(name: name, reason: .staleTmp))
        }
        for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let stem = String(name.dropLast(5))
            let taken = dir + "/" + stem + ".taken"
            // Claim it atomically; if the rename loses, someone else has it.
            guard (try? fm.moveItem(atPath: dir + "/" + name, toPath: taken)) != nil else { continue }
            func drop(_ reason: DropReason) {   // don't wedge the queue on a bad item
                done(taken)
                batch.dropped.append(Drop(name: name, reason: reason))
            }
            guard let data = fm.contents(atPath: taken),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { drop(.malformed); continue }
            // Before any field is read: a newer schema may have moved them all.
            if let raw = obj["v"] {
                guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue == Double(version)
                else { drop(.unsupportedVersion); continue }
            }
            guard let text = obj["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { drop(.emptyText); continue }
            let created: Date
            if let raw = obj["created"] {
                // JSON booleans also bridge to NSNumber; they aren't timestamps.
                guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue.isFinite
                else { drop(.invalidCreated); continue }
                created = Date(timeIntervalSince1970: n.doubleValue)
            } else {
                // Rename keeps mtime, so this is when the producer wrote the file.
                created = mtime(taken) ?? now
            }
            guard now.timeIntervalSince(created) < maxAge else { drop(.tooOld); continue }
            let source = obj["source"] as? String ?? ""
            let key = obj["key"] as? String ?? ""
            batch.items.append(SpeechItem(text: text,
                                          source: source.isEmpty ? "Claude Code" : source,
                                          key: key.isEmpty ? stem : key,
                                          created: created,
                                          file: taken,
                                          origin: Origin(json: obj["origin"]),
                                          links: TextLink.parse(obj["links"], in: text),
                                          cwd: TextLink.absolutePath(obj["cwd"]),
                                          blocks: CodeBlock.parse(obj["blocks"], in: text),
                                          answerable: obj["reply"] as? String == "prompt",
                                          media: PhoneMedia.parse(obj["media"])))
        }
        return batch
    }

    /// "The agent is alive and draining": touch the heartbeat's mtime. Only its first
    /// write creates a directory entry; after that it's a pure mtime change, which the
    /// spool's directory watcher doesn't see, so beating never triggers a drain.
    @discardableResult
    static func beat(in dir: String = Spool.dir, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        let path = dir + "/" + heartbeatName
        // The dir can be removed from under a live agent; the hook only recreates it when
        // it queues, which it won't do while the heartbeat is missing. So bring it back here.
        if !fm.fileExists(atPath: dir) { ensure(dir) }
        if !fm.fileExists(atPath: path), !fm.createFile(atPath: path, contents: nil) { return false }
        return (try? fm.setAttributes([.modificationDate: now], ofItemAtPath: path)) != nil
    }

    /// This item will never be spoken again — finished, skipped, stopped, or superseded.
    static func done(_ path: String?) {
        guard let path = path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}

// ---------------------------------------------------------------------------
// Reading the text you've highlighted in whatever app is frontmost.
// ---------------------------------------------------------------------------

enum Selection {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "grant Accessibility" prompt. Returns true if already trusted.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Selected text from the frontmost app, or nil if there is none (or we're untrusted).
    static func current() -> String? {
        guard isTrusted else { return nil }
        return viaAccessibility() ?? viaSynthesizedCopy()
    }

    /// The clean path: ask the focused UI element for its selection. Doesn't touch
    /// the clipboard, but plenty of apps (Chrome, some terminals) don't implement it.
    private static func viaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)   // never hang on a wedged app
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID()
        else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(f as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let s = selected as? String
        else { return nil }
        return nonEmpty(s)
    }

    /// The fallback: press ⌘C for the user and put their clipboard back afterwards.
    private static func viaSynthesizedCopy() -> String? {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        else { return nil }
        // Set flags explicitly: the user is still holding the trigger hotkey's modifiers,
        // and we must not deliver ⌃⌥⌘C to the target app.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        // Nothing selected means ⌘C is a no-op and changeCount never moves.
        var waitedMs = 0
        while pb.changeCount == before && waitedMs < 300 { usleep(10_000); waitedMs += 10 }
        guard pb.changeCount != before else { return nil }

        let copied = pb.string(forType: .string)
        restore(saved, to: pb)
        return copied.flatMap(nonEmpty)
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { types[t] = item.data(forType: t) }
            return types
        }
    }

    private static func restore(_ snap: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        let items = snap.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, data) in types { item.setData(data, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}

// ---------------------------------------------------------------------------
// The mic. When something else starts recording — Claude Code's hold-space
// dictation, a call, system dictation — we shut up until it stops, or whatever
// we're saying ends up in the transcript.
// ---------------------------------------------------------------------------

/// Who's recording comes from CoreAudio's per-process "running input" flag (macOS 14+).
/// Deliberately not the device-wide "running somewhere" flag as the answer: a headset
/// is one device for mic and speaker, so that flips the moment we start talking.
/// But the per-process flag never notifies, so the device flag, the process list, and
/// the default-input choice are just triggers to go and look again.
/// And they miss some recorders: macOS dictation records through a system daemon
/// (historicalaudiod) on a mic that isn't the default input, so nothing fired when it
/// stopped and the hold stuck until some other app touched the mic. So it also looks
/// on a timer, nudged or not.
@available(macOS 14.0, *)
final class MicWatch {
    /// How often it looks without being nudged.
    static let pollEvery: TimeInterval = 0.5

    private(set) var busy = false
    private let recorders: () -> [String]?
    private let onChange: (Bool, String?) -> Void
    private var poll: Timer?
    private var inputDevice = AudioObjectID(kAudioObjectUnknown)
    private var trigger: AudioObjectPropertyListenerBlock!
    private var deviceChanged: AudioObjectPropertyListenerBlock!
    private let system = AudioObjectID(kAudioObjectSystemObject)

    /// `recorders` names who else is recording right now (nil: couldn't tell); tests
    /// stand in for CoreAudio there. `onChange` gets the first name with a hold.
    init(recorders: @escaping () -> [String]? = MicWatch.otherRecorders,
         every: TimeInterval = MicWatch.pollEvery,
         onChange: @escaping (Bool, String?) -> Void) {
        self.recorders = recorders
        self.onChange = onChange
        trigger = { [weak self] _, _ in self?.recheck() }
        deviceChanged = { [weak self] _, _ in self?.followDefaultInput() }
        var list = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(system, &list, .main, trigger)
        var def = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(system, &def, .main, deviceChanged)
        followDefaultInput()
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in self?.look() }
        timer.tolerance = every / 5
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    deinit { poll?.invalidate() }

    private static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T: FixedWidthInteger>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> T? {
        var addr = address(sel)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// Plugging in a headset moves the default input; the old device goes quiet on us.
    private func followDefaultInput() {
        var running = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if inputDevice != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(inputDevice, &running, .main, trigger)
        }
        inputDevice = Self.read(system, kAudioHardwarePropertyDefaultInputDevice) ?? AudioObjectID(kAudioObjectUnknown)
        if inputDevice != kAudioObjectUnknown {
            AudioObjectAddPropertyListenerBlock(inputDevice, &running, .main, trigger)
        }
        recheck()
    }

    private func recheck() {
        look()
        // A recorder's process shows up a beat before its input is actually running;
        // look once more so that ordering can't leave us talking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.look() }
    }

    private func look() {
        guard let others = recorders() else { return }   // couldn't tell: what we knew stands
        let now = !others.isEmpty
        guard now != busy else { return }
        busy = now
        onChange(now, others.first)
    }

    /// Every other process whose input is running, by name. Ours doesn't count.
    static func otherRecorders() -> [String]? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        let me = getpid()
        return ids.compactMap { id in
            let running: UInt32? = read(id, kAudioProcessPropertyIsRunningInput)
            guard (running ?? 0) != 0 else { return nil }
            let pid: Int32? = read(id, kAudioProcessPropertyPID)
            return pid == me ? nil : name(of: pid)
        }
    }

    /// What to call a recorder in the log. macOS dictation and Siri have no process of
    /// their own on the mic: both show up as the system's historicalaudiod. Claude Code's
    /// program file is named for its version (…/claude/versions/2.1.293).
    private static func name(of pid: Int32?) -> String {
        guard let pid = pid else { return "an unknown process" }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "pid \(pid)" }
        return name(ofProgram: String(cString: buf))
    }

    static func name(ofProgram path: String) -> String {
        let file = (path as NSString).lastPathComponent
        if file == "historicalaudiod" { return "macOS dictation or Siri (historicalaudiod)" }
        if path.contains("/claude/versions/") { return "Claude Code \(file)" }
        return file
    }
}

/// Between MicWatch and Playback: whether "someone's recording" should hold speech.
/// Owns the "Pause While Recording" setting and the release debounce. A hold starts at
/// once; a release from the mic waits a beat (recorders drop and reopen the mic between
/// chunks, and you may just be pausing for breath); a release because you switched the
/// setting off is immediate. `deliver` only ever sees transitions.
final class MicHold {
    /// Key in the shared prefs suite, so the agent and the standalone reader agree.
    static let prefKey = "pauseWhileRecording"
    static let releaseDelay: TimeInterval = 0.6

    /// On unless you've turned it off.
    static func storedEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: prefKey) as? Bool ?? true
    }
    static func store(_ on: Bool, in defaults: UserDefaults) { defaults.set(on, forKey: prefKey) }

    private(set) var enabled: Bool
    private(set) var recording = false   // what MicWatch last said, whatever the setting
    private(set) var holding = false     // what Playback was last told
    private var cancelRelease: (() -> Void)?
    private let deliver: (Bool) -> Void
    private let debounce: (@escaping () -> Void) -> () -> Void

    /// `debounce` runs work after `releaseDelay` and returns its cancel; tests run it by hand.
    init(enabled: Bool,
         deliver: @escaping (Bool) -> Void,
         debounce: @escaping (@escaping () -> Void) -> () -> Void = { work in
             let item = DispatchWorkItem(block: work)
             DispatchQueue.main.asyncAfter(deadline: .now() + MicHold.releaseDelay, execute: item)
             return item.cancel
         }) {
        self.enabled = enabled
        self.deliver = deliver
        self.debounce = debounce
    }

    func recordingChanged(_ busy: Bool) {
        recording = busy
        guard enabled else { return }
        if busy { hold() } else if holding, cancelRelease == nil {
            cancelRelease = debounce { [weak self] in
                self?.cancelRelease = nil
                self?.release()
            }
        }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if !on { release() } else if recording { hold() }
    }

    private func hold() {
        cancelRelease?(); cancelRelease = nil
        guard !holding else { return }
        holding = true
        deliver(true)
    }

    private func release() {
        cancelRelease?(); cancelRelease = nil
        guard holding else { return }
        holding = false
        deliver(false)
    }
}

// ---------------------------------------------------------------------------
// Global hotkeys. One Carbon handler for the whole process, dispatching on the
// hotkey id — installing a handler per feature would fire all of them on any key.
// ---------------------------------------------------------------------------

enum HotKeyAction: UInt32 { case read = 1, togglePause = 2, toggleHUD = 3 }

final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private static let signature = OSType(0x53504b48)   // 'SPKH'
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event = event else { return noErr }
            var id = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id)
            if err == noErr { HotKeyCenter.shared.handlers[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    func register(_ action: HotKeyAction, keyCode: UInt32, mods: UInt32,
                  handler: @escaping () -> Void) -> Bool {
        installHandler()
        unregister(action)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        guard RegisterEventHotKey(keyCode, mods, id, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref = ref else { return false }
        refs[action.rawValue] = ref
        handlers[action.rawValue] = handler
        return true
    }

    func unregister(_ action: HotKeyAction) {
        if let ref = refs.removeValue(forKey: action.rawValue) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: action.rawValue)
    }
}

// ---------------------------------------------------------------------------
// Source identity: a stable color per project, so four terminals are four
// colors you learn rather than four names you have to read.
// ---------------------------------------------------------------------------

enum Accent {
    // Yellow and red are omitted: one is illegible, the other reads as an error.
    private static let palette: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple,
        .systemTeal, .systemPink, .systemIndigo, .systemBrown,
    ]
    /// djb2 rather than Swift's `hashValue`, whose seed is randomized per process —
    /// a project would otherwise change color every time the agent restarted.
    static func color(for source: String) -> NSColor {
        var h: UInt64 = 5381
        for byte in source.utf8 { h = (h &* 33) &+ UInt64(byte) }
        return palette[Int(h % UInt64(palette.count))]
    }

    /// The terminal's own frame color ("#rrggbb" from the item's origin), when it has
    /// one: then the pill is the color of the window it goes back to.
    static func frame(_ hex: String?) -> NSColor? {
        guard let hex = hex, hex.count == 7, hex.hasPrefix("#"),
              let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// A colored pill naming whoever is speaking. When the item knows where it came
/// from, the pill is a link: an arrow, a hand cursor, and a click goes there.
final class SourceBadge: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var accent: NSColor = .systemBlue { didSet { needsDisplay = true } }
    /// Filled with the accent instead of tinted by it. For an accent that is the
    /// terminal's frame color: a solid pill is the same swatch as that window's title bar.
    var solid = false { didSet { needsDisplay = true } }
    var isLink = false {
        didSet {
            needsDisplay = true
            toolTip = isLink ? "Go to this terminal" : nil
            window?.invalidateCursorRects(for: self)
        }
    }
    var onClick: () -> Void = {}

    private static let arrow = " ↗"

    private static let dot: CGFloat = 7
    private static let padX: CGFloat = 11
    private static let gap: CGFloat = 7
    private static let maxWidth: CGFloat = 260
    static let height: CGFloat = 24

    private var textAttrs: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail   // long repo names shouldn't stretch the pill
        return [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: ink,
                .paragraphStyle: p]
    }

    /// The name and dot: the accent itself on a tinted pill, black or white on a solid
    /// one, whichever the accent leaves readable.
    private var ink: NSColor {
        guard solid, let c = accent.usingColorSpace(.sRGB) else { return accent }
        let luma = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luma > 0.5 ? NSColor(white: 0, alpha: 0.85) : .white
    }

    /// The arrow is drawn after the name, not as part of it: a session's title is often
    /// too long to fit, and cut off as one string the arrow would be the first thing to go.
    private var arrowWidth: CGFloat {
        isLink ? ceil((Self.arrow as NSString).size(withAttributes: textAttrs).width) : 0
    }

    override var intrinsicContentSize: NSSize {
        let w = ceil((text as NSString).size(withAttributes: textAttrs).width) + arrowWidth
        return NSSize(width: min(w + Self.padX * 2 + Self.dot + Self.gap, Self.maxWidth),
                      height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let pill = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: r.height / 2, yRadius: r.height / 2)
        accent.withAlphaComponent(solid ? 1 : 0.18).setFill(); pill.fill()
        accent.withAlphaComponent(solid ? 1 : 0.5).setStroke(); pill.lineWidth = 1; pill.stroke()

        ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: Self.padX, y: (r.height - Self.dot) / 2,
                                    width: Self.dot, height: Self.dot)).fill()

        let attrs = textAttrs
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        let x = Self.padX + Self.dot + Self.gap
        let y = (r.height - size.height) / 2
        let w = min(ceil(size.width), r.width - x - Self.padX - arrowWidth)
        s.draw(in: NSRect(x: x, y: y, width: w, height: size.height), withAttributes: attrs)
        if isLink {
            (Self.arrow as NSString).draw(at: NSPoint(x: x + w, y: y), withAttributes: attrs)
        }
    }

    override func resetCursorRects() { if isLink { addCursorRect(bounds, cursor: .pointingHand) } }

    /// Whether a click at this window location lands on a live link.
    func takesClick(at locationInWindow: NSPoint) -> Bool {
        isLink && !isHiddenOrHasHiddenAncestor && bounds.contains(convert(locationInWindow, from: nil))
    }
}

/// After the pill takes you to a terminal: dim everything else for a moment and ring
/// that window in the pill's color. Four terminals tiled together look alike, and the
/// one that just came forward isn't obvious.
final class Spotlight {
    static let dim: CGFloat = 0.4
    static let ring: CGFloat = 5
    static let hold: TimeInterval = 0.9
    static let fade: TimeInterval = 0.4

    /// AppleScript's bounds count down from the top of the main screen; AppKit's count
    /// up from its bottom.
    static func flipped(_ r: NSRect, mainHeight: CGFloat? = nil) -> NSRect {
        let h = mainHeight ?? NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    private final class Shade: NSView {
        var hole = NSRect.zero
        var color = NSColor.white

        override func draw(_ dirtyRect: NSRect) {
            let shade = NSBezierPath(rect: bounds)
            shade.append(NSBezierPath(roundedRect: hole, xRadius: 10, yRadius: 10))
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(Spotlight.dim).setFill(); shade.fill()
            // Inside the window's edge: a ring outside it is cut off at the screen's.
            let inset = Spotlight.ring / 2
            let ring = NSBezierPath(roundedRect: hole.insetBy(dx: inset, dy: inset), xRadius: 10, yRadius: 10)
            ring.lineWidth = Spotlight.ring
            color.setStroke(); ring.stroke()
        }
    }

    private var windows: [NSWindow] = []
    private var timer: Timer?
    private var showing = 0   // bumped per show, so a finished fade can't take down a newer one

    init() {
        // The jump may have switched desktops: start the moment over once it lands.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.windows.isEmpty else { return }
            self.windows.forEach { $0.alphaValue = 1 }
            self.linger()
        }
    }

    /// `target` in AppKit screen coordinates. One shade per screen; clicks pass through.
    func show(around target: NSRect, color: NSColor) {
        clear()
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.animationBehavior = .none
            w.level = .floating   // over app windows, under the menu bar and Dock
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let shade = Shade(frame: NSRect(origin: .zero, size: screen.frame.size))
            shade.hole = target.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            shade.color = color
            w.contentView = shade
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        linger()
    }

    private func linger() {
        showing += 1
        let mine = showing
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.hold, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Self.fade
                self.windows.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: { [weak self] in
                if self?.showing == mine { self?.clear() }
            })
        }
    }

    private func clear() {
        timer?.invalidate()
        timer = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}

/// SpeakHUD runs as an accessory app: no Dock icon, and no menu bar to own an Edit
/// menu. ⌘C is normally delivered *by* that menu, so without one a selection in the
/// transcript looks copyable but silently isn't. Route the few editing keys the panel
/// needs straight into the responder chain instead.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // …or it never sees a keystroke at all

    /// The panel is deliberately non-activating, so it can appear mid-sentence without
    /// stealing focus from whatever you're typing in. The cost is that an inactive app
    /// receives no keyboard input at all — which is why selecting text and pressing ⌘C
    /// did nothing. Clicking the HUD is an unambiguous "I want to use this", so take
    /// focus at that point, and only then.
    override func sendEvent(_ event: NSEvent) {
        // The pill sits under the transparent title bar, which takes clicks there as
        // the start of a drag, and the first click on an inactive panel only focuses
        // it. Either way the pill itself would never see the click, so catch it here.
        if event.type == .leftMouseDown, let link = link, link.takesClick(at: event.locationInWindow) {
            // Active, so this app can hand activation on to the terminal (macOS 14+).
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            DispatchQueue.main.async { link.onClick() }
            return
        }
        if event.type == .leftMouseDown, !NSApp.isActive {
            focusDonor = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
        }
        super.sendEvent(event)
    }

    /// The source pill, whose clicks are routed here rather than by hit-testing.
    weak var link: SourceBadge?

    /// Whoever we took focus from. NSApp.deactivate() alone just leaves this app
    /// frontmost with no windows, so the app has to be reactivated by name.
    private var focusDonor: NSRunningApplication?

    func returnFocus() {
        guard NSApp.isActive, let donor = focusDonor,
              donor.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        donor.activate(options: [])
        focusDonor = nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector?
        switch key {
        case "c": action = #selector(NSText.copy(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        default:  action = nil
        }
        if let action = action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// ---------------------------------------------------------------------------
// Playback: every decision about what speaks, when, and from where. The queue,
// whose pause it is (yours, the mic's or Away's), the resume point, the speed. No AppKit
// and no AVFoundation — it drives a `Voice` and publishes one `State` for the HUD
// to render, so the rules run in tests against a fake voice.
// ---------------------------------------------------------------------------

/// What Playback needs from a speech engine. Offsets are UTF-16 positions in the
/// full item text. Progress and finishes come back tagged with the `utterance` they
/// belong to, so anything from an utterance Playback has since dropped is stale.
protocol Voice: AnyObject {
    /// Say `text` from `offset` at `rate`, replacing whatever was going.
    func speak(_ text: String, from offset: Int, rate: Float, utterance: Int)
    /// Hold mid-utterance: `immediately` cuts off mid-word (the mic is opening);
    /// otherwise at the next word boundary.
    func pause(immediately: Bool)
    func resume()
    /// Silence and forget the current utterance. Never reported back as finished.
    func stop()
}

/// What Playback needs from a microphone that turns speech into words. Everything it
/// reports comes back tagged with the `window` it was opened for, so anything from a
/// window Playback has since shut is stale.
protocol Ear: AnyObject {
    var listener: Playback? { get set }
    /// Open the mic: `earOpened` once it is, then what's heard so far, each time it
    /// changes, to `earHeard(_:window:)`. A mic that can't be opened goes to `earFailed`.
    /// Replaces a window still open. `overSpeech`: the voice is talking meanwhile, so
    /// its sound has to be taken out of what the mic hears.
    func listen(window: Int, overSpeech: Bool)
    /// The longest `listen` may take to say `earOpened` or `earFailed`, every try of
    /// its own included. A reply window still not open after that is given up on: the
    /// number is the mic's alone, so no limit of Playback's can cut its tries short.
    func opensWithin(overSpeech: Bool) -> TimeInterval
    /// Close the mic. Nothing more is reported.
    func stop()
}

final class Playback {
    /// Everything the HUD shows about playback, derived in one place so no label can
    /// drift from another.
    struct State: Equatable {
        var status = ""
        var pauseTitle = "❚❚ Pause"
        var speedTitle = ""
        var queued: [String] = []   // sources waiting behind the current item, in order
        var isActive = false        // something is current or waiting: don't auto-hide
        var canSkip = false
        /// What's been heard in the reply window (empty until you speak), then what was
        /// sent, until the next item starts. Nil when there's no reply to show.
        var heard: String? = nil
        var putOff = 0              // turns put off, waiting for the next thing to arrive
        var listening = false       // the mic is open for commands while it reads
    }

    // macOS default rate (0.5) == 1×; the steps scale around it.
    static let rateSteps: [Float] = [0.375, 0.5, 0.625, 0.75, 0.875, 1.0]
    static let rateLabels = ["0.75×", "1×", "1.25×", "1.5×", "1.75×", "2×"]

    private(set) var current: SpeechItem?
    private(set) var queue: [SpeechItem] = []
    private(set) var rateIndex: Int
    private(set) var state = State()

    var onChange: (State) -> Void = { _ in }
    /// A new item became current: show its text.
    var onStart: (SpeechItem) -> Void = { _ in }
    /// The word being spoken, in full-text coordinates.
    var onWord: (NSRange) -> Void = { _ in }
    var onRanDry: () -> Void = {}
    var onStopped: () -> Void = {}
    var log: (String) -> Void = { _ in }

    private let voice: Voice
    private let release: (SpeechItem) -> Void
    private let now: () -> Date

    private enum Sound { case silent, speaking, paused }
    /// What the voice is doing. Only Playback's own calls change it — never read back
    /// from the engine, whose idea of "speaking" lags and lies around stops.
    private var sound = Sound.silent
    private var utterance = 0      // id of the last utterance handed to the voice
    private var resumeAt = 0       // start of the word being spoken: where a restart picks up
    private var userPaused = false {   // yours; the mic never clears it
        didSet {
            // A pause that's over, however it ended, takes its "asked for by voice"
            // with it, and the wait for "go on".
            guard !userPaused else { return }
            pausedByVoice = false
            cancelPausedListen?()
            cancelPausedListen = nil
        }
    }
    private var micBusy = false
    private var away = false       // nobody is at the Mac: nothing sounds, no mic opens
    private var phoneHas: Set<String> = []   // spool files of the turns the phone holds: what Away may let go
    private var lastItem: SpeechItem?   // what Replay replays once the queue has run dry
    private var stopped = false    // the HUD was emptied by Stop, not by running dry
    private var startedAt = Date()

    /// `retire` releases an item that will never be spoken again (its spool file).
    /// `later` runs work after the current event is done; tests run it inline.
    /// `ear` is the mic for the reply window (none: never listens); `timer` runs work
    /// after a while and returns its cancel, and tests fire it by hand.
    init(voice: Voice, rateIndex: Int = 1,
         retire: @escaping (SpeechItem) -> Void = { Spool.done($0.file) },
         now: @escaping () -> Date = Date.init,
         later: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         ear: Ear? = nil,
         timer: @escaping (TimeInterval, @escaping () -> Void) -> () -> Void = { seconds, work in
             let item = DispatchWorkItem(block: work)
             DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
             return item.cancel
         }) {
        self.voice = voice
        self.later = later
        self.ear = ear
        self.timer = timer
        self.rateIndex = Self.rateSteps.indices.contains(rateIndex) ? rateIndex : 1
        self.release = retire
        self.now = now
        state = makeState()
    }

    /// This item will never be spoken again: let go of its spool file.
    private func retire(_ item: SpeechItem) {
        if let file = item.file { phoneHas.remove(file) }
        release(item)
    }

    // -- commands ----------------------------------------------------------

    /// Wait your turn. A second turn from the same session replaces the first one
    /// still waiting in line — you want the latest answer, not a stale one.
    /// `onPhone`: the phone's page has this turn too (`Phone.took`), so Away may let
    /// go of it unread. What became of it goes in the log.
    /// Returns true only if this item is now actually being spoken.
    @discardableResult
    func enqueue(_ item: SpeechItem, onPhone: Bool = false) -> Bool {
        if onPhone, let file = item.file { phoneHas.insert(file) }
        if away, !waitsWhileAway(item) { return false }
        if let i = queue.firstIndex(where: { $0.key == item.key }) {
            retire(queue[i])  // the stale turn is never spoken; let go of its file
            queue[i] = item   // keep its place in line; a chatty session shouldn't jump the queue
        } else {
            queue.append(item)
        }
        // "The end" has arrived for anything put off: behind this, unless this is its
        // own session with something newer to say.
        for stale in putOff where stale.key == item.key { retire(stale) }
        queue.append(contentsOf: putOff.filter { $0.key != item.key })
        putOff.removeAll()
        // Nothing current means the queue was empty: this item becomes current, and
        // sounds unless the mic or your pause is holding us. An open reply window is
        // you about to speak: it waits for that.
        let wasIdle = current == nil && window == nil
        if wasIdle { advance() }
        publish()
        let speaking = wasIdle && sound == .speaking
        if !away {   // away, waitsWhileAway has said what became of it
            log(speaking ? "speaking \(item.source)"
                : wasIdle && current?.file == item.file ? "holding \(item.source) — mic in use or paused"
                : "queued \(item.source) — \(queue.count) waiting")
        }
        return speaking
    }

    /// Jump the queue: you highlighted that text and asked for it now. It becomes
    /// current even while the mic is busy (so you can see it), but waits to be heard.
    func playNow(_ item: SpeechItem) {
        closeWindow("a read was asked for")
        if let c = current {
            silence()
            // A spool-backed turn was interrupted, not finished — put it back at the head
            // of the queue and keep its file, or a hotkey read silently destroys a Claude
            // response mid-sentence. Two exceptions retire it instead: an ad-hoc read
            // (no spool file) is superseded by the one you just asked for, and a session
            // with a newer turn already waiting follows "newest per session wins".
            if c.file != nil, !queue.contains(where: { $0.key == c.key }) {
                log("preempted \(c.source) — requeued")
                queue.insert(c, at: 0)
            } else {
                log("preempted \(c.source)")
                retire(c)
            }
            current = nil
        }
        userPaused = false   // asking for something now is not asking for silence
        start(item)
        publish()
    }

    /// Drop the current item and move on. Clears your pause: skipping is asking for
    /// the next one. The mic still holds it.
    func skip() {
        if window != nil {   // nothing is being read: Skip is "no reply"
            closeWindow("skipped")
            userPaused = false
            moveOn()
            return
        }
        guard let c = current else { return }
        log("skipped \(c.source)")
        retire(c)
        silence()
        lastItem = c
        current = nil
        userPaused = false
        advance()
        publish()
    }

    /// Stop everything and throw the queue away. "Skip" is the one that moves on.
    func stop() {
        closeWindow("stopped")
        putOff.forEach(retire)
        putOff.removeAll()
        silence()
        log("stop: discarded \(queue.count) queued item(s)")
        if let c = current { retire(c); lastItem = c }
        queue.forEach(retire)
        queue.removeAll()
        current = nil
        userPaused = false
        stopped = true
        publish()
        onStopped()
    }

    /// Pause or resume. Also works while an item is waiting on the mic: a pause made
    /// then is kept when the mic frees up. Resuming while the mic is busy hands the
    /// hold back to the mic, which resumes on release.
    func togglePause() {
        pausedByVoice = false   // your hands are on it now: the mic isn't kept open for "go on"
        if let w = window {   // the Clear button, and the one key that works from anywhere
            if SpokenCommand.words(w.heard).isEmpty {
                closeWindow("closed")   // nothing to clear: you didn't mean it to listen
                moveOn()
            } else {
                hearAgain("cleared")    // "not that": wiped, and a few seconds to say it again
            }
            return
        }
        guard current != nil || !queue.isEmpty else { return }
        userPaused.toggle()
        proceed()
        publish()
    }

    /// Cycle the speed. AVSpeech can't change rate mid-utterance, so a live utterance
    /// is dropped and restarted from the current word — immediately if we're sounding,
    /// otherwise on the next resume. Never un-pauses.
    func cycleSpeed() {
        rateIndex = (rateIndex + 1) % Self.rateSteps.count
        silence()
        drive()
        publish()
    }

    /// From the top. Like Speed, it doesn't un-pause. Once the queue has run dry it
    /// brings the last item back as current (without its spool file, which is gone),
    /// so a turn arriving meanwhile queues behind it instead of cutting it off.
    func replay() {
        closeWindow("replay")   // the turn you were about to answer is the last item
        if current == nil {
            guard var last = lastItem else { return }
            last.file = nil
            start(last)
        } else {
            silence()
            resumeAt = 0
            drive()
        }
        publish()
    }

    /// Something else is (or stopped) recording. Mid-speech this pauses on the spot
    /// and resumes on release; nothing new starts while it's busy. Debouncing the
    /// release is the caller's job.
    func micChanged(busy: Bool) {
        guard busy != micBusy else { return }
        micBusy = busy
        log(busy ? "mic in use — holding speech" : "mic released")
        if busy, window != nil {   // you're answering with a key held instead
            closeWindow("another app took the mic")
            advance()
        } else {
            proceed()
        }
        publish()
    }

    /// Away went on or off: nobody is at the Mac, and the phone has the turns. On: what's
    /// being read stops, and it and everything waiting that the phone has is let go for
    /// good; a reply window or the mic open for commands shuts. Until it goes off
    /// nothing is read and no mic opens. Off: nothing let go comes back. What the phone
    /// couldn't show, or was asked for by hand meanwhile, has waited and is read now.
    func awayChanged(on: Bool) {
        guard on != away else { return }
        away = on
        if on {
            closeWindow("away")
            silence()
            resumeAt = 0   // the one being read, if it's kept, is read from the top
            if let c = current, !waitsWhileAway(c) {
                lastItem = c
                current = nil
            }
            queue = queue.filter(waitsWhileAway)
            putOff = putOff.filter(waitsWhileAway)
            if current == nil { advance() }   // what waits is up next, shown but silent
        } else {
            log("away off")
            proceed()
        }
        publish()
    }

    /// Away: whether `item` waits to be read. Not if the phone has it, nor if nothing on
    /// disk backs it (it was asked for by hand, or has been read to its end already):
    /// those are let go here. One the phone couldn't show has been seen nowhere, so it waits.
    private func waitsWhileAway(_ item: SpeechItem) -> Bool {
        if let file = item.file, !phoneHas.contains(file) {
            log("away: \(item.source) waits to be read: the phone can't show it")
            return true
        }
        log("away: \(item.source) not read" + (item.file == nil ? "" : ", the phone has it"))
        retire(item)
        return false
    }

    // -- from the voice ----------------------------------------------------

    func voiceSpoke(_ range: NSRange, utterance id: Int) {
        guard id == utterance, sound != .silent else { return }
        resumeAt = range.location
        onWord(range)
    }

    /// A stale finish (a dropped utterance) is ignored, so a stop can never advance
    /// the queue a second time. Called from inside the synth's delegate callback: the
    /// finish is recorded now, so a command arriving before the hop sees the item as
    /// done (a hotkey read won't requeue it, Speed won't repeat its last word), but
    /// starting the next item — which hands the voice a new utterance — waits for
    /// `later`, because re-entering the synth from its own callback can drop audio.
    func voiceFinished(utterance id: Int) {
        guard id == utterance, sound != .silent, let c = current else { return }
        sound = .silent
        log(String(format: "finish %@ after %.1fs", c.source, now().timeIntervalSince(startedAt)))
        retire(c)
        lastItem = c
        current = nil
        if shouldListen(after: c) {   // your turn; the next item waits for the window to shut
            openWindow(for: c)
            return
        }
        publish()
        later { [weak self] in
            guard let self = self, self.current == nil, self.window == nil else { return }  // something started meanwhile
            self.advance()
            self.publish()
        }
    }

    // -- the reply window ---------------------------------------------------
    //
    // "Listen After Reading": when an answerable turn has been read, the mic opens and
    // what you say goes back to the terminal that spoke. Say nothing and it closes by
    // itself. Nothing else is read while it's open.

    /// How long you have to start talking.
    static let replyWait: TimeInterval = 8
    /// The quiet that ends what you're saying.
    static let replyPause: TimeInterval = 1.5
    /// How long "sending" shows before it goes: say more, or Skip, to take it back.
    static let replyGrace: TimeInterval = 1.5
    /// How long you have to start again after taking back what was heard.
    static let replyRetry: TimeInterval = 5

    private struct Listening {
        enum Phase { case opening, waiting, hearing, sending }
        let item: SpeechItem
        let id: Int
        var heard = ""
        var phase = Phase.opening
        var again = false   // reopened after a take-back: a shorter wait to start
    }

    /// The setting. Turning it off shuts a window that's open.
    var listens = false {
        didSet {
            guard !listens, window != nil else { return }
            closeWindow("switched off")
            moveOn()
        }
    }
    /// The mic opened for a reply to this item.
    var onListen: (SpeechItem) -> Void = { _ in }
    /// A reply was said and this is what became of it. The words stay in `state.heard`
    /// either way, so one that didn't arrive isn't lost.
    var onReplied: (Reply.Outcome) -> Void = { _ in }
    /// The mic couldn't be opened.
    var onEarFailed: (String) -> Void = { _ in }
    /// Puts the words in the item's terminal. Tests answer for iTerm2.
    var deliver: (String, SpeechItem) -> Reply.Outcome = { text, item in
        item.origin.map { Reply.send(text, to: $0) } ?? .gone
    }

    private let ear: Ear?
    private let timer: (TimeInterval, @escaping () -> Void) -> () -> Void
    private var window: Listening?
    private var windowID = 0
    private var cancelTimer: (() -> Void)?
    /// Turns put off with nothing else waiting. They rejoin the line behind the next
    /// thing to arrive, which is what "the end" means when there is no line.
    private var putOff: [SpeechItem] = []
    private var note = ""       // how the last reply went, shown until the next item starts
    private var said: String?   // and what it was

    private func shouldListen(after item: SpeechItem) -> Bool {
        // Not while another app has the mic: you're already answering with a key held.
        // Not when its session has more to say already: that turn gets the window.
        listens && ear != nil && item.answerable && Reply.canReach(item.origin) && !micBusy
            && !queue.contains { $0.key == item.key }
    }

    private func openWindow(for item: SpeechItem) {
        windowID += 1
        window = Listening(item: item, id: windowID)
        note = ""
        said = nil
        hearReply()
        publish()
    }

    /// Open the mic for the window just made. Your time to start runs from when the mic
    /// says it's open (`earOpened`); one that never says is given up on, once the mic's
    /// own tries have had the time it says they take (`Ear.opensWithin`).
    private func hearReply() {
        guard let w = window, let ear = ear else { return }
        arm(ear.opensWithin(overSpeech: obeys)) { [weak self] in
            self?.closeWindow("the mic never opened")
            self?.moveOn()
        }
        // The same kind of mic the commands use, when they're on: going from the
        // echo-cancelling mic to the plain one failed to start 8 times in 8, and in use
        // it twice opened to silence (10-07). Staying on one kind opened 8 times in 8.
        ear.listen(window: w.id, overSpeech: obeys)
    }

    /// The mic is open: your turn. (For commands while reading there's nothing to do.)
    func earOpened(window id: Int) {
        guard var w = window, w.id == id, w.phase == .opening else { return }
        w.phase = .waiting
        window = w
        log("listening for a reply to \(w.item.source)")
        onListen(w.item)
        armWait()
        publish()
    }

    private func arm(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        cancelTimer?()
        cancelTimer = timer(seconds, work)
    }

    private func armWait() {
        arm(window?.again == true ? Self.replyRetry : Self.replyWait) { [weak self] in
            self?.closeWindow("nothing said")
            self?.moveOn()
        }
    }

    /// Shut the mic without sending anything.
    private func closeWindow(_ why: String) {
        guard let w = window else { return }
        cancelTimer?()
        cancelTimer = nil
        window = nil
        ear?.stop()
        log("stopped listening to \(w.item.source): \(why)")
    }

    /// The window is shut and nothing was started in its place: on to whatever's waiting.
    private func moveOn() {
        guard current == nil, window == nil else { return }
        advance()
        publish()
    }

    /// What the mic has made of it so far: the whole of it each time, not the new part.
    func earHeard(_ text: String, window id: Int) {
        if var a = attending, a.id == id {
            let before = SpokenCommand.words(a.heard), now = SpokenCommand.words(text)
            a.heard = text
            attending = a
            guard now != before else { return }
            cancelPhrase?()
            cancelPhrase = timer(Self.commandPause) { [weak self] in self?.phraseEnded() }
            return
        }
        guard var w = window, w.id == id else { return }
        let before = SpokenCommand.words(w.heard), now = SpokenCommand.words(text)
        w.heard = text
        if now != before {   // the same words re-punctuated aren't more speech
            if now.isEmpty {
                w.phase = .waiting
                armWait()
            } else {
                w.phase = .hearing
                arm(Self.replyPause) { [weak self] in self?.settled() }
            }
        }
        window = w
        publish()
    }

    func earFailed(_ why: String, window id: Int) {
        if attending?.id == id {
            log("can't listen for commands: \(why)")
            earBroken = true   // until the next item: no use retrying on every word
            publish()
            return
        }
        guard window?.id == id else { return }
        closeWindow("can't listen: \(why)")
        note = "✗ Can't listen: \(why)"
        onEarFailed(why)
        moveOn()
    }

    /// You've stopped talking. A command is done now; a reply shows as "sending" first.
    private func settled() {
        guard var w = window else { return }
        cancelTimer = nil
        switch SpokenCommand.parse(w.heard) {
        case .again?:
            closeWindow("asked to hear it again")
            var again = w.item
            again.file = nil   // its spool file went when it finished
            start(again)
            publish()
        case .later?:
            closeWindow("put off to the end")
            var later = w.item
            later.file = nil
            // A session with more to say already has put this turn behind it.
            if !queue.contains(where: { $0.key == later.key }) {
                if queue.isEmpty { putOff.append(later) } else { queue.append(later) }
                note = "⏳ Put off to the end"
            }
            moveOn()
        case .skip?:
            closeWindow("no reply")
            moveOn()
        case .scratch?:
            hearAgain("scratched")
        case nil, .pause?, .resume?, .stopAll?:   // those three are only ever heard mid-turn
            w.phase = .sending
            window = w
            arm(Self.replyGrace) { [weak self] in self?.sendReply() }
            publish()
        }
    }

    /// Throw away what's been heard and listen afresh for a little while: you may want
    /// to say it again, or nothing. A fresh window, because the mic would go on
    /// reporting the words taken back.
    private func hearAgain(_ why: String) {
        guard let w = window else { return }
        log("\(why); listening again")
        windowID += 1
        var fresh = Listening(item: w.item, id: windowID)
        fresh.again = true
        window = fresh
        hearReply()
        publish()
    }

    private func sendReply() {
        guard let w = window else { return }
        cancelTimer = nil
        window = nil
        ear?.stop()
        let line = Reply.clean(w.heard)
        let outcome = line.map { deliver($0, w.item) } ?? .failed("nothing to send")
        log("reply to \(w.item.source) (\(w.heard.count) chars): \(outcome)")
        note = outcome == .sent ? "✓ Sent to \(w.item.source)" : "✗ Not sent: \(outcome)"
        said = line
        onReplied(outcome)
        moveOn()
    }

    // -- commands while reading ---------------------------------------------
    //
    // "Listen While Reading": the mic is open while turns are being read, with the
    // voice's own sound taken out of it (MicEar), and a short phrase said on its own is
    // a command: again, later, skip, pause, go on, stop everything.

    /// The quiet that ends a command.
    static let commandPause: TimeInterval = 0.6
    /// How long the mic stays open for "go on" after "pause" was said.
    static let pausedListen: TimeInterval = 60
    /// How far back from the word being spoken the voice's own words are looked for,
    /// in UTF-16 units: several seconds' worth at any speed.
    static let ownVoiceReach = 160

    /// The setting.
    var obeys = false { didSet { if obeys != oldValue { publish() } } }
    /// A command was heard and is about to be done.
    var onCommand: (SpokenCommand) -> Void = { _ in }

    private struct Attending {
        let id: Int
        var heard = ""
        var mark: [String] = []   // the words as they stood at the last quiet moment
    }
    private var attending: Attending?
    private var cancelPhrase: (() -> Void)?
    private var pausedByVoice = false
    private var cancelPausedListen: (() -> Void)?
    private var earBroken = false

    /// Make the mic match the policy, as drive() does the voice: open for commands
    /// while there's something to read and nothing else has the mic. A reply window has
    /// it to itself. Paused by a key or button it shuts (your hands are on it); paused
    /// by voice it stays, for "go on". Away it's shut: nothing is read to say them over.
    private func attend() {
        let reading = current != nil || !queue.isEmpty
        let want = obeys && ear != nil && !earBroken && window == nil && !micBusy && !away && reading
            && (!userPaused || pausedByVoice)
        if want, attending == nil {
            windowID += 1
            attending = Attending(id: windowID)
            ear?.listen(window: windowID, overSpeech: true)
        } else if !want, attending != nil {
            cancelPhrase?()
            cancelPhrase = nil
            attending = nil
            if window == nil { ear?.stop() }   // a reply window has already taken the mic over
        }
    }

    /// It's gone quiet: was what was just said a command?
    private func phraseEnded() {
        cancelPhrase = nil
        guard var a = attending else { return }
        let all = SpokenCommand.words(a.heard).split(separator: " ").map(String.init)
        // What's new since the last quiet moment. The transcriber may have gone back and
        // changed what came before it; then all of it counts as new.
        let phrase = (all.starts(with: a.mark) ? Array(all.dropFirst(a.mark.count)) : all).joined(separator: " ")
        a.mark = all
        attending = a
        guard let command = SpokenCommand.parse(phrase, whileReading: true) else { return }
        guard !saidByTheVoice(phrase) else {
            log("ignored \"\(phrase)\": the voice had just said it")
            return
        }
        log("heard \"\(phrase)\"")
        onCommand(command)
        obey(command)
    }

    /// Whether the voice itself just said `phrase`: its words, in order, among the last
    /// it spoke. Echo cancelling should have kept them out of the mic; this is for when
    /// it hasn't, so the HUD can't talk itself into skipping.
    private func saidByTheVoice(_ phrase: String) -> Bool {
        guard let c = current, sound == .speaking else { return false }
        let text = c.text as NSString
        let from = max(0, resumeAt - Self.ownVoiceReach), to = min(text.length, resumeAt + 40)
        guard to > from else { return false }
        let recent = SpokenCommand.words(text.substring(with: NSRange(location: from, length: to - from)))
        return (" " + recent + " ").contains(" " + phrase + " ")
    }

    private func obey(_ command: SpokenCommand) {
        switch command {
        case .again:
            if userPaused {   // asking to hear it is asking for sound
                userPaused = false
                pausedByVoice = false
            }
            replay()
        case .later:
            putOffCurrent()
        case .skip:
            skip()
        case .pause:
            guard !userPaused, current != nil else { return }
            userPaused = true
            pausedByVoice = true
            cancelPausedListen?()
            cancelPausedListen = timer(Self.pausedListen) { [weak self] in
                guard let self = self, self.pausedByVoice else { return }
                self.pausedByVoice = false   // still paused; no longer listening for "go on"
                self.publish()
            }
            proceed()
            publish()
        case .resume:
            guard userPaused else { return }
            userPaused = false
            pausedByVoice = false
            proceed()
            publish()
        case .stopAll:
            stop()
        case .scratch:
            break
        }
    }

    /// "Later", said mid-turn: to the back of the line, to be read from the top when its
    /// time comes. It keeps its spool file: it hasn't been heard out yet.
    private func putOffCurrent() {
        guard let c = current else { return }
        log("put off \(c.source)")
        silence()
        current = nil
        userPaused = false
        if queue.contains(where: { $0.key == c.key }) {
            retire(c)   // its session has something newer waiting: that's the one to hear
        } else if queue.isEmpty {
            putOff.append(c)
            note = "⏳ Put off to the end"
        } else {
            queue.append(c)
        }
        advance()
        publish()
    }

    // -- policy ------------------------------------------------------------

    private let later: (@escaping () -> Void) -> Void
    private var canSound: Bool { !userPaused && !micBusy && !away }

    /// Something that was holding us let go (or took hold): act on it.
    private func proceed() {
        guard window == nil else { return }
        if current != nil { drive() } else if !queue.isEmpty { advance() }
    }

    /// Nothing is current. Make the next item current even if something is holding
    /// us: the HUD shows what's up next, and drive() keeps it silent until we can sound.
    private func advance() {
        if queue.isEmpty {
            userPaused = false
            stopped = false
            onRanDry()
        } else {
            start(queue.removeFirst())
        }
    }

    private func start(_ item: SpeechItem) {
        current = item
        resumeAt = 0
        stopped = false
        note = ""
        said = nil
        earBroken = false   // a mic that failed gets another try with each item
        startedAt = now()
        log("start \(item.source) (\(item.text.count) chars)")
        onStart(item)
        drive()
    }

    /// Make the voice match the policy.
    private func drive() {
        guard let c = current else { return }
        if canSound {
            switch sound {
            case .silent:
                utterance += 1
                sound = .speaking
                voice.speak(c.text, from: resumeAt, rate: Self.rateSteps[rateIndex], utterance: utterance)
            case .paused:
                sound = .speaking
                voice.resume()
            case .speaking:
                break
            }
        } else if sound == .speaking {
            sound = .paused
            // A synth that's spoken one more syllable has already been heard by the mic.
            voice.pause(immediately: micBusy)
        }
    }

    private func silence() {
        guard sound != .silent else { return }
        sound = .silent
        voice.stop()
    }

    private func publish() {
        attend()
        state = makeState()
        onChange(state)
    }

    private func makeState() -> State {
        var s = State()
        s.queued = queue.map(\.source)
        s.isActive = current != nil || !queue.isEmpty
        s.canSkip = current != nil && !queue.isEmpty
        s.speedTitle = "⏩ \(Self.rateLabels[rateIndex])"
        s.pauseTitle = userPaused ? "▶ Resume" : "❚❚ Pause"
        s.putOff = putOff.count
        s.heard = window?.heard ?? said
        if let w = window {
            s.isActive = true   // you're mid-reply: the HUD stays up
            s.canSkip = true
            // Nothing to pause: the button (and its key) wipes what's been heard, or with
            // nothing heard shuts the mic.
            s.pauseTitle = SpokenCommand.words(w.heard).isEmpty ? "✕ Close" : "✕ Clear"
            switch w.phase {
            case .opening: s.status = "🎙 Opening the mic…"
            case .waiting: s.status = w.again ? "🎙 Cleared. Say it again, or say nothing"
                                              : "🎙 Listening: answer \(w.item.source), or say nothing"
            case .hearing: s.status = "🎙 Listening… “clear that” takes it back"
            case .sending: s.status = "➤ Sending to \(w.item.source)… “clear that” stops it"
            }
        } else if !s.isActive {
            s.status = away ? "📱 Away: turns go to your phone"
                : stopped ? "■ Stopped" : !note.isEmpty ? note : (lastItem == nil ? "" : "Done")
        } else if userPaused {
            s.status = pausedByVoice && attending != nil ? "⏸ Paused: say “go on”" : "⏸ Paused"
        } else if away {
            s.status = "📱 Away: this is read when you're back"
        } else if micBusy {
            s.status = sound == .paused ? "🎙 Mic in use — paused" : "🎙 Mic in use — waiting"
        } else {
            s.status = "🔊 Speaking…  \(Self.rateLabels[rateIndex])"
                + (attending != nil ? "   🎙 again · later · skip · pause" : "")
        }
        s.listening = attending != nil
        return s
    }
}

/// The app's voice: AVSpeechSynthesizer behind the `Voice` seam.
final class SpeechVoice: NSObject, Voice, AVSpeechSynthesizerDelegate {
    weak var listener: Playback?

    // Replaced on every (re)start: stopSpeaking(.immediate) poisons an instance so
    // the next utterance silently finishes with no audio. A fresh synth avoids that.
    private var synth: AVSpeechSynthesizer?
    private var utterance = 0
    private var sliceStart = 0   // where in the full text the live utterance begins

    func speak(_ text: String, from offset: Int, rate: Float, utterance id: Int) {
        stop()
        request = (text, offset, rate, id)
        let ns = text as NSString
        sliceStart = min(max(offset, 0), ns.length)
        utterance = id
        // Speak from the resume point so a speed change picks up where we left off
        // rather than restarting from the top.
        let u = AVSpeechUtterance(string: ns.substring(from: sliceStart))
        let env = ProcessInfo.processInfo.environment
        if let v = env["SPEAK_VOICE"], !v.isEmpty {
            // Accept either a voice identifier or a name; fall back gracefully.
            if let voice = AVSpeechSynthesisVoice(identifier: v) { u.voice = voice }
            else if let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == v }) { u.voice = voice }
        }
        u.rate = rate
        let s = AVSpeechSynthesizer()
        s.delegate = self
        synth = s
        spoke = false
        s.speak(u)
    }

    /// A fresh synth ignores a pause that arrives before its first word — it reports
    /// isPaused and talks anyway, even if the pause is sent from didStart or a hop after
    /// it (all verified on this machine) — and every utterance is a fresh synth. Nothing
    /// has been heard yet in that window, so drop the synth and speak the same request
    /// again on resume.
    private var spoke = false
    private var request: (text: String, offset: Int, rate: Float, id: Int)?
    private var parked = false

    func pause(immediately: Bool) {
        if spoke {
            synth?.pauseSpeaking(at: immediately ? .immediate : .word)
        } else if synth != nil {
            let r = request
            stop()
            request = r
            parked = true
        }
    }
    func resume() {
        if parked, let r = request {
            speak(r.text, from: r.offset, rate: r.rate, utterance: r.id)
        } else {
            synth?.continueSpeaking()
        }
    }

    /// stopSpeaking(.immediate) delivers didFinish — not didCancel — on both a speaking
    /// and a paused synth (verified on this machine). Letting go of the instance first
    /// makes that late finish come from a synth that isn't live, which is ignored; a
    /// stop must never reach Playback as "finished".
    func stop() {
        parked = false
        request = nil
        guard let s = synth else { return }
        synth = nil
        s.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        guard s === synth else { return }   // replaced or stopped: not ours to report
        // Playback records the finish now and hops out of this callback before starting
        // the next item: that replaces `synth`, deallocating the very instance calling
        // us, and the next utterance can be dropped without a sound.
        listener?.voiceFinished(utterance: utterance)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {}

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance u: AVSpeechUtterance) {
        guard s === synth else { return }
        spoke = true
        // Ranges are relative to the (possibly sliced) utterance; shift to full-text coords.
        listener?.voiceSpoke(NSRange(location: sliceStart + characterRange.location,
                                     length: characterRange.length), utterance: utterance)
    }
}

// ---------------------------------------------------------------------------
// Dictation from the phone: the page records what you say and sends it here, and the
// Mac's own transcriber turns it into words for the page's answer box. The sound goes
// from your phone to your Mac and no further; it's deleted once it has been heard.
// ---------------------------------------------------------------------------

enum Dictation {
    /// What the page sends: plain 16-bit sound in a WAV, which any Mac reads.
    static let type = "audio/wav"
    /// The least a recording can be and still be one: a WAV's 44-byte header and a
    /// tenth of a second at the page's 16,000 samples a second.
    static let least = 44 + 3_200

    /// How long the transcriber gets with one recording before it's given up on. Three
    /// minutes of speech takes it a few seconds; a recording it can't make sense of has
    /// been seen to keep it for ever (10-08: a WAV whose header didn't match its length).
    static let patience: TimeInterval = 45

    /// A number in a WAV's header: `bytes` of them at `at`, smallest first.
    private static func number(_ data: Data, _ at: Int, _ bytes: Int) -> Int {
        (0..<bytes).reduce(0) { $0 | Int(data[data.startIndex + at + $1]) << (8 * $1) }
    }

    /// Whether `data` is exactly what the page makes, by its own bytes and whatever the
    /// request called it: a 44-byte header saying plain 16-bit sound on one channel, then
    /// just as much sound as the header says. Anything else never reaches the transcriber.
    static func looksRight(_ data: Data) -> Bool {
        guard data.count >= least else { return false }
        func tag(_ at: Int) -> String { String(decoding: data.dropFirst(at).prefix(4), as: UTF8.self) }
        return tag(0) == "RIFF" && tag(8) == "WAVE" && tag(12) == "fmt " && number(data, 16, 4) == 16
            && number(data, 20, 2) == 1 && number(data, 22, 2) == 1 && (8_000...48_000).contains(number(data, 24, 4))
            && number(data, 34, 2) == 16 && tag(36) == "data" && number(data, 40, 4) == data.count - 44
    }

    /// How long `data` runs, in seconds, by its header's own figures. 0 if they're missing.
    static func seconds(_ data: Data) -> Double {
        guard data.count >= 44 else { return 0 }
        let perSecond = number(data, 28, 4)
        return perSecond > 0 ? Double(data.count - 44) / Double(perSecond) : 0
    }

    /// The transcriber a phone's recording is given to, or nil where there is none
    /// (before macOS 26). `done` is called on the main thread.
    static var transcriber: ((Data, @escaping (Result<String, Failure>) -> Void) -> Void)? {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else { return nil }
        return { data, done in
            Task {
                let result: Result<String, Failure>
                do { result = .success(try await words(in: data)) }
                catch { result = .failure(Failure((error as? MicEar.Failure)?.why ?? error.localizedDescription)) }
                await MainActor.run { done(result) }
            }
        }
    }

    struct Failure: Error, Equatable {
        let why: String
        init(_ why: String) { self.why = why }
    }

    /// Word for word: the page sends what you're saying a piece at a time (plain 16-bit
    /// sound, one channel, `rate` samples a second), and each piece's answer is the
    /// words so far, the newest of them still a guess. The piece marked `last` gets the
    /// words as they finally stand. One dictation at a time: a new `id` ends the one
    /// before. nil where there's no transcriber. `done` is called on the main thread.
    static var live: ((_ id: String, _ rate: Int, _ sound: Data, _ last: Bool,
                       _ done: @escaping (Result<String, Failure>) -> Void) -> Void)? {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else { return nil }
        return { id, rate, sound, last, done in
            // On the main thread, like everything the page's server does.
            let hearing: LiveDictation
            if let now = current as? LiveDictation, now.id == id {
                hearing = now
            } else {
                (current as? LiveDictation)?.end()
                hearing = LiveDictation(id: id, rate: rate)
                current = hearing
            }
            hearing.take(sound, last: last) { result in
                if last || (try? result.get()) == nil, (current as? LiveDictation) === hearing { current = nil }
                done(result)
            }
        }
    }
    /// The first dictation after the agent starts would wait some seconds for the
    /// transcriber's model to load (4 to 5 s, timed 10-08). A moment of silence put
    /// through it at start means the first one you say doesn't.
    static func warmUp() {
        live?("warmup", 16_000, Data(count: 9_600), true) { _ in }
    }

    /// The dictation being heard word for word, if one is. Main thread.
    private static var current: AnyObject?
    /// A live dictation the page has stopped sending to is let go after this long.
    static let liveIdle: TimeInterval = 20
    /// The most one live dictation may run: the page stops at two minutes.
    static let liveLongest: TimeInterval = 180

    /// What a recording's file is called while the transcriber reads it.
    static let filePrefix = "speakhud-dictation-"

    /// Delete any recording left behind in `dir`: one the transcriber never finished
    /// with outlives the agent that was waiting on it. Run when the agent starts, when
    /// nothing can be in the middle of being heard. Returns how many went.
    @discardableResult
    static func sweep(in dir: String = NSTemporaryDirectory()) -> Int {
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(filePrefix) }
        return left.filter { (try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent($0))) != nil }.count
    }

    /// The words said in a recording. It's written to a file of your own for the
    /// transcriber to read, and the file goes as soon as it has been.
    @available(macOS 26.0, *)
    static func words(in data: Data) async throws -> String {
        let path = NSTemporaryDirectory() + "\(filePrefix)\(UUID().uuidString).wav"
        guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw MicEar.Failure("the recording couldn't be kept long enough to hear it")
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: URL(fileURLWithPath: path)) }
        catch { throw MicEar.Failure("the recording isn't sound this Mac can read") }
        let transcriber = await MicEar.transcriber()
        try await MicEar.install(transcriber)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // A transcriber that hasn't finished in `patience` is stopped where it is.
        let began = Date()
        let watch = Task {
            try? await Task.sleep(nanoseconds: UInt64(patience * 1_000_000_000))
            if !Task.isCancelled { await analyzer.cancelAndFinishNow() }
        }
        defer { watch.cancel() }
        // Each result is one stretch of speech, guessed at and then final: the finals are it.
        async let heard: String = {
            var settled = ""
            for try await result in transcriber.results where result.isFinal { settled += String(result.text.characters) }
            return settled
        }()
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let words = try await heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Date().timeIntervalSince(began) < patience else { throw MicEar.Failure("the Mac took too long to hear it") }
        return words
    }
}

/// One dictation from the phone, heard as it's said: the transcriber is kept open, each
/// piece of sound the page sends is fed to it, and its words so far are there to read.
/// Everything here runs on the main thread except the transcriber's own work.
@available(macOS 26.0, *)
final class LiveDictation: @unchecked Sendable {
    let id: String
    private let rate: Int
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var converter: AVAudioConverter?
    private var from: AVAudioFormat?
    private var to: AVAudioFormat?
    private var opening: Task<Void, Never>?
    private var results: Task<Void, Never>?
    private var problem: String?
    private var settled = ""      // the stretches of speech that are final
    private var guess = ""        // the stretch being said: it changes as more is heard
    private var samples = 0
    private var idle: DispatchWorkItem?
    private var ended = false

    init(id: String, rate: Int) {
        self.id = id
        self.rate = rate
    }

    var text: String { (settled + guess).trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Feed it `sound`; `done` gets the words so far, or, for the `last` piece, the words
    /// as they finally stand once the transcriber has heard everything.
    func take(_ sound: Data, last: Bool, done: @escaping (Result<String, Dictation.Failure>) -> Void) {
        guard !ended else { return done(.failure(Dictation.Failure("that dictation is over"))) }
        idle?.cancel()
        let quiet = DispatchWorkItem { [weak self] in self?.end() }
        idle = quiet
        DispatchQueue.main.asyncAfter(deadline: .now() + Dictation.liveIdle, execute: quiet)
        if opening == nil { opening = Task { await self.open() } }
        let ready = opening
        Task {
            await ready?.value   // the first piece waits for the transcriber; the rest find it open
            await MainActor.run {
                if let problem = self.problem { self.end(); return done(.failure(Dictation.Failure(problem))) }
                guard !self.ended else { return done(.failure(Dictation.Failure("that dictation is over"))) }
                self.samples += sound.count / 2
                if Double(self.samples) / Double(self.rate) > Dictation.liveLongest {
                    self.end()
                    return done(.failure(Dictation.Failure("that's more than the Mac hears in one go")))
                }
                self.hand(sound)
                if last { self.finish(done) } else { done(.success(self.text)) }
            }
        }
    }

    /// Ready the transcriber and start reading its results. Leaves `problem` set if it can't.
    private func open() async {
        do {
            let transcriber = await MicEar.transcriber()
            try await MicEar.install(transcriber)
            guard let to = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
                  let from = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: from, to: to) else {
                throw MicEar.Failure("the phone's sound can't be made into what the transcriber takes")
            }
            converter.primeMethod = .none
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: stream)
            await MainActor.run {
                (self.analyzer, self.feed, self.converter, self.from, self.to) = (analyzer, feed, converter, from, to)
            }
            results = Task {
                do {
                    for try await result in transcriber.results {
                        let piece = String(result.text.characters), final = result.isFinal
                        await MainActor.run {
                            if final { self.settled += piece; self.guess = "" } else { self.guess = piece }
                        }
                    }
                } catch {
                    let why = error.localizedDescription
                    await MainActor.run { self.problem = self.problem ?? why }
                }
            }
        } catch {
            let why = (error as? MicEar.Failure)?.why ?? error.localizedDescription
            await MainActor.run { self.problem = why }
        }
    }

    /// One piece of the page's sound, to the transcriber.
    private func hand(_ sound: Data) {
        let frames = sound.count / 2
        guard frames > 0, let from = from, let to = to, let converter = converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(frames)),
              let room = buffer.int16ChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        sound.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(room[0], base, frames * 2) }
        }
        if let out = MicEar.convert(buffer, with: converter, to: to) { feed?.yield(AnalyzerInput(buffer: out)) }
    }

    /// No more sound is coming: let the transcriber finish what it has, then say the words.
    private func finish(_ done: @escaping (Result<String, Dictation.Failure>) -> Void) {
        ended = true
        idle?.cancel()
        feed?.finish()
        let analyzer = self.analyzer, results = self.results
        Task {
            var failure: String?
            do { try await analyzer?.finalizeAndFinishThroughEndOfInput() }
            catch { failure = error.localizedDescription }
            await results?.value
            let trouble = failure
            await MainActor.run {
                if let why = trouble ?? self.problem { done(.failure(Dictation.Failure(why))) } else { done(.success(self.text)) }
            }
        }
    }

    /// Stop hearing it, with nothing more to say: a new dictation has begun, or the page
    /// went quiet.
    func end() {
        guard !ended else { return }
        ended = true
        idle?.cancel()
        feed?.finish()
        results?.cancel()
        if let analyzer = analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }
}

// ---------------------------------------------------------------------------
// The ear: the mic, and the Mac's own transcriber turning what it hears into words
// (SpeechAnalyzer, macOS 26). On-device: nothing said leaves the Mac. The model is the
// system's; this app's first use registers it, and downloads it if the Mac lacks it.
// ---------------------------------------------------------------------------

@available(macOS 26.0, *)
final class MicEar: Ear, @unchecked Sendable {
    weak var listener: Playback?

    // Main thread only, like everything Playback calls. The work of getting ready
    // happens off it and comes back to it before the mic opens.
    private var window = 0   // the window being listened for; 0 when shut
    private var task: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?

    struct Failure: Error {
        let why: String
        init(_ why: String) { self.why = why }
    }

    /// Where the sound comes from: the mic, or a recording played in as if it were said
    /// (tests/EarTests.swift, so the transcriber is tried for real without a sound).
    enum Source { case microphone, recording(String) }
    private let source: Source
    init(source: Source = .microphone) { self.source = source }

    /// Buffers handed to the transcriber for the open window, counted from the audio
    /// thread. Logged when the window shuts: none at all means the mic gave nothing.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
    private var tally: Tally?
    private var player: Task<Void, Never>?

    static let micDenied = "microphone access is off for SpeakHUD (System Settings › Privacy & Security › Microphone)"

    func listen(window id: Int, overSpeech: Bool) {
        stop()
        window = id
        task = Task { [weak self] in await self?.run(id, overSpeech: overSpeech) }
    }

    func stop() {
        window = 0
        task?.cancel()
        task = nil
        player?.cancel()
        player = nil
        if let t = tally { listener?.log("mic shut after \(t.count) buffers") }
        tally = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        feed?.finish()
        feed = nil
        if let a = analyzer { Task { await a.cancelAndFinishNow() } }
        analyzer = nil
    }

    /// Ask for the mic and ready the model now, so the first reply window doesn't open
    /// onto a permission prompt. `done` gets what's wrong, or nil, on the main thread.
    func prepare(_ done: @escaping (String?) -> Void) {
        Task {
            var problem: String?
            if !SpeechTranscriber.isAvailable {
                problem = "this Mac's transcriber isn't available"
            } else if !(await AVCaptureDevice.requestAccess(for: .audio)) {
                problem = Self.micDenied
            } else {
                do { try await Self.install(await Self.transcriber()) }
                catch { problem = "the speech model couldn't be readied: \(error.localizedDescription)" }
            }
            let result = problem
            await MainActor.run { done(result) }
        }
    }

    static func transcriber() async -> SpeechTranscriber {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            ?? Locale(identifier: "en-US")
        // Progressive: words are reported as they're heard, and firmed up after.
        return SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    static func install(_ transcriber: SpeechTranscriber) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    private func run(_ id: Int, overSpeech: Bool) async {
        do {
            if case .microphone = source {
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure(Self.micDenied) }
            }
            let transcriber = await Self.transcriber()
            try await Self.install(transcriber)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw Failure("the transcriber offers no audio format")
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
            // For a moment after one mic session shuts, the next can fail to start, or
            // start and then give nothing. Going from the echo-cancelling mic straight to
            // the plain one failed 8 times in 8 ("bad device", tried 10-07), and in use it
            // twice opened to silence. Playback no longer asks for that switch, but a mic
            // is a mic: try again a few times, and don't call it open until sound is
            // arriving and keeps arriving.
            var tries = 0
            while true {
                tries += 1
                do {
                    let open = try await MainActor.run {
                        try self.openMic(for: id, overSpeech: overSpeech, feed: feed, as: format, analyzer: analyzer)
                    }
                    guard open else { feed.finish(); return }
                    if try await soundArrives(for: id, within: Self.tryWait(overSpeech: overSpeech)) { break }
                    if tries >= Self.openTries { throw Failure("the microphone opened but gave no sound") }
                } catch let failure as Failure {
                    if tries >= Self.openTries { throw failure }
                }
                await MainActor.run { self.shutEngine() }
                try await Task.sleep(nanoseconds: UInt64(Self.tryGap * 1_000_000_000))
            }
            if tries > 1 {
                let n = tries
                await MainActor.run { self.listener?.log("mic opened on try \(n)") }
            }
            try await analyzer.start(inputSequence: stream)
            await MainActor.run {
                if self.window == id { self.listener?.earOpened(window: id) }
            }
            // Each result is one stretch of speech: guessed at while it's being said,
            // then final. What's reported is everything final plus the current guess.
            var settled = ""
            for try await result in transcriber.results {
                let piece = String(result.text.characters)
                if result.isFinal { settled += piece }
                let text = result.isFinal ? settled : settled + piece
                await MainActor.run {
                    if self.window == id { self.listener?.earHeard(text, window: id) }
                }
                // Over speech the mic is open for as long as there's reading to do, and
                // only short phrases matter: start afresh at a pause rather than grow.
                if overSpeech, result.isFinal, settled.count > 200 { settled = "" }
            }
        } catch is CancellationError {
        } catch {
            let why = (error as? Failure)?.why ?? error.localizedDescription
            await MainActor.run {
                if self.window == id { self.listener?.earFailed(why, window: id) }
            }
        }
    }

    /// A mic gets this many tries at starting. Each is given a while to hand sound on
    /// (longer over speech), with a breath between one try and the next.
    static let openTries = 5
    static func tryWait(overSpeech: Bool) -> TimeInterval { overSpeech ? 2.0 : 1.2 }
    static let tryGap: TimeInterval = 0.35
    /// Readying the transcriber before the first try and starting it after the last.
    /// With its model cold that alone has taken 4 to 5 s (timed 10-08).
    static let readying: TimeInterval = 6

    /// Every try run to its end, and the readying: 13.4 s, or 17.4 s over speech. All
    /// of it is worked out from the numbers the tries themselves run on.
    func opensWithin(overSpeech: Bool) -> TimeInterval {
        Self.readying + Double(Self.openTries) * Self.tryWait(overSpeech: overSpeech)
            + Double(Self.openTries - 1) * Self.tryGap
    }

    /// Whether the mic just opened for `id` is handing sound on, steadily. Throws if
    /// the window is shut meanwhile.
    private func soundArrives(for id: Int, within seconds: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let count = await MainActor.run { self.window == id ? (self.tally?.count ?? 0) : -1 }
            if count < 0 { throw CancellationError() }
            if count >= 3 { return true }   // one buffer and then nothing has been seen
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// Let go of a mic that failed to start or gave nothing, keeping the window, the
    /// feed and the transcriber for the next try. Main thread.
    private func shutEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        tally = nil
    }

    /// Runs on the main thread, where stop() does: a window shut while the model was
    /// being readied must not open the mic after all. False means it was.
    private func openMic(for id: Int, overSpeech: Bool, feed: AsyncStream<AnalyzerInput>.Continuation,
                         as format: AVAudioFormat, analyzer: SpeechAnalyzer) throws -> Bool {
        guard window == id else { return false }
        let tally = Tally()
        if case .recording(let path) = source {
            let file: AVAudioFile
            do { file = try AVAudioFile(forReading: URL(fileURLWithPath: path)) }
            catch { throw Failure("can't read \(path)") }
            let native = file.processingFormat
            guard let converter = AVAudioConverter(from: native, to: format) else {
                throw Failure("the recording can't be converted for the transcriber")
            }
            converter.primeMethod = .none
            // The recording, then quiet for as long as the window stays open, as a mic gives.
            player = Task.detached {
                var playing = true
                while !Task.isCancelled {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: native, frameCapacity: 4096) else { return }
                    if playing {
                        if (try? file.read(into: buffer)) == nil || buffer.frameLength == 0 { playing = false }
                    }
                    if !playing {
                        buffer.frameLength = buffer.frameCapacity
                        for c in 0..<Int(native.channelCount) {
                            if let samples = buffer.floatChannelData?[c] {
                                memset(samples, 0, Int(buffer.frameCapacity) * MemoryLayout<Float>.size)
                            }
                        }
                        try? await Task.sleep(nanoseconds: UInt64(4096 / native.sampleRate * 1_000_000_000))
                    }
                    if let out = Self.convert(buffer, with: converter, to: format) {
                        feed.yield(AnalyzerInput(buffer: out))
                        tally.add()
                    }
                }
            }
            self.tally = tally
            self.feed = feed
            self.analyzer = analyzer
            return true
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if overSpeech {
            // Voice processing cancels what the Mac is playing out of what the mic hears.
            // Tried here 10-07 with the voice reading a 24-word phrase over the speakers:
            // the plain mic gave the transcriber 20 of the words, this gave it none.
            do { try input.setVoiceProcessingEnabled(true) } catch {
                throw Failure("echo cancelling wouldn't start: \(error.localizedDescription)")
            }
            // It also turns other sound down while it's on. As little as it allows: the
            // other sound is the voice.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else { throw Failure("no microphone") }
        // The first channel alone. With voice processing on, the mic reports nine, and
        // converting all nine down to one gave the transcriber silence (same trial): the
        // first is the processed one. A plain mic has only the one.
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: native.sampleRate,
                                       channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: format) else {
            throw Failure("the mic's audio can't be converted for the transcriber")
        }
        converter.primeMethod = .none   // no lead-in: every buffer is converted whole
        input.installTap(onBus: 0, bufferSize: 4096, format: native) { tapped, _ in
            guard let source = tapped.floatChannelData,
                  let first = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: tapped.frameLength),
                  let samples = first.floatChannelData else { return }
            first.frameLength = tapped.frameLength
            memcpy(samples[0], source[0], Int(tapped.frameLength) * MemoryLayout<Float>.size)
            if let out = Self.convert(first, with: converter, to: format) {
                feed.yield(AnalyzerInput(buffer: out))
                tally.add()
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw Failure("the microphone wouldn't start: \(error.localizedDescription)")
        }
        self.engine = engine
        self.tally = tally
        self.feed = feed
        self.analyzer = analyzer
        return true
    }

    /// One mic buffer in the transcriber's format (its sample rate and layout differ).
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, state in
            if fed { state.pointee = .noDataNow; return nil }
            fed = true
            state.pointee = .haveData
            return buffer
        }
        return status != .error && out.frameLength > 0 ? out : nil
    }
}

// ---------------------------------------------------------------------------
// The HUD: renders Playback's state and wires the buttons, hotkeys and mic to it.
// ---------------------------------------------------------------------------

final class Controller: NSObject, NSWindowDelegate, NSTextViewDelegate {
    let playback: Playback
    var queue: [SpeechItem] { playback.queue }

    /// Standalone reader exits; the agent just hides the panel and keeps listening.
    var onIdle: () -> Void = { NSApp.terminate(nil) }
    /// Where queue transitions go. The agent points this at its log file.
    var log: (String) -> Void = { _ in }

    var panel: HUDPanel!
    var statusLabel: NSTextField!
    var queueLabel: NSTextField!
    var sourceBadge: SourceBadge!
    var nextLabel: NSTextField!
    var pauseBtn: NSButton!
    var speedBtn: NSButton!
    var skipBtn: NSButton!
    var textView: NSTextView!
    var hideBtn: NSButton!
    var closeTimer: Timer?
    /// Where the item on screen came from. Kept after it finishes, so the pill still
    /// works while the panel waits to hide.
    private var shownOrigin: Origin?
    private let spotlight = Spotlight()
    /// The text on screen (spoken text plus code blocks), and where its commands are typed.
    private var transcript = Transcript(text: "")
    private var shownLinks: [TextLink] { transcript.links }
    private var shownCwd: String?

    /// How long the panel sits there after the queue runs dry. Measured from your last
    /// interaction, not from when speech ended.
    var idleHideDelay: TimeInterval = 15
    /// Last click, scroll, or keypress aimed at the panel. An auto-hide that fires while
    /// you're mid-scroll is the whole "it vanished on me" complaint.
    private var lastInteraction = Date.distantPast
    private var interactionMonitor: Any?
    /// The user put the HUD away. Sticky for the life of the agent, so a chatty session
    /// can't keep shoving the panel back in front of them. Not persisted on purpose:
    /// a hidden-forever HUD across restarts just looks like a broken app.
    private(set) var isMinimized = false
    /// Footer text. The agent appends the hotkeys it actually managed to register.
    var hotkeyHint = "Pause / Resume anywhere:  ⌃⌥P"

    static let rateKey = "speakRateIndex"   // UserDefaults key for persisted speed

    // Mic hold: something else is recording, so we're silent until it stops.
    private var micWatch: AnyObject?
    private var micHold: MicHold!

    /// "Pause While Recording". Off releases any hold now; on while something's
    /// recording holds now. Persisted in the shared suite.
    var pauseWhileRecording: Bool {
        get { micHold.enabled }
        set {
            micHold.setEnabled(newValue)
            MicHold.store(newValue, in: prefs)
            log("pause while recording: \(newValue ? "on" : "off")")
        }
    }

    // Listen After Reading: once a Claude Code turn has been read, the mic opens and
    // what you say goes back to its terminal (Playback's reply window, Reply, MicEar).
    static let listenKey = "listenAfterReading"
    /// Whether this Mac can listen at all: the transcriber needs macOS 26.
    let canListen: Bool
    private var prepareEar: ((@escaping (String?) -> Void) -> Void)?

    var listenAfterReading: Bool { playback.listens }
    // Listen While Reading: the mic is open while a turn is read, and a short phrase
    // said on its own is a command (Playback's "commands while reading").
    static let obeyKey = "listenWhileReading"
    var listenWhileReading: Bool { playback.obeys }

    /// Both are off unless you've turned them on. Turning one on asks for the mic there
    /// and then, not in the middle of the next turn; if that goes wrong `problem` hears
    /// why and the setting stays off.
    func setListenAfterReading(_ on: Bool, problem: @escaping (String) -> Void = { _ in }) {
        switchListening(on, was: playback.listens, key: Self.listenKey, name: "listen after reading",
                        problem: problem) { [weak self] in self?.playback.listens = $0 }
    }

    func setListenWhileReading(_ on: Bool, problem: @escaping (String) -> Void = { _ in }) {
        switchListening(on, was: playback.obeys, key: Self.obeyKey, name: "listen while reading",
                        problem: problem) { [weak self] in self?.playback.obeys = $0 }
    }

    private func switchListening(_ on: Bool, was: Bool, key: String, name: String,
                                 problem: @escaping (String) -> Void, apply: @escaping (Bool) -> Void) {
        guard canListen, on != was else { return }
        func set(_ on: Bool) {
            apply(on)
            prefs.set(on, forKey: key)
            log("\(name): \(on ? "on" : "off")")
        }
        guard on, let prepare = prepareEar else { set(on); return }
        prepare { [weak self] why in
            if let why = why {
                self?.log("can't listen: \(why)")
                problem(why)
            } else {
                set(true)
            }
        }
    }

    /// `listens`: false for the one-shot reader, which is only ever the hook's fallback
    /// and gone again when it has spoken. The agent is what listens.
    init(listens: Bool = true) {
        let voice = SpeechVoice()
        var ear: Ear?
        var prepare: ((@escaping (String?) -> Void) -> Void)?
        if #available(macOS 26.0, *) {
            let mic = MicEar()
            ear = mic
            prepare = mic.prepare
        }
        playback = Playback(voice: voice, rateIndex: Self.initialRateIndex(), ear: ear)
        voice.listener = playback
        ear?.listener = playback
        canListen = listens && ear != nil
        prepareEar = prepare
        super.init()
        playback.listens = canListen && prefs.bool(forKey: Self.listenKey)
        playback.obeys = canListen && prefs.bool(forKey: Self.obeyKey)
        playback.onCommand = { _ in NSSound(named: "Bottle")?.play() }   // heard you
        playback.onListen = { [weak self] _ in
            guard let self = self else { return }
            self.closeTimer?.invalidate()
            if !self.isMinimized { self.panel?.orderFrontRegardless() }
            NSSound(named: "Tink")?.play()   // your turn
        }
        playback.onReplied = { outcome in
            NSSound(named: outcome == .sent ? "Pop" : "Basso")?.play()
        }
        playback.onEarFailed = { _ in NSSound(named: "Basso")?.play() }
        micHold = MicHold(enabled: MicHold.storedEnabled(in: prefs)) { [weak self] busy in
            self?.playback.micChanged(busy: busy)
        }
        playback.log = { [weak self] in self?.log($0) }
        playback.onChange = { [weak self] in self?.render($0) }
        playback.onStart = { [weak self] in self?.show($0) }
        playback.onWord = { [weak self] in self?.highlight($0) }
        playback.onRanDry = { [weak self] in
            guard let self = self else { return }
            self.clearHighlight()
            self.scheduleAutoClose(after: self.idleHideDelay)
        }
        playback.onStopped = { [weak self] in
            self?.closeTimer?.invalidate()
            self?.clearHighlight()
            self?.onIdle()
        }
    }

    /// The last speed the user picked, unless an explicit SPEAK_RATE env wins for
    /// this invocation.
    private static func initialRateIndex() -> Int {
        var index = 1
        if let saved = prefs.object(forKey: rateKey) as? Int,
           Playback.rateSteps.indices.contains(saved) {
            index = saved
        }
        if let r = ProcessInfo.processInfo.environment["SPEAK_RATE"], let f = Float(r), f > 0 {
            index = Playback.rateSteps.enumerated().min(by: { abs($0.1 - f) < abs($1.1 - f) })!.0
        }
        return index
    }

    // -- commands ----------------------------------------------------------

    /// Returns true only if the item started speaking straight away.
    @discardableResult
    func enqueue(_ item: SpeechItem) -> Bool { playback.enqueue(item) }

    /// Jump the queue. Used for hotkey reads.
    func playNow(_ item: SpeechItem) { playback.playNow(item) }

    @objc func skip() { playback.skip() }
    @objc func replay() { playback.replay() }
    @objc func togglePause() { playback.togglePause() }

    @objc func changeSpeed() {
        playback.cycleSpeed()
        prefs.set(playback.rateIndex, forKey: Self.rateKey)   // remember it
    }

    /// The source pill was clicked: go to the terminal that's talking.
    func revealSource() {
        guard let origin = shownOrigin else { return }
        let outcome = Reveal.go(origin)
        log("reveal \(sourceBadge.text): \(outcome)")
        switch outcome {
        case .pane(let bounds?):
            spotlight.show(around: Spotlight.flipped(bounds), color: sourceBadge.accent)
            if panel.isVisible { panel.orderFrontRegardless() }   // the HUD stays lit, above the dimming
        case .pane, .app: break
        default: NSSound.beep()
        }
    }

    /// Stop everything and throw the queue away. Note this discards what's waiting —
    /// "Skip" is the one that moves on to the next item.
    @objc func stopAll() { playback.stop() }

    /// Start listening for other apps recording. Silently a no-op before macOS 14.
    func watchMic() {
        guard micWatch == nil, #available(macOS 14.0, *) else { return }
        micWatch = MicWatch { [weak self] busy, who in self?.micChanged(busy, by: who) }
    }

    /// The setting and the release debounce live in MicHold. Who took the mic goes in
    /// the log, so a hold that looks wrong can be traced to an app.
    private func micChanged(_ busy: Bool, by who: String?) {
        if busy { log("mic taken by \(who ?? "an unknown process")") }
        micHold.recordingChanged(busy)
    }

    // -- rendering ---------------------------------------------------------

    /// A new item is current: put its text up. Content is kept current even while
    /// hidden, so restoring shows the real state rather than whatever was on screen
    /// when it was put away.
    private func show(_ item: SpeechItem) {
        closeTimer?.invalidate()
        buildWindowIfNeeded()
        shownCwd = item.cwd
        transcript = Transcript(item)
        shownHeard = nil   // setTranscript() takes the last reply off with the last turn
        setTranscript()
        shownOrigin = item.origin
        sourceBadge.text = item.source
        let frame = Accent.frame(item.origin?.color)
        sourceBadge.accent = frame ?? Accent.color(for: item.source)
        sourceBadge.solid = frame != nil
        sourceBadge.isLink = item.origin != nil
        sourceBadge.setFrameSize(sourceBadge.intrinsicContentSize)
        if !isMinimized { panel.orderFrontRegardless() }
        onVisibilityChange()
    }

    /// The only place the playback labels and buttons are written.
    private func render(_ s: Playback.State) {
        guard panel != nil else { return }
        statusLabel.stringValue = s.status
        pauseBtn.title = s.pauseTitle
        speedBtn.title = s.speedTitle
        queueLabel.stringValue = !s.queued.isEmpty ? "▸ \(s.queued.count) queued"
            : s.putOff > 0 ? "⏳ \(s.putOff) put off" : ""
        nextLabel.attributedStringValue = queuePreview(s.queued)
        skipBtn.isEnabled = s.canSkip
        showHeard(s.heard)
    }

    private var shownHeard: String?

    /// What's been heard in the reply window goes under the turn it answers, and stays
    /// there once sent. Nil takes it away.
    private func showHeard(_ heard: String?) {
        guard heard != shownHeard, let tv = textView, let storage = tv.textStorage else { return }
        shownHeard = heard
        let turn = (transcript.shown as NSString).length
        if storage.length > turn {
            storage.deleteCharacters(in: NSRange(location: turn, length: storage.length - turn))
        }
        guard let heard = heard else { return }
        storage.append(NSAttributedString(string: "\n\n🎙  " + (heard.isEmpty ? "…" : heard), attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]))
        tv.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
    }

    /// "next: Alpha, Beta", each name in its project's color (its terminal's, if known).
    private func queuePreview(_ sources: [String]) -> NSAttributedString {
        guard !sources.isEmpty else { return NSAttributedString(string: "") }
        let dim: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let out = NSMutableAttributedString(string: "next: ", attributes: dim)
        for (i, source) in sources.prefix(3).enumerated() {
            if i > 0 { out.append(NSAttributedString(string: ", ", attributes: dim)) }
            out.append(NSAttributedString(string: source, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: Accent.frame(queue.first { $0.source == source }?.origin?.color)
                    ?? Accent.color(for: source),
            ]))
        }
        if sources.count > 3 { out.append(NSAttributedString(string: "…", attributes: dim)) }
        return out
    }

    /// Transient hide: stopped, or the standalone reader running dry. Distinct from
    /// minimizing — the next thing to speak brings the panel back.
    /// Clicking the HUD takes focus so ⌘C can work; hand it back on the way out, or the
    /// next thing you type goes to an app with no windows left to receive it.
    private func yieldFocus() {
        panel?.returnFocus()
    }

    func hidePanel() {
        closeTimer?.invalidate()
        panel?.orderOut(nil)
        yieldFocus()
        onVisibilityChange()
    }

    /// Put the HUD away and keep it away. Speech carries on; only the panel goes.
    @objc func minimize() {
        guard !isMinimized else { return }
        isMinimized = true
        closeTimer?.invalidate()
        panel?.orderOut(nil)
        yieldFocus()
        log("hud hidden")
        onVisibilityChange()
    }

    /// Bring it back. No-op before anything has ever been spoken — there'd be nothing
    /// in the panel to look at. Brought back with nothing playing (after Stop, or once
    /// the queue ran dry), it auto-hides like any idle panel.
    func restore() {
        isMinimized = false
        guard panel != nil else { onVisibilityChange(); return }
        closeTimer?.invalidate()
        panel.orderFrontRegardless()
        log("hud shown")
        if !playback.state.isActive { scheduleAutoClose(after: idleHideDelay) }
        onVisibilityChange()
    }

    /// Stop also leaves the panel off-screen, so "is it up right now" is the honest
    /// question to toggle on — not whether the user pressed Hide.
    var isPanelVisible: Bool { panel?.isVisible == true }

    @objc func toggleMinimized() { isPanelVisible ? minimize() : restore() }

    /// Lets the menu bar mirror whether the panel is currently up.
    var onVisibilityChange: () -> Void = {}

    // Karaoke-style follow: highlight + scroll to the word currently being spoken.
    private func highlight(_ spoken: NSRange) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = transcript.shown(spoken)
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        if NSMaxRange(range) <= storage.length {
            storage.addAttribute(.backgroundColor, value: NSColor.findHighlightColor, range: range)
            scrollToSpokenWord(range, in: tv)
        }
    }

    /// Keep the spoken word in view with room to spare.
    ///
    /// `scrollRangeToVisible` alone isn't enough for two reasons: it scrolls the minimum
    /// distance, so the word ends up jammed against the bottom edge (often half-clipped,
    /// which reads as "it stopped following"), and glyphs are laid out lazily — on a long
    /// response the line may have no layout yet, so the rect comes back wrong and the
    /// view doesn't move at all.
    private func scrollToSpokenWord(_ range: NSRange, in tv: NSTextView) {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else {
            tv.scrollRangeToVisible(range)
            return
        }
        lm.ensureLayout(forCharacterRange: range)
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        rect.origin.x += tv.textContainerInset.width
        rect.origin.y += tv.textContainerInset.height
        // A couple of lines of context either side, so you can read ahead of the voice.
        tv.scrollToVisible(rect.insetBy(dx: 0, dy: -44))
    }

    // Detection is cheap, but the detector isn't — build it once, not per response.
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Show a response. Leading and paragraph spacing do most of the readability work —
    /// a wall of tightly-set 12pt is hard to find your place in when the highlight is
    /// moving. Attributes go on before `linkify()`, which would otherwise be wiped by
    /// the blanket `addAttributes` here.
    private func setTranscript() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        tv.string = transcript.shown
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        // No paragraphSpacing: the text already carries a blank line between paragraphs,
        // and adding both doubles every gap and wastes the window.
        style.paragraphSpacing = 0
        storage.addAttributes([
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ], range: NSRange(location: 0, length: storage.length))
        // Code blocks: set in, quieter, in a code font. No background — the karaoke
        // highlight clears every background in the text on each word.
        let indented = NSMutableParagraphStyle()
        indented.lineSpacing = 2
        indented.firstLineHeadIndent = 12
        indented.headIndent = 12
        for range in transcript.code where NSMaxRange(range) <= storage.length {
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: indented,
            ], range: range)
        }
        linkify()
    }

    /// Mark URLs, paths and commands in the transcript as real links. Only `.link` (plus
    /// a tooltip, and a code font on commands) is added, so the karaoke highlight (which
    /// only ever touches `.backgroundColor`) can't wipe them out.
    private func linkify() {
        guard let storage = textView?.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.link, range: full)
        storage.removeAttribute(.toolTip, range: full)
        Self.linkDetector?.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match = match, let url = match.url else { return }
            storage.addAttribute(.link, value: url, range: match.range)
        }
        // The hook's links point back into shownLinks by index, through a scheme only
        // textView(_:clickedOnLink:at:) understands.
        for (i, link) in shownLinks.enumerated() where NSMaxRange(link.range) <= storage.length {
            var taken = false
            storage.enumerateAttribute(.link, in: link.range) { v, _, stop in
                if v != nil { taken = true; stop.pointee = true }
            }
            guard !taken, let url = URL(string: "\(Self.linkScheme):\(i)") else { continue }
            var attrs: [NSAttributedString.Key: Any] = [.link: url]
            switch link.action {
            case .open(let path):
                var isDir: ObjCBool = false
                let dir = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                attrs[.toolTip] = dir ? "Show in Finder" : "Open"
            case .load:
                attrs[.toolTip] = "Type into a new terminal window (not run)"
                let size = (storage.attribute(.font, at: link.range.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 13
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: min(size, 12), weight: .regular)
            }
            storage.addAttributes(attrs, range: link.range)
        }
    }

    private static let linkScheme = "speakhud-link"

    /// A path opens; a command is typed into a terminal, never run. URLs fall through
    /// to the text view, which hands them to the default browser.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == Self.linkScheme,
              let i = Int(url.absoluteString.dropFirst(Self.linkScheme.count + 1)),
              shownLinks.indices.contains(i) else { return false }
        switch shownLinks[i].action {
        case .open(let path):
            log("open \(path): \(OpenPath.go(path))")
        case .load(let command):
            let outcome = LoadCommand.go(command, cwd: shownCwd)
            log("command (\(command.count) chars): \(outcome)")
            switch outcome {
            case .loaded, .copied: break
            default: NSSound.beep()
            }
        }
        return true
    }

    /// Clicks, scrolls, and keystrokes aimed at the panel, so the auto-hide can tell
    /// "finished speaking a while ago" from "they're still reading it".
    private func watchInteraction() {
        interactionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            guard let self = self else { return event }
            if event.window === self.panel { self.lastInteraction = Date() }
            return event
        }
    }

    deinit {
        if let m = interactionMonitor { NSEvent.removeMonitor(m) }
    }

    private func clearHighlight() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
    }

    /// Hide once it's been quiet for `seconds` — counted from your last interaction, not
    /// from when speech stopped. Scrolling, selecting, or clicking a link keeps it up;
    /// so does anything still current or waiting (paused, or held by the mic).
    private func scheduleAutoClose(after seconds: TimeInterval) {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.playback.state.isActive { self.scheduleAutoClose(after: seconds); return }
            let quiet = Date().timeIntervalSince(self.lastInteraction)
            guard quiet >= seconds else {
                self.scheduleAutoClose(after: seconds - quiet)   // still being used
                return
            }
            self.onIdle()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        stopAll()
        return false   // stopAll already hid (or terminated) us
    }

    /// The title bar is transparent but still there, so the green button — or a
    /// double-click anywhere along the top — zooms the panel to fill the screen. The
    /// panel then keeps that frame for the life of the agent, and every later read
    /// reopens as a full-screen HUD. Resizing by the edges is fine; zooming never is.
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { false }

    // -- window ------------------------------------------------------------

    func buildWindowIfNeeded() {
        guard panel == nil else { return }
        let w: CGFloat = 500, h: CGFloat = 330
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.minSize = NSSize(width: w, height: 260)   // narrower than this clips the button row
        panel.standardWindowButton(.zoomButton)?.isHidden = true   // zoom is refused; don't advertise it
        panel.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // Who's talking — the loudest thing in the window, because with several
        // terminals queued it's the first thing you need to know. Indented past the
        // traffic lights, which float over this content view (.fullSizeContentView).
        let badge = SourceBadge(frame: NSRect(x: 80, y: h - 34, width: 140, height: SourceBadge.height))
        badge.autoresizingMask = [.minYMargin]
        badge.onClick = { [weak self] in self?.revealSource() }
        content.addSubview(badge)
        panel.link = badge
        sourceBadge = badge

        let queued = NSTextField(labelWithString: "")
        queued.frame = NSRect(x: w - 166, y: h - 31, width: 150, height: 18)
        queued.alignment = .right
        queued.font = .systemFont(ofSize: 11, weight: .medium)
        queued.textColor = .secondaryLabelColor
        queued.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(queued)
        queueLabel = queued

        // Playback state, demoted below the source.
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 18, y: h - 58, width: w - 36, height: 18)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.autoresizingMask = [.width, .minYMargin]
        content.addSubview(label)
        statusLabel = label

        // Full response text — scrollable, auto-follows speech (fills the middle)
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 96, width: w - 32, height: h - 162))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 12)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        // Clicking a detected link hands it to NSWorkspace, i.e. your default browser.
        tv.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        tv.delegate = self   // paths and commands; see textView(_:clickedOnLink:at:)
        scroll.documentView = tv
        content.addSubview(scroll)
        textView = tv

        // What's waiting behind the current item
        let next = NSTextField(labelWithString: "")
        next.frame = NSRect(x: 16, y: 76, width: w - 32, height: 14)
        next.font = .systemFont(ofSize: 10)
        next.textColor = .tertiaryLabelColor
        next.lineBreakMode = .byTruncatingTail
        next.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(next)
        nextLabel = next

        // Hotkey hint (above buttons, pinned to bottom)
        let hint = NSTextField(labelWithString: hotkeyHint)
        hint.frame = NSRect(x: 16, y: 58, width: w - 32, height: 14)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(hint)

        // Buttons (pinned to bottom)
        func button(_ title: String, _ x: CGFloat, _ width: CGFloat, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.frame = NSRect(x: x, y: 16, width: width, height: 26)
            b.bezelStyle = .rounded
            b.autoresizingMask = [.maxYMargin]
            return b
        }
        content.addSubview(button("↻ Replay", 14, 78, #selector(replay)))
        // Titles and enabled state come from render(), the one writer.
        pauseBtn = button("", 96, 86, #selector(togglePause))
        content.addSubview(pauseBtn)
        speedBtn = button("", 186, 70, #selector(changeSpeed))
        content.addSubview(speedBtn)
        skipBtn = button("⏭ Skip", 260, 66, #selector(skip))
        content.addSubview(skipBtn)
        content.addSubview(button("■ Stop", 330, 66, #selector(stopAll)))
        // Hide, not Stop: the panel goes away, the speech keeps going, and the
        // menu-bar item brings it back.
        hideBtn = button("⌄ Hide", 400, 86, #selector(minimize))
        content.addSubview(hideBtn)

        panel.contentView = content

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.maxX - w - 20, y: vf.maxY - h - 20))
        }
        self.panel = panel
        render(playback.state)
        watchInteraction()
    }
}

// ---------------------------------------------------------------------------
// Global hotkey + background agent (read the selection from anywhere)
// ---------------------------------------------------------------------------

// Stored at ~/.config/speakhud/config.json so you can set your own combo.
// Set SPEAKHUD_CONFIG_DIR to point at a different dir (used by tests).
enum HotkeyConfig {
    static let defaultSpec = "ctrl+opt+s"
    static let dirEnv = "SPEAKHUD_CONFIG_DIR"
    static var dir: String {
        if let d = ProcessInfo.processInfo.environment[dirEnv], !d.isEmpty {
            return NSString(string: d).expandingTildeInPath
        }
        return NSString(string: "~/.config/speakhud").expandingTildeInPath
    }
    static var path: String { dir + "/config.json" }

    /// The combo to use, and why it isn't yours when the file is broken. A missing file
    /// is not a problem (you just haven't picked one); anything unusable in a file that
    /// exists is, because otherwise your edit is silently ignored.
    struct Loaded: Equatable {
        let spec: String
        let problem: String?
    }

    static func load() -> Loaded {
        let fallback = { (why: String) in Loaded(spec: defaultSpec, problem: why) }
        guard FileManager.default.fileExists(atPath: path) else { return Loaded(spec: defaultSpec, problem: nil) }
        guard let data = FileManager.default.contents(atPath: path) else { return fallback("can't be read") }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return fallback("isn't valid JSON") }
        guard let obj = json as? [String: Any] else { return fallback("isn't a JSON object") }
        guard let value = obj["hotkey"] else { return fallback("has no \"hotkey\" setting") }
        guard let hk = (value as? String)?.trimmingCharacters(in: .whitespaces), !hk.isEmpty else {
            return fallback("\"hotkey\" isn't a non-empty string")
        }
        guard parseHotkey(hk) != nil else {
            return fallback("hotkey \"\(hk)\" isn't a valid combo (need ≥1 modifier + a key)")
        }
        return Loaded(spec: hk, problem: nil)
    }

    @discardableResult
    static func save(_ spec: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let json = "{\n  \"hotkey\": \"\(spec)\"\n}\n"
        return (try? json.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    /// Write the default only if there's no file yet — never over one you're editing,
    /// broken or not.
    @discardableResult
    static func ensureFile() -> Bool {
        FileManager.default.fileExists(atPath: path) || save(defaultSpec)
    }

    /// "ctrl+opt+s" → "⌃⌥S", in the order macOS menus draw modifiers.
    static func label(_ spec: String) -> String {
        var mods = Set<String>(), key = ""
        for raw in spec.lowercased().split(separator: "+") {
            switch raw.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command", "⌘": mods.insert("⌘")
            case "ctrl", "control", "⌃": mods.insert("⌃")
            case "opt", "option", "alt", "⌥": mods.insert("⌥")
            case "shift", "⇧": mods.insert("⇧")
            case let k: key = k
            }
        }
        let isFKey = key.count > 1 && key.hasPrefix("f") && key.dropFirst().allSatisfy(\.isNumber)
        let shown = key.count == 1 || isFKey ? key.uppercased() : key.capitalized
        return ["⌃", "⌥", "⇧", "⌘"].filter(mods.contains).joined() + shown
    }
}

// `--set-hotkey`: save the combo, then restart the agent so it takes effect. Says what
// actually happened at each step instead of "hotkey set" regardless. The launchctl call
// is injected so the decision is testable without touching the live LaunchAgent.
enum SetHotkey {
    static let agentLabel = "com.chris.speakhud.agent"
    /// What `launchctl kickstart` said. launchctl exits 113 when the label isn't loaded.
    struct Kick: Equatable {
        let status: Int32
        let output: String
    }
    static let notLoadedStatus: Int32 = 113

    struct Outcome: Equatable {
        let message: String
        let exitCode: Int32
    }

    static func run(_ spec: String,
                    save: (String) -> Bool = { HotkeyConfig.save($0) },
                    kick: () throws -> Kick = kickAgent) -> Outcome {
        guard save(spec) else {
            return Outcome(message: "error: couldn't save \(spec) to \(HotkeyConfig.path) — nothing changed", exitCode: 1)
        }
        let result: Kick
        do { result = try kick() } catch {
            return Outcome(message: "error: saved \(spec), but couldn't run launchctl to restart the agent: \(error.localizedDescription)",
                           exitCode: 1)
        }
        let said = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch result.status {
        case 0:
            return Outcome(message: "hotkey set to \(spec) — agent restarted", exitCode: 0)
        case notLoadedStatus:
            return Outcome(message: "hotkey saved as \(spec); agent not running, takes effect when it starts", exitCode: 0)
        default:
            return Outcome(message: "error: saved \(spec), but restarting the agent failed (launchctl exit \(result.status))"
                                    + (said.isEmpty ? "" : ": \(said)"),
                           exitCode: 1)
        }
    }

    /// The real restart. Only `Main` calls this; tests inject their own.
    static func kickAgent() throws -> Kick {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(agentLabel)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Kick(status: p.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }
}

// Installs/removes the Claude Code "Stop" hook that reads each response aloud, so
// a downloaded copy can replicate the author's setup with one click. This is the one
// install path: the menu item, --setup-claude, and build.sh (which shells out to
// --setup-claude) all land here. An install is three pieces — read-summary.py, the
// reader binary the hook falls back to, and the settings.json entry — and status()
// checks all three, so a missing or out-of-date file shows up as `.stale` rather than
// hiding behind a present settings entry. Edits to settings.json are merges: other keys,
// groups and sibling hooks are preserved.
// Set SPEAKHUD_CLAUDE_DIR to point at a different dir (used by tests).
enum ClaudeHook {
    enum Status: String {
        case installed
        case stale                          // entry present, but a file is missing or out of date
        case notInstalled = "not installed"
    }

    static var defaultDir: String { NSString(string: "~/.claude").expandingTildeInPath }
    static var dir: String {
        if let d = ProcessInfo.processInfo.environment["SPEAKHUD_CLAUDE_DIR"], !d.isEmpty {
            return NSString(string: d).expandingTildeInPath
        }
        return defaultDir
    }
    static var settingsPath: String { dir + "/settings.json" }
    static var scriptPath: String { dir + "/read-summary.py" }
    static var binDir: String { dir + "/bin" }
    static var binPath: String { binDir + "/speak-hud" }

    /// The command registered in settings.json. For the real dir it stays the portable
    /// `~` form; with SPEAKHUD_CLAUDE_DIR set it names the overridden script, so the entry
    /// and the file it runs never disagree. (read-summary.py's own fallback still looks
    /// for ~/.claude/bin/speak-hud — the override exists for tests, which never run it.)
    static var hookCommand: String {
        if dir == defaultDir { return "python3 ~/.claude/read-summary.py" }
        return "python3 '" + scriptPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// read-summary.py shipped inside SpeakHUD.app. Nil when running outside the bundle
    /// (e.g. as ~/.claude/bin/speak-hud).
    static var bundledScript: URL? { Bundle.main.url(forResource: "read-summary", withExtension: "py") }

    /// The file this process is running from, absolute and with symlinks resolved.
    /// argv[0] isn't good enough: it's relative when invoked via PATH or `./`.
    static var runningExecutable: URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size) + 1)
        if _NSGetExecutablePath(&buf, &size) == 0, let real = realpath(buf, nil) {
            defer { free(real) }
            return URL(fileURLWithPath: String(cString: real))
        }
        return Bundle.main.executableURL?.resolvingSymlinksInPath()
    }

    // MARK: settings.json

    private enum Settings { case missing, invalid, ok([String: Any]) }

    private static func readSettings() -> Settings {
        guard let data = FileManager.default.contents(atPath: settingsPath) else { return .missing }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .invalid }
        return .ok(root)
    }

    private static func stopGroups(_ root: [String: Any]) -> [[String: Any]] {
        (root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
    }
    /// One hook entry (not a group) is ours if it runs read-summary.py.
    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains("read-summary.py") == true
    }
    private static func groupHasOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains(where: isOurs) == true
    }

    // MARK: files

    /// True when both paths name the same file on disk (same device + inode), whatever
    /// the spelling — /tmp vs /private/tmp, symlinks, hard links.
    static func sameFile(_ a: String, _ b: String) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(a, &sa) == 0, stat(b, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    private static func sameContents(_ a: String, _ b: String) -> Bool {
        if sameFile(a, b) { return true }
        let fm = FileManager.default
        guard let sa = (try? fm.attributesOfItem(atPath: a))?[.size] as? NSNumber,
              let sb = (try? fm.attributesOfItem(atPath: b))?[.size] as? NSNumber,
              sa == sb,
              let da = try? Data(contentsOf: URL(fileURLWithPath: a), options: .alwaysMapped),
              let db = try? Data(contentsOf: URL(fileURLWithPath: b), options: .alwaysMapped)
        else { return false }
        return da == db
    }

    /// Copy `src` over `dst` without ever leaving `dst` missing: copy to a temp name in the
    /// same dir, then rename(2) it into place. A no-op when they're already the same file
    /// (`~/.claude/bin/speak-hud --setup-claude`). A symlinked `dst` (say, into a checkout)
    /// is written through, not replaced by a plain file. Returns nil on success, else why not.
    private static func placeFile(from src: String, to link: String, mode: Int) -> String? {
        let fm = FileManager.default
        let dst = (link as NSString).resolvingSymlinksInPath
        if sameFile(src, dst) { return nil }
        guard fm.isReadableFile(atPath: src) else { return "can't read \(src)" }
        let tmp = (dst as NSString).deletingLastPathComponent
            + "/.\((dst as NSString).lastPathComponent).tmp-\(getpid())"
        try? fm.removeItem(atPath: tmp)
        do {
            try fm.copyItem(atPath: src, toPath: tmp)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp)
        } catch {
            try? fm.removeItem(atPath: tmp)
            return "copy \(src) failed: \(error.localizedDescription)"
        }
        guard rename(tmp, dst) == 0 else {
            let why = String(cString: strerror(errno))
            try? fm.removeItem(atPath: tmp)
            return "couldn't replace \(dst): \(why)"
        }
        return nil
    }

    // MARK: public surface

    /// Three-way status plus, when stale, what's wrong. `script`/`binary` are what an
    /// install would copy from; a nil source can't be compared, so only presence counts.
    static func check(script: URL? = bundledScript,
                      binary: URL? = runningExecutable) -> (status: Status, problems: [String]) {
        let root: [String: Any]
        switch readSettings() {
        case .missing: return (.notInstalled, [])
        case .invalid: return (.notInstalled, ["\(settingsPath) is not valid JSON"])
        case .ok(let r): root = r
        }
        guard stopGroups(root).contains(where: groupHasOurs) else { return (.notInstalled, []) }
        let fm = FileManager.default
        var problems: [String] = []
        if !fm.fileExists(atPath: scriptPath) {
            problems.append("script missing")
        } else if let s = script, !sameContents(s.path, scriptPath) {
            problems.append("script differs from bundled copy")
        }
        if !fm.isExecutableFile(atPath: binPath) {
            problems.append("binary missing")
        } else if let b = binary, !sameContents(b.path, binPath) {
            problems.append("binary differs from this build")
        }
        return (problems.isEmpty ? .installed : .stale, problems)
    }

    static func status(script: URL? = bundledScript, binary: URL? = runningExecutable) -> Status {
        check(script: script, binary: binary).status
    }

    /// Refresh the script and binary where copies already exist, without touching
    /// settings.json. For a hook registered somewhere we don't read (settings.local.json,
    /// a project's settings) or a settings.json we can't parse: a rebuild still shouldn't
    /// leave those copies running old code. Returns what it did, or "error: …".
    static func refreshFiles(script: URL? = bundledScript, binary: URL? = runningExecutable) -> String {
        let fm = FileManager.default
        var done: [String] = [], problems: [String] = []
        if let s = script, fm.fileExists(atPath: scriptPath) {
            if let e = placeFile(from: s.path, to: scriptPath, mode: 0o644) { problems.append("script: \(e)") }
            else { done.append("script") }
        }
        if let b = binary, fm.fileExists(atPath: binPath) {
            if let e = placeFile(from: b.path, to: binPath, mode: 0o755) { problems.append("binary: \(e)") }
            else { done.append("binary") }
        }
        if !problems.isEmpty { return "error: " + problems.joined(separator: "; ") }
        return done.isEmpty ? "nothing to refresh" : "refreshed " + done.joined(separator: ", ")
    }

    /// Install or repair all three pieces. Returns "installed", or "error: …" naming every
    /// step that failed. Idempotent: re-running refreshes the files and leaves an existing
    /// settings entry alone.
    @discardableResult
    static func install(script: URL? = bundledScript, binary: URL? = runningExecutable) -> String {
        let fm = FileManager.default
        // Settings first: if the file can't be parsed, touch nothing at all.
        var root: [String: Any] = [:]
        switch readSettings() {
        case .invalid: return "error: \(settingsPath) is not valid JSON — left it untouched"
        case .ok(let r): root = r
        case .missing: break
        }
        do { try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true) }
        catch { return "error: couldn't create \(binDir): \(error.localizedDescription)" }

        var problems: [String] = []
        if let s = script {
            if let e = placeFile(from: s.path, to: scriptPath, mode: 0o644) { problems.append("script: \(e)") }
        } else if !fm.fileExists(atPath: scriptPath) {
            problems.append("script: no bundled read-summary.py to install (run this from SpeakHUD.app)")
        }
        // Registering a hook that points at nothing is the silent failure we're avoiding.
        guard fm.fileExists(atPath: scriptPath) else {
            return "error: " + problems.joined(separator: "; ") + " — hook not registered"
        }
        if let b = binary {
            if let e = placeFile(from: b.path, to: binPath, mode: 0o755) { problems.append("binary: \(e)") }
        } else {
            problems.append("binary: couldn't locate the running executable")
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var stop = hooks["Stop"] as? [[String: Any]] ?? []
        if !stop.contains(where: groupHasOurs) {
            stop.append(["hooks": [["type": "command", "command": hookCommand, "async": true]]])
            hooks["Stop"] = stop
            root["hooks"] = hooks
            if !write(root) { problems.append("settings: couldn't write \(settingsPath)") }
        }
        return problems.isEmpty ? "installed" : "error: " + problems.joined(separator: "; ")
    }

    /// Remove only our entry. Sibling hooks in the same group stay; a group is dropped
    /// only once it's empty. The script and binary are left in place.
    @discardableResult
    static func remove() -> String {
        var root: [String: Any]
        switch readSettings() {
        case .missing: return "nothing to remove"
        case .invalid: return "error: \(settingsPath) is not valid JSON — left it untouched"
        case .ok(let r): root = r
        }
        guard var hooks = root["hooks"] as? [String: Any],
              let stop = hooks["Stop"] as? [[String: Any]],
              stop.contains(where: groupHasOurs)
        else { return "nothing to remove" }
        let kept: [[String: Any]] = stop.compactMap { group in
            guard var inner = group["hooks"] as? [[String: Any]], inner.contains(where: isOurs)
            else { return group }
            inner.removeAll(where: isOurs)
            if inner.isEmpty { return nil }
            var g = group
            g["hooks"] = inner
            return g
        }
        if kept.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = kept }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return write(root) ? "removed" : "error: couldn't write \(settingsPath)"
    }

    private static func write(_ root: [String: Any]) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: root,
                                                     options: [.prettyPrinted, .sortedKeys]),
              var text = String(data: data, encoding: .utf8) else { return false }
        // JSONSerialization escapes every "/" as "\/"; undo that for a clean config file.
        text = text.replacingOccurrences(of: "\\/", with: "/") + "\n"
        return (try? text.write(toFile: settingsPath, atomically: true, encoding: .utf8)) != nil
    }
}

// Human combo like "ctrl+opt+s" -> (Carbon keycode, modifier mask).
let keyCodeMap: [String: UInt32] = [
    "a":0x00,"s":0x01,"d":0x02,"f":0x03,"h":0x04,"g":0x05,"z":0x06,"x":0x07,"c":0x08,
    "v":0x09,"b":0x0B,"q":0x0C,"w":0x0D,"e":0x0E,"r":0x0F,"y":0x10,"t":0x11,"o":0x1F,
    "u":0x20,"i":0x22,"p":0x23,"l":0x25,"j":0x26,"k":0x28,"n":0x2D,"m":0x2E,
    "1":0x12,"2":0x13,"3":0x14,"4":0x15,"5":0x17,"6":0x16,"7":0x1A,"8":0x1C,"9":0x19,"0":0x1D,
    "space":0x31,"return":0x24,"tab":0x30,
    "f1":0x7A,"f2":0x78,"f3":0x63,"f4":0x76,"f5":0x60,"f6":0x61,"f7":0x62,"f8":0x64,
    "f9":0x65,"f10":0x6D,"f11":0x67,"f12":0x6F,
]

func parseHotkey(_ spec: String) -> (keyCode: UInt32, mods: UInt32)? {
    var mods: UInt32 = 0
    var key: String?
    for raw in spec.lowercased().split(separator: "+") {
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "cmd", "command", "⌘": mods |= UInt32(cmdKey)
        case "ctrl", "control", "⌃": mods |= UInt32(controlKey)
        case "opt", "option", "alt", "⌥": mods |= UInt32(optionKey)
        case "shift", "⇧": mods |= UInt32(shiftKey)
        case let other: key = other
        }
    }
    guard let k = key, let code = keyCodeMap[k], mods != 0 else { return nil }   // need ≥1 modifier
    return (code, mods)
}

// ---------------------------------------------------------------------------
// The phone. A page that shows each terminal's last turn and takes an answer for it,
// and a push when a turn finishes while you're away. The page is served on this Mac
// only (127.0.0.1): reaching it from a phone is your tailnet's job (`tailscale serve`),
// so nothing here listens on a network. Off until ~/.config/speakhud/phone.json exists
// (`speak-hud --setup-phone`).
// ---------------------------------------------------------------------------

/// Sessions that could be picked up again. Claude Code keeps each as a transcript,
/// ~/.claude/projects/<folder>/<id>.jsonl, which says what it was called and where it
/// ran: enough to open a terminal there and `claude --resume` it.
enum OldSessions {
    struct Session: Equatable {
        var id: String
        var title: String
        var cwd: String
        var at: Date        // when it last wrote anything
    }

    static var root: String { NSString(string: "~/.claude/projects").expandingTildeInPath }
    static let maxAge: TimeInterval = 30 * 86_400
    static let limit = 40
    /// How much of a transcript's end is read for its title and folder. They're written
    /// over and over, so the end has them without reading megabytes of turns.
    static let tailBytes = 400_000

    static func isID(_ s: String) -> Bool {
        s.range(of: #"^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }

    /// The newest sessions first. Only a session's own transcript counts (a file named
    /// for its id, straight in a project folder), and only one that says where it ran.
    static func recent(in root: String = OldSessions.root, now: Date = Date()) -> [Session] {
        let fm = FileManager.default
        var files: [(path: String, id: String, at: Date)] = []
        for folder in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let dir = root + "/" + folder
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".jsonl") {
                let id = String(name.dropLast(6))
                guard isID(id), let at = (try? fm.attributesOfItem(atPath: dir + "/" + name))?[.modificationDate] as? Date,
                      now.timeIntervalSince(at) < maxAge else { continue }
                files.append((dir + "/" + name, id, at))
            }
        }
        return files.sorted { $0.at > $1.at }.prefix(limit).compactMap { file in
            guard let facts = read(file.path) else { return nil }
            let folder = (facts.cwd as NSString).lastPathComponent
            return Session(id: file.id, title: facts.title ?? (folder.isEmpty ? "Claude Code" : folder), cwd: facts.cwd, at: file.at)
        }
    }

    /// A transcript's title (yours from /rename over Claude's own), from its end, and the
    /// folder it was started in, from its beginning: that folder is the project the
    /// session belongs to, and the only place `claude --resume` finds it from. (The
    /// folder Claude later moved to, at the end, is the fallback.) Nil if it never says.
    static func read(_ path: String) -> (title: String?, cwd: String)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        try? handle.seek(toOffset: 0)
        let head = String(decoding: (try? handle.read(upToCount: 65_536)) ?? Data(), as: UTF8.self)
        var custom: String?, ai: String?, cwd: String?, started: String?
        func object(_ line: Substring) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
        func words(_ raw: Any?) -> String? {
            guard let s = raw as? String else { return nil }
            let line = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            return line.isEmpty ? nil : String(line.prefix(120))
        }
        for line in text.split(separator: "\n").reversed() {   // the newest say wins
            if line.contains("-title\""), let o = object(line) {
                if custom == nil, o["type"] as? String == "custom-title" { custom = words(o["customTitle"]) }
                if ai == nil, o["type"] as? String == "ai-title" { ai = words(o["aiTitle"]) }
            } else if cwd == nil, line.contains("\"cwd\""), let o = object(line), let dir = o["cwd"] as? String, dir.hasPrefix("/") {
                cwd = dir
            }
            if cwd != nil, custom != nil { break }
        }
        for line in head.split(separator: "\n") where line.contains("\"cwd\"") {
            if let dir = object(line)?["cwd"] as? String, dir.hasPrefix("/") { started = dir; break }
        }
        return (started ?? cwd).map { (custom ?? ai, $0) }
    }

    /// The ids of sessions a running Claude Code says are its own (it keeps a note per
    /// process in ~/.claude/sessions; not every version writes one).
    static func running(in dir: String = NSString(string: "~/.claude/sessions").expandingTildeInPath) -> Set<String> {
        var ids: Set<String> = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + name),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = o["sessionId"] as? String, let pid = (o["pid"] as? NSNumber)?.int32Value,
                  kill(pid, 0) == 0 else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// The AppleScript that opens a new iTerm2 window in the session's folder and resumes
    /// it there. Only an id that is one and a folder that's a plain path are ever put in.
    static func script(_ session: Session) -> String? {
        guard isID(session.id), LoadCommand.isLoadable(session.cwd) else { return nil }
        let line = "cd " + LoadCommand.shellQuote(session.cwd) + " && claude --resume " + session.id
        return """
        tell application id "\(Reveal.iTerm)"
            set w to (create window with default profile)
            tell current session of w to write text \(LoadCommand.literal(line))
            return "ok"
        end tell
        """
    }

    /// Open it. `run` is what executes the script; tests keep it instead.
    static func resume(_ session: Session, run: (String) -> Reply.Answer = OldSessions.run) -> Reply.Outcome {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDir), isDir.boolValue else {
            return .failed("its folder isn't there any more")
        }
        guard let source = script(session) else { return .failed("that isn't a session that can be resumed") }
        let a = run(source)
        if let code = a.errorCode {
            return code == -1743 ? .denied : .failed(a.errorMessage ?? "AppleScript error \(code)")
        }
        return .sent
    }

    /// Unlike `Reply.ask`, this starts iTerm2 if it isn't running: a terminal is the point.
    static func run(_ source: String) -> Reply.Answer {
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err = err {
            return Reply.Answer(errorCode: err[NSAppleScript.errorNumber] as? Int ?? 0,
                                errorMessage: err[NSAppleScript.errorMessage] as? String)
        }
        return Reply.Answer(reply: result?.stringValue)
    }
}

/// A box Claude Code has up instead of its prompt, read off the terminal's own screen: a
/// question with its choices, a permission prompt, the folder-trust check. The screen is
/// the one thing that's true for all of them, whoever put the box there and whenever the
/// agent started, so this, not the question hook, is what the phone answers from.
struct TerminalBox: Equatable {
    struct Row: Equatable {
        var label: String
        var detail: String? = nil
        var number: Int? = nil       // the digit that picks it, when it has one
        var cursor = false           // the ❯ is on it
        var checked: Bool? = nil     // a pick-any-that-apply row, and whether it's ticked
        /// The row that turns into a text field when picked ("Type something").
        var types: Bool { label.lowercased().hasPrefix("type something") }
    }

    var ask: String                  // what it says above its choices
    var tabs: String? = nil          // "☒ Route  ☐ Extras  ✔ Submit": several questions, and where you are
    var rows: [Row]
    var hints: String? = nil         // "Enter to select · Esc to cancel"

    private static func isRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= 10 && t.allSatisfy { $0 == "─" || $0 == "╌" }
    }

    /// The box at the foot of `screen`, or nil: Claude's prompt is showing, or nothing
    /// that reads as a list of choices with a cursor on one.
    static func read(_ screen: String) -> TerminalBox? {
        guard Reply.promptText(in: screen) == nil else { return nil }
        var lines = screen.components(separatedBy: .newlines).map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        func col(_ line: String) -> Int? {
            line.firstIndex { $0 != " " }.map { line.distance(from: line.startIndex, to: $0) }
        }
        func blank(_ i: Int) -> Bool { lines[i].trimmingCharacters(in: .whitespaces).isEmpty }
        // The cursor: the last line that starts with ❯ and something after it.
        guard let at = lines.lastIndex(where: { l in col(l).map { l.dropFirst($0).hasPrefix("❯ ") } ?? false }),
              let c = col(lines[at]) else { return nil }
        // Its list runs up and down from there: rows start two columns in from the
        // cursor, what's under a row is indented further, and a rule may cross it.
        func inList(_ i: Int) -> Bool {
            if blank(i) { return false }
            if isRule(lines[i]) { return true }
            return i == at || (col(lines[i]) ?? 0) >= c + 2
        }
        var top = at, bottom = at
        while top > 0, inList(top - 1) { top -= 1 }
        while bottom < lines.count - 1, inList(bottom + 1) { bottom += 1 }
        while top < at, isRule(lines[top]) { top += 1 }
        // Under the list there's nothing but its hint line: anything more and that ❯ was
        // a line of the conversation, not a cursor.
        let under = (bottom + 1..<lines.count).filter { !blank($0) }.map { lines[$0].trimmingCharacters(in: .whitespaces) }
        guard under.count <= 1 else { return nil }
        let hints = under.first
        if let h = hints, !(h.contains("Esc") || h.contains("Enter") || h.contains(" · ")) { return nil }

        var rows: [Row] = []
        var labelCol = c + 2
        for i in top...bottom where !isRule(lines[i]) {
            let k = i == at ? c + 2 : (col(lines[i]) ?? 0)
            var text = String(lines[i].dropFirst(min(k, lines[i].count))).trimmingCharacters(in: .whitespaces)
            if i == at { text = String(lines[i].dropFirst(c + 1)).trimmingCharacters(in: .whitespaces) }
            let numbered = text.range(of: #"^\d{1,2}\.\s+"#, options: .regularExpression)
            if k == c + 2, let n = numbered {
                var row = Row(label: String(text[n.upperBound...]), number: Int(text.prefix { $0.isNumber }), cursor: i == at)
                labelCol = k + text.distance(from: text.startIndex, to: n.upperBound)
                if let box = row.label.range(of: #"^\[(.)\]\s+"#, options: .regularExpression) {
                    row.checked = !row.label[box].hasPrefix("[ ]")
                    labelCol += row.label.distance(from: row.label.startIndex, to: box.upperBound)
                    row.label = String(row.label[box.upperBound...])
                }
                rows.append(row)
            } else if k == c + 2 || (k < labelCol && rows.last?.checked != nil) || rows.isEmpty {
                // A row with no number: the trust box's choices, or Submit under a list of ticks.
                rows.append(Row(label: text, cursor: i == at))
            } else {
                // Under a row: its description, or the rest of a label that wrapped.
                rows[rows.count - 1].detail = [rows[rows.count - 1].detail, text].compactMap { $0 }.joined(separator: " ")
            }
        }
        guard rows.count >= 2, rows.contains(where: { $0.cursor }) else { return nil }

        // What it says: from the rule that opens the box down to the list.
        var open = top
        while open > 0, !isRule(lines[open - 1]) || lines[open - 1].contains("╌"), top - open < 40 { open -= 1 }
        var said: [String] = []
        var tabs: String?
        for i in open..<top where !blank(i) && !isRule(lines[i]) {
            let text = lines[i].trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("←") || (said.isEmpty && (text.hasPrefix("☐ ") || text.hasPrefix("☒ "))) {
                // The strip of questions (several), or the one question's own heading.
                tabs = text.trimmingCharacters(in: CharacterSet(charactersIn: "←→ ")).replacingOccurrences(of: "  ", with: " ")
            } else {
                said.append(text)
            }
        }
        return TerminalBox(ask: said.joined(separator: "\n"), tabs: tabs, rows: rows, hints: hints)
    }

    /// The keys that pick row `index` as the box stands: its digit, or the arrows from
    /// where the cursor is and Enter. Nil if there's no such row.
    func keys(toPick index: Int) -> [String]? {
        guard rows.indices.contains(index), let from = rows.firstIndex(where: { $0.cursor }) else { return nil }
        if let n = rows[index].number, (1...9).contains(n) { return [String(n)] }
        let step = index >= from ? "down" : "up"
        return Array(repeating: step, count: abs(index - from)) + ["enter"]
    }

    var json: [String: Any] {
        ["ask": ask, "tabs": tabs as Any? ?? NSNull(), "hints": hints as Any? ?? NSNull(),
         "rows": rows.map { r -> [String: Any] in
            ["label": r.label, "detail": r.detail as Any? ?? NSNull(), "number": r.number as Any? ?? NSNull(),
             "cursor": r.cursor, "checked": r.checked as Any? ?? NSNull(), "types": r.types]
         }]
    }
}

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
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
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
            let box = TerminalBox.read(pane.screen)
            let busy = box == nil && Reply.working(title: pane.name, screen: pane.screen)
            if let i = turns.firstIndex(where: { $0.origin?.session == pane.session }) {
                if turns[i].key.hasPrefix(Self.paneKey) { turns[i].name = Reply.paneName(pane.name) }
                if let box = box, turns[i].box?.ask != box.ask { asking.append(turns[i].key) }
                (turns[i].box, turns[i].busy) = (box, busy)
                if let status = Reply.status(in: pane.screen) { (turns[i].status, turns[i].context) = status }
            } else if box != nil || Reply.showsClaude(pane.screen), turns.count < Self.keep {
                var t = Turn(key: Self.paneKey + pane.session, name: Reply.paneName(pane.name), text: "", at: now,
                             origin: Origin(term: "iTerm.app", session: pane.session))
                (t.box, t.busy) = (box, busy)
                if let status = Reply.status(in: pane.screen) { (t.status, t.context) = status }
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
        turns[i].box = TerminalBox.read(screen)
        if turns[i].box != nil { turns[i].busy = false }
        if let status = Reply.status(in: screen) { (turns[i].status, turns[i].context) = status }
        if turns[i].question != nil, Reply.promptText(in: screen) != nil { (turns[i].question, turns[i].askedAt) = (nil, nil) }
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

/// What the page asks and what it's told, and the push when you're away. No network of
/// its own: PhoneServer hands it requests, and `transport` takes the pushes.
final class Phone {
    static let awayKey = "phoneAway"
    static let cookie = "speakhud"
    static let pushLength = 300
    static let assets = ["/": ("index.html", "text/html; charset=utf-8"),
                         "/app.css": ("app.css", "text/css; charset=utf-8"),
                         "/app.js": ("app.js", "text/javascript; charset=utf-8"),
                         "/mic.js": ("mic.js", "text/javascript; charset=utf-8")]

    /// How often, at most, iTerm2 is asked what its panes are showing: while a page is
    /// polling, or while you're away and a box coming up needs a push.
    static let scanEvery: TimeInterval = 4
    /// A page that asked this recently is still open.
    static let pageOpen: TimeInterval = 15
    /// One push per question, whichever of the hook and the screen sees it first.
    static let askGap: TimeInterval = 120
    /// The answers you send often, as buttons on the page. Yours to change there.
    static let quickKey = "phoneQuick"
    static let quickDefault = ["Yes", "No", "Go ahead", "Wrap up"]
    static let quickLimit = 12

    let config: PhoneConfig
    private(set) var desk: PhoneDesk { didSet { if desk.turns != oldValue.turns { save(desk.snapshot()) } } }
    private let defaults: UserDefaults
    private var scanned = Date.distantPast
    private var polled = Date.distantPast
    private var askPushed: [String: Date] = [:]
    /// Puts the words in a terminal. Tests answer for iTerm2.
    var deliver: (String, Origin) -> Reply.Outcome = { Reply.send($0, to: $1) }
    /// Presses a key in a terminal, and reads the foot of its screen.
    var press: (String, Origin) -> Reply.Outcome = { Reply.press($0, in: $1) }
    var look: (Origin) -> String? = { Reply.screen(of: $0) }
    /// Sends a push. Tests keep the request instead.
    var transport: (URLRequest, @escaping (String?) -> Void) -> Void = Phone.post
    /// A file of the page, by name. The app's are in its bundle; tests read the repo's.
    var asset: (String) -> Data? = { name in
        Bundle.main.resourcePath.flatMap { FileManager.default.contents(atPath: $0 + "/phone/" + name) }
    }
    /// The panes iTerm2 has open and what's on them. Tests answer for it.
    var survey: () -> [Reply.Pane]? = { Reply.survey() }
    /// Types into a terminal's own text field, and waits between keys.
    var type: (String, Origin) -> Reply.Outcome = { Reply.type($0, in: $1) }
    var wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    /// Closes a terminal.
    var shut: (Origin) -> Reply.Outcome = { Reply.close($0) }
    /// The sessions that could be resumed, and what opens one.
    var oldSessions: () -> [OldSessions.Session] = { OldSessions.recent() }
    var reopen: (OldSessions.Session) -> Reply.Outcome = { OldSessions.resume($0) }
    var runningIDs: () -> Set<String> = { OldSessions.running() }

    /// Whether `session` already has a window on the page: resuming it again would put
    /// two terminals on one conversation.
    private func isOpen(_ session: OldSessions.Session) -> Bool {
        desk.turns.contains { $0.key == session.id || ($0.key.hasPrefix(PhoneDesk.paneKey) && $0.name == session.title) }
    }

    var quick: [String] { defaults.stringArray(forKey: Self.quickKey) ?? Self.quickDefault }

    /// Keep `list` as the quick answers: each as it would be sent (one line), no
    /// repeats, no more than `quickLimit`.
    func setQuick(_ list: [String]) {
        var kept: [String] = []
        for raw in list {
            guard let line = Reply.clean(raw).map({ String($0.prefix(200)) }), !kept.contains(line) else { continue }
            kept.append(line)
            if kept.count == Self.quickLimit { break }
        }
        defaults.set(kept, forKey: Self.quickKey)
    }
    /// Turns a recording from the page into words, where this Mac can. Tests answer for it.
    var hear: ((Data, @escaping (Result<String, Dictation.Failure>) -> Void) -> Void)? = Dictation.transcriber
    private var hearing = false
    /// Hears a dictation word for word, a piece of sound at a time (`Dictation.live`).
    var hearLive: ((String, Int, Data, Bool, @escaping (Result<String, Dictation.Failure>) -> Void) -> Void)? = Dictation.live
    /// The dictation being heard word for word: its id, when it began, how much sound so far.
    private var live: (id: String, began: Date, seconds: Double)?
    /// What the page sends a piece of a live dictation as: 16-bit sound and nothing else.
    static let liveType = "audio/pcm"
    /// How long the page waits for its words. Past this the transcriber is taken to be
    /// stuck, the page is told, and the next recording is heard: one that never answers
    /// must not leave every later one turned away.
    var hearPatience: TimeInterval = Dictation.patience + 15
    /// Keeps the list for the next run of the agent. `saved` is what the last one kept.
    var save: (Data) -> Void = { _ in }
    var log: (String) -> Void = { _ in }
    var onAwayChange: (Bool) -> Void = { _ in }

    init(config: PhoneConfig, defaults: UserDefaults = prefs, saved: Data? = nil) {
        self.config = config
        self.defaults = defaults
        desk = PhoneDesk(snapshot: saved)
    }

    /// Ask iTerm2 what's open and showing, so the page lists every Claude Code terminal,
    /// none that has closed, and each one's box. Cheap to call: it asks at most every
    /// `scanEvery`.
    func scan(now: Date = Date()) {
        guard now.timeIntervalSince(scanned) >= Self.scanEvery else { return }
        scanned = now
        guard let open = survey() else { return }   // iTerm2 not running, or not saying: nothing learned
        for key in desk.met(open, now: now) where away {
            guard let turn = desk.turn(key), let box = turn.box, firstAsk(key, now) else { continue }
            push(title: "\(turn.name) is asking", message: box.ask, key: key, name: turn.name)
        }
    }

    /// The agent's heartbeat calls this: keep looking while someone is, or while a box
    /// coming up would otherwise sit there unseen.
    func tick(now: Date = Date()) {
        if away || now.timeIntervalSince(polled) < Self.pageOpen { scan(now: now) }
    }

    /// Whether `key` hasn't been pushed as asking in the last `askGap`; marks it so.
    private func firstAsk(_ key: String, _ now: Date) -> Bool {
        if let last = askPushed[key], now.timeIntervalSince(last) < Self.askGap { return false }
        askPushed[key] = now
        return true
    }

    // -- away --------------------------------------------------------------

    /// Away: finished turns go to the phone instead of being read to an empty room.
    var away: Bool { defaults.bool(forKey: Self.awayKey) }

    func setAway(_ on: Bool) {
        guard on != away else { return }
        defaults.set(on, forKey: Self.awayKey)
        log("away: \(on ? "on — turns go to the phone" : "off")")
        onAwayChange(on)
    }

    // -- turns in ----------------------------------------------------------

    /// A turn or question off the spool. Kept for the page either way; pushed when away.
    /// False when the page has nowhere to show it, so the phone doesn't have it.
    @discardableResult
    func took(_ item: SpeechItem, now: Date = Date()) -> Bool {
        let asking = item.key.hasSuffix(PhoneDesk.questionSuffix)
        guard item.answerable || asking else { return false }   // only Claude Code's turns have a terminal to answer in
        let first = desk.took(item, now: now)
        guard away, first else { return true }
        let key = asking ? String(item.key.dropLast(PhoneDesk.questionSuffix.count)) : item.key
        if asking, !firstAsk(key, now) { return true }   // the screen already said so
        // What came with it is said in the title: the words are cut to length.
        let with = PhoneMedia.said(item.media).map { " (\($0))" } ?? ""
        push(title: (asking ? "\(item.source) is asking" : item.source) + with, message: item.text, key: key, name: item.source)
        return true
    }

    /// `text` as a push's body: one line, cut to length.
    static func brief(_ text: String) -> String {
        let line = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return line.count > pushLength ? String(line.prefix(pushLength - 1)) + "…" : line
    }

    /// The push for a terminal, or nil when there's nowhere to send one. A tap on it
    /// opens the page at that terminal's window.
    func pushRequest(title: String, message: String, key: String) -> URLRequest? {
        guard let topicURL = config.ntfy.flatMap({ URL(string: $0) }), !topicURL.lastPathComponent.isEmpty,
              topicURL.lastPathComponent != "/" else { return nil }
        var body: [String: Any] = ["topic": topicURL.lastPathComponent, "title": title, "message": Self.brief(message)]
        if let url = config.url {
            body["click"] = url + "/#" + (key.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
        }
        var request = URLRequest(url: topicURL.deletingLastPathComponent())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("SpeakHUD", forHTTPHeaderField: "User-Agent")
        if let token = config.ntfyToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func push(title: String, message: String, key: String, name: String) {
        guard let request = pushRequest(title: title, message: message, key: key) else {
            log("away: no push for \(name) — phone.json has no ntfy topic")
            return
        }
        transport(request) { [weak self] problem in
            self?.log(problem.map { "away: push for \(name) failed — \($0)" } ?? "away: pushed \(name)")
        }
    }

    /// Sends `request`; `done` gets what went wrong, or nil, on the main queue.
    static func post(_ request: URLRequest, done: @escaping (String?) -> Void) {
        URLSession.shared.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let problem = error?.localizedDescription ?? ((200..<300).contains(code) ? nil : "the server answered \(code)")
            DispatchQueue.main.async { done(problem) }
        }.resume()
    }

    // -- the page ----------------------------------------------------------

    private func paired(_ r: HTTP.Request) -> Bool {
        Self.same(r.cookies[Self.cookie] ?? "", config.token)
    }

    /// Compared without stopping at the first difference, so timing says nothing.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<y.count { diff |= (i < x.count ? x[i] : 0) ^ y[i] }
        return diff == 0
    }

    func state(now: Date = Date()) -> [String: Any] {
        ["away": away,
         "quick": quick,
         "canHear": hear != nil,   // whether a recording sent here comes back as words
         "canHearLive": hearLive != nil,   // and whether it can be heard word for word as it's said
         "turns": desk.turns.map { t -> [String: Any] in
            ["key": t.key, "name": t.name, "text": t.text,
             "at": ((t.askedAt.map { max($0, t.at) } ?? t.at).timeIntervalSince1970).rounded(),
             "color": t.origin?.color as Any? ?? NSNull(),
             "canReply": Reply.canReach(t.origin),
             "question": t.question as Any? ?? NSNull(),
             "sent": t.sent as Any? ?? NSNull(),
             "note": t.note as Any? ?? NSNull(),
             "box": t.box?.json as Any? ?? NSNull(),
             "busy": t.busy,
             "status": t.status as Any? ?? NSNull(),
             "context": t.context as Any? ?? NSNull(),
             // Each by its place in the turn's list, which is all the page ever asks by.
             "media": t.media.enumerated().compactMap { i, path -> [String: Any]? in
                PhoneMedia.file(path).map { ["i": i, "name": $0.name, "kind": $0.kind, "size": $0.size, "v": $0.version] }
             }]
         }]
    }

    // -- pictures from the phone -------------------------------------------

    /// Where a picture sent with an answer is kept for the terminal's Claude to read, and
    /// for how long. The page shrinks it first; here it only has to be a picture.
    var picturesDir = (Spool.dir as NSString).deletingLastPathComponent + "/from-phone"
    static let pictureAge: TimeInterval = 7 * 86_400
    private var pictures: [String: String] = [:]   // what the page was told to call it -> where it is
    private var pictureCount = 0

    /// A picture the page will name in its next answer. It's kept under a name with no
    /// spaces in it, so the path can go into a terminal's prompt as it is.
    private func picture(_ r: HTTP.Request, now: Date = Date()) -> HTTP.Response {
        guard r.headers["x-speakhud"] == "1" else { return .json(["error": "not found"], status: 404) }
        let jpeg = r.body.starts(with: [0xFF, 0xD8, 0xFF])
        let png = r.body.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard jpeg || png else { return .json(["error": "that isn't a picture"], status: 400) }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: picturesDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        pictureCount += 1
        let name = "\(stamp.string(from: now))-\(pictureCount).\(jpeg ? "jpg" : "png")"
        guard fm.createFile(atPath: picturesDir + "/" + name, contents: r.body, attributes: [.posixPermissions: 0o600]) else {
            return .json(["error": "the Mac couldn't keep that picture"], status: 500)
        }
        pictures[name] = picturesDir + "/" + name
        return .json(["id": name])
    }

    /// Pictures from the phone are for the turn they went with: old ones go.
    func sweepPictures(now: Date = Date()) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: picturesDir)) ?? [] {
            let path = picturesDir + "/" + name
            guard let changed = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(changed) > Self.pictureAge else { continue }
            try? fm.removeItem(atPath: path)
        }
    }

    /// A file a turn made or named, for the page to show under it. Asked for by the
    /// turn and its place in that turn's list, so nothing else on this Mac can be.
    private func media(_ r: HTTP.Request) -> HTTP.Response {
        guard let turn = desk.turn(r.query["key"] ?? ""), let i = Int(r.query["i"] ?? ""), turn.media.indices.contains(i),
              let file = PhoneMedia.file(turn.media[i]) else {
            return .json(["error": "that file isn't there any more"], status: 404)
        }
        let range = r.headers["range"]
        // To keep on the phone: always the file itself, never the lighter copy of a picture.
        let save = r.query["save"] == "1"
        if HTTP.range(range, of: file.size) != .none, range == nil || range?.hasPrefix("bytes=0-") == true {
            log("phone \(save ? "saved" : "shown") \(file.name) (\(file.kind), \(file.size / 1024) KB) from \(turn.name)")
        }
        if save { return .file(file.path, size: file.size, type: file.type, range: range, save: true) }
        if PhoneMedia.sendsSmaller(file), let side = Int(r.query["w"] ?? ""),
           let small = PhoneMedia.small(file.path, side: min(max(side, 64), 2400)) {
            return HTTP.Response(type: small.type, headers: [("Cache-Control", "private, max-age=3600")], body: small.data)
        }
        return .file(file.path, size: file.size, type: file.type, range: range)
    }

    /// The one request whose answer takes a while: a recording of what you said, to be
    /// turned into words for the page's answer box. False for any other request, which
    /// `respond` answers at once. The words are never logged, only how many.
    func respondLater(to r: HTTP.Request, done: @escaping (HTTP.Response) -> Void) -> Bool {
        guard r.method == "POST", r.path == "/api/hear" else { return false }
        guard paired(r) else { done(.json(["error": "not paired"], status: 401)); return true }
        guard r.headers["x-speakhud"] == "1" else { done(.json(["error": "not found"], status: 404)); return true }
        if let id = r.query["live"] { hearPiece(r, of: id, done); return true }
        guard let hear = hear else {
            done(.json(["error": "this Mac can't turn speech into words (it needs macOS 26)"], status: 501))
            return true
        }
        guard r.headers["content-type"]?.lowercased().hasPrefix(Dictation.type) == true, Dictation.looksRight(r.body) else {
            done(.json(["error": "that isn't a recording"], status: 400))
            return true
        }
        guard !hearing else {
            done(.json(["error": "the Mac is still hearing the last one"], status: 409))
            return true
        }
        hearing = true
        let began = Date(), length = Dictation.seconds(r.body)
        var answered = false
        let finish: (Result<String, Dictation.Failure>) -> Void = { [weak self] result in
            guard !answered else { return }   // the transcriber and the wait for it can both get here
            answered = true
            self?.hearing = false
            let took = String(format: "%.1f", Date().timeIntervalSince(began))
            switch result {
            case .success(let text):
                let words = text.split(whereSeparator: { $0.isWhitespace }).count
                self?.log("phone dictated \(words) word\(words == 1 ? "" : "s") (\(String(format: "%.1f", length)) s of sound, heard in \(took) s)")
                done(.json(["text": text]))
            case .failure(let failure):
                self?.log("phone dictation failed after \(took) s: \(failure.why)")
                done(.json(["error": failure.why], status: 503))
            }
        }
        hear(r.body, finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + hearPatience) {
            finish(.failure(Dictation.Failure("the Mac took too long to hear it")))
        }
        return true
    }

    /// One piece of a dictation being heard word for word: `?live=<the page's name for
    /// this dictation>&rate=<samples a second>`, `&last=1` on the piece that ends it, the
    /// sound itself as the body. The answer is the words so far; the last piece's, the
    /// words as they finally stand. Pairing and the page's header were checked by the caller.
    private func hearPiece(_ r: HTTP.Request, of id: String, _ done: @escaping (HTTP.Response) -> Void) {
        guard let hearLive = hearLive else {
            return done(.json(["error": "this Mac can't turn speech into words (it needs macOS 26)"], status: 501))
        }
        let last = r.query["last"] == "1"
        guard id.range(of: #"^[a-z0-9]{6,32}$"#, options: .regularExpression) != nil,
              let rate = Int(r.query["rate"] ?? ""), (8_000...48_000).contains(rate),
              r.headers["content-type"]?.lowercased().hasPrefix(Self.liveType) == true,
              r.body.count % 2 == 0, last || !r.body.isEmpty else {
            return done(.json(["error": "that isn't a piece of a dictation"], status: 400))
        }
        if live?.id != id { live = (id, Date(), 0) }
        live?.seconds += Double(r.body.count / 2) / Double(rate)
        let heard = live
        var answered = false
        let finish: (Result<String, Dictation.Failure>) -> Void = { [weak self] result in
            guard !answered else { return }
            answered = true
            let took = String(format: "%.1f", Date().timeIntervalSince(heard?.began ?? Date()))
            switch result {
            case .success(let text):
                if last {
                    let words = text.split(whereSeparator: { $0.isWhitespace }).count
                    self?.log("phone dictated \(words) word\(words == 1 ? "" : "s") word for word (\(String(format: "%.1f", heard?.seconds ?? 0)) s of sound, done \(took) s after it began)")
                    if self?.live?.id == id { self?.live = nil }
                }
                done(.json(["text": text]))
            case .failure(let failure):
                self?.log("phone dictation failed \(took) s in: \(failure.why)")
                if self?.live?.id == id { self?.live = nil }
                done(.json(["error": failure.why], status: 503))
            }
        }
        hearLive(id, rate, r.body, last, finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + hearPatience) {
            finish(.failure(Dictation.Failure("the Mac took too long to hear it")))
        }
    }

    func respond(to r: HTTP.Request) -> HTTP.Response {
        if r.method == "GET", r.path == "/pair" {
            guard Self.same(r.query["k"] ?? "", config.token) else {
                return .text("That link doesn't open this Mac. Get a fresh one from SpeakHUD's menu: Phone, Pair a Phone.", status: 403)
            }
            let secure = config.url?.lowercased().hasPrefix("https:") == true ? "; Secure" : ""
            return HTTP.Response(status: 303, type: "text/plain; charset=utf-8", headers: [
                ("Location", "/"),
                ("Set-Cookie", "\(Self.cookie)=\(config.token); Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax\(secure)")])
        }
        guard paired(r) else {
            return r.path.hasPrefix("/api/")
                ? .json(["error": "not paired"], status: 401)
                : .text("This phone isn't paired with the Mac. On the Mac, open SpeakHUD's menu: Phone, Pair a Phone.", status: 401)
        }
        if r.method == "GET", let (name, type) = Self.assets[r.path] {
            guard let data = asset(name) else { return .text("The page's files are missing from the app.", status: 404) }
            return HTTP.Response(type: type, body: data)
        }
        if r.method == "GET", r.path == "/api/state" {
            polled = Date()
            scan()
            return .json(state())
        }
        if r.method == "GET", r.path == "/api/file" { return media(r) }
        if r.method == "POST", r.path == "/api/picture" { return picture(r) }
        if r.method == "GET", r.path == "/api/sessions" {
            let running = runningIDs()
            return .json(["sessions": oldSessions().map { s -> [String: Any] in
                ["id": s.id, "title": s.title, "folder": (s.cwd as NSString).lastPathComponent,
                 "at": s.at.timeIntervalSince1970.rounded(), "open": running.contains(s.id) || isOpen(s)]
            }])
        }
        if r.method == "GET", r.path == "/api/screen" {
            guard let turn = desk.turn(r.query["key"] ?? ""), let origin = turn.origin,
                  let screen = look(origin) else {
                return .json(["error": "its terminal can't be read from here"], status: 409)
            }
            desk.saw(turn.key, screen)   // its box as it stands; back at the prompt, a question is over
            return .json(["screen": screen, "state": state()])
        }
        guard r.method == "POST", r.headers["x-speakhud"] == "1", let body = r.json else {
            return .json(["error": "not found"], status: 404)
        }
        switch r.path {
        case "/api/away":
            guard let on = body["on"] as? Bool else { return .json(["error": "on must be true or false"], status: 400) }
            setAway(on)
            return .json(state())
        case "/api/heard":
            // How a reading went on the phone, for the log: numbers only, and no more
            // than these names. It is what a page's own voice did, which nothing on the
            // Mac can see.
            let names = ["parts", "words", "sized", "backwards", "gap", "scrolls", "stalls", "seconds", "speed", "voices"]
            var said = names.compactMap { name in (body[name] as? NSNumber).map { "\(name) \($0.doubleValue == $0.doubleValue.rounded() ? String($0.intValue) : String($0.doubleValue))" } }
            if let marks = body["marks"] as? Bool { said.append("marks \(marks ? "yes" : "no")") }
            if let lang = body["lang"] as? String, lang.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil {
                said.append("lang \(lang)")
            }
            // Which of the phone's voices read it (a name as the phone gives it, or "own").
            if let name = body["voice"] as? String, name.range(of: #"^[A-Za-z0-9 ()._'-]{1,40}$"#, options: .regularExpression) != nil {
                said.append("voice \(name)")
            }
            // What started it, what ended it, and which open copy of the page it was.
            for name in ["why", "end", "page"] {
                if let word = body[name] as? String, word.range(of: #"^[a-z0-9-]{1,12}$"#, options: .regularExpression) != nil {
                    said.append("\(name) \(word)")
                }
            }
            log("phone reading: " + said.joined(separator: ", "))
            return .json(["ok": true])
        case "/api/mic":
            // A dictation that never reached the Mac, for the log: the name of what went
            // wrong on the phone (its browser's own word for it), and nothing else.
            guard let why = body["why"] as? String, why.range(of: #"^[A-Za-z]{1,40}$"#, options: .regularExpression) != nil else {
                return .json(["error": "why?"], status: 400)
            }
            log("phone dictation didn't start: \(why)")
            return .json(["ok": true])
        case "/api/quick":
            guard let list = body["list"] as? [String] else { return .json(["error": "list must be a list of answers"], status: 400) }
            setQuick(list)
            return .json(state())
        case "/api/resume":
            // The folder and the id come from this Mac's own transcripts, looked up by the
            // id the page sent: the page never names a command or a path.
            guard let id = body["id"] as? String, let session = oldSessions().first(where: { $0.id == id }) else {
                return .json(["error": "that session isn't on this Mac any more"], status: 404)
            }
            guard !isOpen(session), !runningIDs().contains(session.id) else {
                return .json(["sent": false, "outcome": "it's already open"], status: 409)
            }
            let outcome = reopen(session)
            log("phone resumed \(session.title): \(outcome)")
            scanned = .distantPast   // the next look should find its new pane
            return .json(["sent": outcome == .sent, "outcome": outcome == .sent ? "opening on the Mac" : outcome.description])
        case "/api/close":
            guard let key = body["key"] as? String, let turn = desk.turn(key) else {
                return .json(["error": "that terminal isn't on the list any more"], status: 404)
            }
            guard let origin = turn.origin, Reply.canReach(origin) else {
                return .json(["error": "its terminal can't be reached from here"], status: 409)
            }
            let outcome = shut(origin)
            log("phone closed \(turn.name): \(outcome)")
            if outcome == .sent { desk.closed(key) }
            return .json(["sent": outcome == .sent, "outcome": outcome.description, "state": state()])
        case "/api/pick":
            // A choice in the box its terminal is showing. The box is read again here, so
            // the keys are worked out from where its cursor is now, and a box that has
            // moved on since the page drew it is never answered blind.
            guard let key = body["key"] as? String, let row = body["row"] as? Int, let label = body["label"] as? String else {
                return .json(["error": "which choice?"], status: 400)
            }
            guard let turn = desk.turn(key), let origin = turn.origin, Reply.canReach(origin) else {
                return .json(["error": "its terminal can't be reached from here"], status: 409)
            }
            guard let screen = look(origin), let box = TerminalBox.read(screen),
                  box.rows.indices.contains(row), box.rows[row].label == label, var keys = box.keys(toPick: row) else {
                if let screen = look(origin) { desk.saw(key, screen) }
                return .json(["sent": false, "outcome": "its box has changed since this was drawn", "state": state()])
            }
            var words: String?
            if let text = body["text"] as? String {
                // Its own answer: pick the row that turns into a text field, type, Enter.
                guard box.rows[row].types, box.rows[row].checked == nil, let line = Reply.clean(text) else {
                    return .json(["error": "that choice doesn't take words"], status: 400)
                }
                words = line
                keys.append("enter")
            }
            var outcome = Reply.Outcome.sent
            for (i, name) in keys.enumerated() where outcome == .sent {
                if i > 0 { wait(0.15) }
                if let line = words, i == keys.count - 1 {
                    outcome = type(line, origin)
                    if outcome == .sent { wait(0.15) }
                }
                if outcome == .sent { outcome = press(name, origin) }
            }
            log("phone pick \(row + 1) of \(box.rows.count) in \(turn.name): \(outcome)")
            return .json(["sent": outcome == .sent, "outcome": outcome.description])
        case "/api/key":
            guard let key = body["key"] as? String, let name = body["press"] as? String, Reply.keys[name] != nil else {
                return .json(["error": "no such key"], status: 400)
            }
            guard let turn = desk.turn(key) else {
                return .json(["error": "that terminal isn't on the list any more"], status: 404)
            }
            guard let origin = turn.origin, Reply.canReach(origin) else {
                return .json(["error": "its terminal can't be reached from here"], status: 409)
            }
            // At Claude's prompt a key isn't an answer: it lands in the message being
            // typed, and the next answer is pasted after it. Enter and Esc still mean
            // something there (send what's typed; stop the turn).
            if !["enter", "esc"].contains(name), let screen = look(origin), Reply.promptText(in: screen) != nil {
                return .json(["sent": false, "outcome": "its terminal is at Claude's prompt, where that key would only type into your message"])
            }
            let outcome = press(name, origin)
            log("phone key \(name) to \(turn.name): \(outcome)")
            return .json(["sent": outcome == .sent, "outcome": outcome.description])
        case "/api/reply":
            guard let key = body["key"] as? String, let said = body["text"] as? String else {
                return .json(["error": "nothing to send"], status: 400)
            }
            // Pictures sent ahead of this answer go with it as where they are on the Mac:
            // a terminal's Claude reads a picture from its path.
            let ids = body["pictures"] as? [String] ?? []
            let paths = ids.compactMap { pictures[$0] }.filter { FileManager.default.fileExists(atPath: $0) }
            guard paths.count == ids.count else {
                return .json(["error": "a picture didn't reach the Mac: add it again"], status: 400)
            }
            var text = said
            if !paths.isEmpty {
                let words = Reply.clean(said)
                let lead = paths.count == 1 ? "picture" : "pictures"
                text = (words.map { $0 + " The \(lead) from my phone:" } ?? "Look at \(paths.count == 1 ? "this" : "these") \(lead) from my phone:")
                    + " " + paths.joined(separator: " ")
            }
            guard Reply.clean(text) != nil else { return .json(["error": "nothing to send"], status: 400) }
            guard let turn = desk.turn(key) else {
                return .json(["error": "that terminal isn't on the list any more"], status: 404)
            }
            guard let origin = turn.origin, Reply.canReach(origin) else {
                return .json(["error": "its terminal can't be reached from here"], status: 409)
            }
            let outcome = deliver(text, origin)
            let with = paths.isEmpty ? "" : paths.count == 1 ? "1 picture" : "\(paths.count) pictures"
            desk.answered(key, with: [Reply.clean(said), with.isEmpty ? nil : "[\(with)]"].compactMap { $0 }.joined(separator: " "), outcome)
            log("phone reply to \(turn.name) (\(said.count) chars\(with.isEmpty ? "" : ", " + with)): \(outcome)")
            // `pasted`: the words are in its prompt, unsent. Sending them again would double them.
            return .json(["sent": outcome == .sent, "pasted": outcome == .unconfirmed,
                          "outcome": outcome.description, "state": state()])
        default:
            return .json(["error": "not found"], status: 404)
        }
    }
}

/// Getting the token onto a phone, and phone.json onto the Mac.
enum PhonePair {
    /// `text` as a QR code, black on white with a quiet border, `side` points square.
    static func qr(_ text: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage, code.extent.width > 0 else { return nil }
        let scale = (side / code.extent.width).rounded(.down)
        let rep = NSCIImageRep(ciImage: code.transformed(by: CGAffineTransform(scaleX: max(scale, 1), y: max(scale, 1))))
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        rep.draw(in: NSRect(x: (side - rep.size.width) / 2, y: (side - rep.size.height) / 2,
                            width: rep.size.width, height: rep.size.height))
        image.unlockFocus()
        return image
    }

    /// `speak-hud --setup-phone [--url U] [--ntfy TOPIC_URL] [--ntfy-token T] [--port N] [--new-token]`:
    /// writes phone.json, keeping the token and whatever isn't given again. The ntfy
    /// token can come from $SPEAKHUD_NTFY_TOKEN instead, which keeps it out of `ps`.
    /// `--new-token` is for a lost phone or a leaked link: every phone has to pair again.
    static func setup(_ argv: [String], env: [String: String] = ProcessInfo.processInfo.environment,
                      path: String = PhoneConfig.path) -> (message: String, exitCode: Int32) {
        func value(_ flag: String) -> String? {
            argv.firstIndex(of: flag).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
        }
        var config = PhoneConfig.load(path) ?? PhoneConfig(token: PhoneConfig.newToken())
        let renewed = argv.contains("--new-token")
        if renewed { config.token = PhoneConfig.newToken() }
        if let raw = value("--url") {
            guard let url = PhoneConfig.web(raw) else { return ("error: --url wants an http(s) address, like https://my-mac.my-tailnet.ts.net", 2) }
            config.url = url
        }
        if let raw = value("--ntfy") {
            guard let topic = PhoneConfig.web(raw), URL(string: topic)?.path.count ?? 0 > 1 else {
                return ("error: --ntfy wants a topic's address, like https://ntfy.example.com/terminals", 2)
            }
            config.ntfy = topic
        }
        if let token = value("--ntfy-token") ?? env["SPEAKHUD_NTFY_TOKEN"], !token.isEmpty { config.ntfyToken = token }
        if let raw = value("--port") {
            guard let port = UInt16(raw), port >= 1024 else { return ("error: --port wants a number from 1024 to 65535", 2) }
            config.port = port
        }
        guard config.save(to: path) else { return ("error: couldn't write \(path)", 1) }
        var lines = ["phone page set up in \(path) (port \(config.port), this Mac only)"]
        lines.append(config.url == nil ? "no --url yet: share the port on your tailnet (tailscale serve --bg \(config.port)), then give its address with --url"
                                       : "reached at \(config.url!)")
        lines.append(config.ntfy == nil ? "no --ntfy topic: Away won't push" : "pushes go to \(config.ntfy!)")
        if renewed { lines.append("new key: every phone has to pair again") }
        lines.append("restart SpeakHUD, then pair from its menu: Phone, Pair a Phone")
        return (lines.joined(separator: "\n"), 0)
    }
}

/// How long the agent's log is kept. launchd only ever appends to it, so without this
/// it grows for ever: at start, and once a day after, lines older than `days` go.
/// The file is cut down in place. launchd holds it open for appending, and a file
/// swapped in under that would leave the agent writing to one nobody can see.
enum LogKeep {
    static let days = 30

    /// Where the kept part of `log` starts and how many lines come before it: from the
    /// first line stamped at or after `cutoff` on. nil when there's nothing old to drop
    /// (a log with no stamps at all is left alone). Stamps are "[2026-10-08T04:31:34Z] …",
    /// which sort as text.
    static func cut(_ log: Data, before cutoff: Date) -> (offset: Int, lines: Int)? {
        let oldest = Array(ISO8601DateFormatter().string(from: cutoff).utf8)
        var start = log.startIndex, lines = 0, sawOld = false
        while start < log.endIndex {
            let end = log[start...].firstIndex(of: 0x0A) ?? log.endIndex
            let close = start + oldest.count + 1
            if close < end, log[start] == UInt8(ascii: "["), log[close] == UInt8(ascii: "]") {
                if !log[(start + 1)..<close].lexicographicallyPrecedes(oldest) { break }
                sawOld = true
            }
            lines += 1
            start = min(end + 1, log.endIndex)
        }
        return sawOld ? (start - log.startIndex, lines) : nil
    }

    /// Drop what's older than `days` from the log at `path`. Returns how many lines went.
    @discardableResult
    static func trim(_ path: String, now: Date = Date()) -> Int {
        guard let log = FileManager.default.contents(atPath: path),
              let cut = cut(log, before: now.addingTimeInterval(-Double(days) * 86_400)),
              let file = FileHandle(forWritingAtPath: path) else { return 0 }
        defer { try? file.close() }
        do {
            try file.truncate(atOffset: 0)
            try file.write(contentsOf: log.suffix(from: log.startIndex + cut.offset))
        } catch { return 0 }
        return cut.lines
    }

    /// The file stderr goes to, when it is one (launchd's StandardErrorPath).
    static func stderrFile() -> String? {
        var st = stat()
        guard fstat(STDERR_FILENO, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return fcntl(STDERR_FILENO, F_GETPATH, &buf) == 0 ? String(cString: buf) : nil
    }
}

// Background listener: owns the one HUD, the speech queue, and the global hotkey.
// Runs from a LaunchAgent; no window/Dock until something needs reading.
final class Agent {
    static weak var shared: Agent?
    let hud = Controller()
    var spoolSource: DispatchSourceFileSystemObject?
    var pollTimer: Timer?
    var logTrimTimer: Timer?
    private(set) var phone: Phone?
    private var phoneServer: PhoneServer?
    private var awakeGuard: NSObjectProtocol?
    var napGuard: NSObjectProtocol?
    var heartbeatOK = true
    var usr1: DispatchSourceSignal?

    /// launchd routes stderr to ~/Library/Logs/speakhud-agent.log (see build.sh).
    func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write("[\(ts)] \(message)\n".data(using: .utf8)!)
    }

    /// Keep the log to LogKeep.days. Says so only when something went.
    private func trimLog() {
        guard let path = LogKeep.stderrFile() else { return }   // run by hand: stderr is the terminal
        let gone = LogKeep.trim(path)
        if gone > 0 { log("log trimmed: \(gone) lines older than \(LogKeep.days) days dropped") }
    }

    func run() {
        Agent.shared = self
        hud.onIdle = { [weak self] in self?.hud.hidePanel() }
        hud.log = { [weak self] in self?.log($0) }
        hud.watchMic()
        hud.hotkeyHint = "Anywhere:  ⌃⌥P pause / resume    ⌃⌥H show / hide this window"
        trimLog()
        logTrimTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in self?.trimLog() }
        log("agent started (pid \(getpid()))")
        // The one thing you can't tell from outside the process: whether macOS will
        // let us see the text you've highlighted.
        log(Selection.isTrusted
            ? "accessibility: granted — hotkey reads your selection"
            : "accessibility: NOT granted — hotkey falls back to the clipboard")
        registerReadHotKey()
        HotKeyCenter.shared.register(.togglePause,
                                     keyCode: UInt32(kVK_ANSI_P),
                                     mods: UInt32(controlKey | optionKey)) { [weak self] in
            self?.hud.togglePause()
        }
        let shown = HotKeyCenter.shared.register(.toggleHUD,
                                                 keyCode: UInt32(kVK_ANSI_H),
                                                 mods: UInt32(controlKey | optionKey)) { [weak self] in
            self?.hud.toggleMinimized()
        }
        if !shown {
            // Without the hotkey the menu bar is the only way back; say so in the panel.
            log("could not register ⌃⌥H — use the menu bar to show/hide the HUD")
            hud.hotkeyHint = "Pause / Resume anywhere:  ⌃⌥P    (show / hide: menu bar)"
        }
        startPhone()
        watchSpool()
        // SIGUSR1 also triggers a read — lets the install step self-test without keys.
        signal(SIGUSR1, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s.setEventHandler { Agent.shared?.readClipboard() }
        s.resume()
        usr1 = s
    }

    /// The read hotkey actually live right now. Editing config.json doesn't change it
    /// until the agent re-registers, so the menu reports this, not the file.
    private(set) var registeredSpec: String?

    func registerReadHotKey() {
        let loaded = HotkeyConfig.load()
        if let why = loaded.problem {
            // Left as is: it's yours to fix, and the menu shows the same warning.
            log("\(HotkeyConfig.path) \(why) — using \(loaded.spec)")
        }
        let spec = loaded.spec
        guard let hk = parseHotkey(spec) else {
            log("invalid hotkey \"\(spec)\" — not registered")
            return
        }
        let ok = HotKeyCenter.shared.register(.read, keyCode: hk.keyCode, mods: hk.mods) { [weak self] in
            self?.readSelection()
        }
        registeredSpec = ok ? spec : nil   // register() drops the old binding first
        log(ok ? "listening for \(spec)" : "could not register \(spec) — another app owns it")
    }

    // -- spool -------------------------------------------------------------

    private func watchSpool() {
        Spool.ensure()
        Spool.recover()   // whatever the last agent died holding gets another turn
        log("spool: watching \(Spool.dir)")   // if the hook writes elsewhere, this is where you'd see it
        let fd = open(Spool.dir, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .rename], queue: .main)
            src.setEventHandler { [weak self] in self?.drainSpool() }
            src.setCancelHandler { close(fd) }
            src.resume()
            spoolSource = src
        }
        // Safety net: the vnode source goes deaf if the directory is ever replaced.
        // Also the heartbeat: the hook queues only while it's fresh, so it beats from
        // this main-thread timer (a hung main thread goes stale) in .common modes (an
        // open menu mustn't stop it), with App Nap off (an accessory app with no window
        // gets napped, and its timers stretched past the hook's threshold).
        napGuard = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "spool heartbeat")
        let timer = Timer(timeInterval: Spool.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.heartbeat()
            self?.drainSpool()
            self?.phone?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        heartbeat()   // alive from the first drain, not 3s later
        drainSpool()
    }

    private func heartbeat() {
        let ok = Spool.beat()
        // Log transitions only: every 3s would drown the log.
        if ok != heartbeatOK {
            log(ok ? "spool: heartbeat restored"
                   : "spool: can't write \(Spool.heartbeatName) in \(Spool.dir) — hooks will speak turns directly")
        }
        heartbeatOK = ok
    }

    private func drainSpool() {
        let batch = Spool.drain()
        for drop in batch.dropped { log("spool: dropped \(drop.name) — \(drop.reason)") }
        // The phone keeps what it can show. Whether a turn is read, and what Away does
        // with it, is Playback's to decide and to log.
        for item in batch.items { hud.playback.enqueue(item, onPhone: phone?.took(item) ?? false) }
    }

    // -- phone -------------------------------------------------------------

    /// The page and the pushes, if phone.json sets them up. Without it nothing listens.
    private func startPhone() {
        guard let config = PhoneConfig.load() else { return }
        // The list of turns outlives a restart, next to the spool it came through.
        let kept = (Spool.dir as NSString).deletingLastPathComponent + "/phone-desk.json"
        let phone = Phone(config: config, saved: FileManager.default.contents(atPath: kept))
        phone.save = { data in
            FileManager.default.createFile(atPath: kept, contents: data, attributes: [.posixPermissions: 0o600])
        }
        phone.log = { [weak self] in self?.log($0) }
        phone.sweepPictures()
        phone.onAwayChange = { [weak self] in self?.awayChanged($0) }
        let leftBehind = Dictation.sweep()
        if leftBehind > 0 { log("phone: deleted \(leftBehind) recording\(leftBehind == 1 ? "" : "s") a past dictation left behind") }
        Dictation.warmUp()
        do {
            let server = try PhoneServer(port: config.port) { phone.respond(to: $0) }
            server.slow = { phone.respondLater(to: $0, done: $1) }
            server.start { [weak self] in self?.log("phone: the page stopped — \($0)") }
            phoneServer = server
            log("phone: page on 127.0.0.1:\(config.port)" + (config.url == nil ? " (no url in phone.json: pushes won't link to it)" : ""))
        } catch {
            log("phone: can't serve the page on port \(config.port) — \(error.localizedDescription)")
        }
        self.phone = phone
        awayChanged(phone.away)
    }

    /// Away stops the reading and shuts the mic (Playback), and keeps the Mac from
    /// idling to sleep (the screen can still lock and dim): a sleeping Mac answers nothing.
    var onAwayChange: () -> Void = {}
    private func awayChanged(_ on: Bool) {
        hud.playback.awayChanged(on: on)
        if on, awakeGuard == nil {
            awakeGuard = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled,
                                                               reason: "away: answering from the phone")
        } else if !on, let held = awakeGuard {
            ProcessInfo.processInfo.endActivity(held)
            awakeGuard = nil
        }
        onAwayChange()
    }

    // -- reads -------------------------------------------------------------

    /// Hotkey: read whatever is highlighted in the frontmost app.
    func readSelection() {
        let front = NSWorkspace.shared.frontmostApplication
        // No selection (or no Accessibility grant) falls back to the clipboard,
        // which is exactly what this hotkey did before it could see selections.
        play(Selection.current() ?? NSPasteboard.general.string(forType: .string) ?? "",
             source: front?.localizedName ?? "Selection",
             origin: front.map { Origin(appPID: $0.processIdentifier) })
    }

    /// Menu item / double-clicking the app: there's no meaningful selection when
    /// SpeakHUD itself is frontmost, so read the clipboard.
    func readClipboard() {
        play(NSPasteboard.general.string(forType: .string) ?? "", source: "Clipboard")
    }

    private func play(_ raw: String, source: String, origin: Origin? = nil) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { NSSound.beep(); return }
        hud.playNow(SpeechItem(text: text, source: source, key: UUID().uuidString, created: Date(),
                               origin: origin))
    }
}

// Because the agent is a running instance of the app bundle, double-clicking
// SpeakHUD.app doesn't launch a new reader — macOS just "reopens" the agent.
// Treat that reopen as "read the clipboard", so double-click does what you'd expect.
final class AgentDelegate: NSObject, NSApplicationDelegate {
    let agent: Agent
    init(_ agent: Agent) { self.agent = agent }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        agent.readClipboard()
        return true
    }
}

// Menu-bar settings surface for the agent: read clipboard, toggle the Claude Code
// integration, and pick the global hotkey — all without a Dock icon or window.
final class MenuController: NSObject, NSMenuDelegate {
    let agent: Agent
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var claudeItem: NSMenuItem!
    var axItem: NSMenuItem!
    var hudItem: NSMenuItem!
    let hotkeyPresets = [("⌃⌥S", "ctrl+opt+s"), ("⌃⌥R", "ctrl+opt+r"),
                         ("⌃⌥Space", "ctrl+opt+space"), ("⌘⌥S", "cmd+opt+s")]
    var hotkeyItems: [NSMenuItem] = []
    var hotkeyWarning: NSMenuItem!
    var micItem: NSMenuItem!
    var listenItem: NSMenuItem!
    var obeyItem: NSMenuItem!
    var awayItem: NSMenuItem!
    var pairItem: NSMenuItem!
    var phoneNote: NSMenuItem!

    init(_ agent: Agent) {
        self.agent = agent
        super.init()
        build()
        // Hiding via the panel's own button has to move the menu item too. Only the
        // visibility bits: the hook check compares whole files, so it waits for the menu.
        agent.hud.onVisibilityChange = { [weak self] in self?.refreshVisibility() }
        agent.onAwayChange = { [weak self] in self?.refresh() }   // the phone can switch it too
    }

    private func build() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false   // so a disabled Pause While Recording (pre-14) stays disabled
        // First item, because when the HUD is hidden this is what you came here for.
        hudItem = item("Show HUD", #selector(toggleHUD))
        hudItem.keyEquivalent = "h"
        hudItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(hudItem)
        menu.addItem(item("Read Clipboard Aloud", #selector(readClipboard)))
        menu.addItem(.separator())

        claudeItem = item("Read Claude Code Responses Aloud", #selector(toggleClaude))
        menu.addItem(claudeItem)

        micItem = item("Pause While Recording", #selector(toggleMicHold))
        if #available(macOS 14.0, *) {
            micItem.toolTip = "Hold speech while another app uses the microphone"
        } else {
            micItem.isEnabled = false
            micItem.toolTip = "Needs macOS 14 or later"
        }
        menu.addItem(micItem)

        listenItem = item("Listen After Reading", #selector(toggleListen))
        if agent.hud.canListen {
            listenItem.toolTip = "After a Claude Code turn is read, open the mic and send what you say back to its terminal. Say nothing and it closes."
        } else {
            listenItem.isEnabled = false
            listenItem.toolTip = "Needs macOS 26 or later"
        }
        menu.addItem(listenItem)

        obeyItem = item("Listen While Reading", #selector(toggleObey))
        if agent.hud.canListen {
            obeyItem.toolTip = "While a turn is being read, say: again, later, skip, pause, go on, stop everything. The Mac's own voice is cancelled out of the mic."
        } else {
            obeyItem.isEnabled = false
            obeyItem.toolTip = "Needs macOS 26 or later"
        }
        menu.addItem(obeyItem)

        let hk = NSMenu()
        hk.autoenablesItems = false   // keep the warning line disabled
        // Only shown while config.json is broken; the tooltip says how.
        hotkeyWarning = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hotkeyWarning.isEnabled = false
        hk.addItem(hotkeyWarning)
        for (label, spec) in hotkeyPresets {
            let it = item(label, #selector(pickHotkey(_:))); it.representedObject = spec
            hk.addItem(it); hotkeyItems.append(it)
        }
        hk.addItem(.separator())
        hk.addItem(item("Edit Config File…", #selector(openHotkeyConfig)))
        let hkParent = NSMenuItem(title: "Global Hotkey", action: nil, keyEquivalent: "")
        hkParent.submenu = hk
        menu.addItem(hkParent)

        let ph = NSMenu()
        ph.autoenablesItems = false   // keep the note, and an unset-up Away, disabled
        awayItem = item("Away: Turns Go to My Phone", #selector(toggleAway))
        awayItem.toolTip = "Finished turns are pushed to your phone instead of read aloud, no mic opens, and the Mac stays awake."
        ph.addItem(awayItem)
        pairItem = item("Pair a Phone…", #selector(pairPhone))
        ph.addItem(pairItem)
        // Only shown until phone.json exists.
        phoneNote = NSMenuItem(title: "Not set up — run: speak-hud --setup-phone", action: nil, keyEquivalent: "")
        phoneNote.isEnabled = false
        ph.addItem(phoneNote)
        let phParent = NSMenuItem(title: "Phone", action: nil, keyEquivalent: "")
        phParent.submenu = ph
        menu.addItem(phParent)

        // Only surfaced when we can't read selections yet — otherwise it's noise.
        axItem = item("Grant Accessibility Access…", #selector(grantAccessibility))
        menu.addItem(axItem)

        menu.addItem(.separator())
        menu.addItem(item("SpeakHUD on GitHub", #selector(openGitHub)))
        menu.addItem(item("Quit SpeakHUD", #selector(quit)))
        statusItem.menu = menu
        refresh()
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    private func refresh() {
        refreshVisibility()
        refreshHook()
        axItem.isHidden = Selection.isTrusted
        let loaded = HotkeyConfig.load()
        for it in hotkeyItems { it.state = (it.representedObject as? String == loaded.spec) ? .on : .off }
        hotkeyWarning.isHidden = loaded.problem == nil
        hotkeyWarning.title = "⚠ config.json invalid — "
            + (agent.registeredSpec.map { "using \(HotkeyConfig.label($0))" } ?? "no hotkey registered")
        hotkeyWarning.toolTip = loaded.problem.map { "\(HotkeyConfig.path) \($0)" }
        micItem.state = micItem.isEnabled && agent.hud.pauseWhileRecording ? .on : .off
        listenItem.state = agent.hud.listenAfterReading ? .on : .off
        obeyItem.state = agent.hud.listenWhileReading ? .on : .off
        let phone = agent.phone
        phoneNote.isHidden = phone != nil
        awayItem.isEnabled = phone != nil
        awayItem.state = phone?.away == true ? .on : .off
        pairItem.isEnabled = phone?.config.pairLink != nil
        pairItem.toolTip = phone != nil && phone?.config.pairLink == nil
            ? "phone.json has no url: set the address your phone reaches this Mac at" : nil
    }

    private func refreshVisibility() {
        let hidden = !agent.hud.isPanelVisible
        hudItem.title = hidden ? "Show HUD" : "Hide HUD"
        // A hollow icon is the standing reminder that the panel is only hidden,
        // not gone — otherwise a hidden HUD is indistinguishable from a broken one.
        if let btn = statusItem.button {
            // Away, nothing is read aloud: a phone in the menu bar says why it's quiet.
            if agent.phone?.away == true,
               let phone = NSImage(systemSymbolName: "iphone.radiowaves.left.and.right",
                                   accessibilityDescription: "SpeakHUD (away: turns go to your phone)") {
                btn.image = phone
                return
            }
            btn.image = NSImage(systemSymbolName: hidden ? "speaker.wave.2" : "speaker.wave.2.fill",
                                accessibilityDescription: hidden ? "SpeakHUD (hidden)" : "SpeakHUD")
        }
    }

    private func refreshHook() {
        let hook = ClaudeHook.check()
        claudeItem.title = hook.status == .stale ? "Read Claude Code Responses Aloud — Repair"
                                                 : "Read Claude Code Responses Aloud"
        switch hook.status {
        case .installed:    claudeItem.state = .on
        case .stale:        claudeItem.state = .mixed    // "–": present but broken
        case .notInstalled: claudeItem.state = .off
        }
        claudeItem.toolTip = hook.problems.isEmpty ? nil
            : hook.status == .stale ? "Needs repair: " + hook.problems.joined(separator: "; ") + ". Click to reinstall."
            : hook.problems.joined(separator: "; ")
    }

    @objc private func toggleHUD() { agent.hud.toggleMinimized() }
    @objc private func readClipboard() { agent.readClipboard() }
    @objc private func toggleClaude() {
        // Installed -> remove. Stale -> reinstall (a repair, not an uninstall). Off -> install.
        let result = ClaudeHook.status() == .installed ? ClaudeHook.remove() : ClaudeHook.install()
        if result.hasPrefix("error") {
            let alert = NSAlert()
            alert.messageText = "Claude Code hook"
            alert.informativeText = result
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refresh()
    }
    @objc private func grantAccessibility() {
        if !Selection.requestTrust() {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        refresh()
    }
    @objc private func pickHotkey(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? String else { return }
        HotkeyConfig.save(spec)
        agent.registerReadHotKey()   // re-register live; no restart needed
        refresh()
    }
    @objc private func toggleMicHold() {
        agent.hud.pauseWhileRecording.toggle()
        refresh()
    }
    @objc private func toggleListen() {
        agent.hud.setListenAfterReading(!agent.hud.listenAfterReading) { [weak self] in
            self?.cantListen("Listen After Reading", $0)
        }
        refresh()
    }
    @objc private func toggleObey() {
        agent.hud.setListenWhileReading(!agent.hud.listenWhileReading) { [weak self] in
            self?.cantListen("Listen While Reading", $0)
        }
        refresh()
    }
    private func cantListen(_ setting: String, _ why: String) {
        let alert = NSAlert()
        alert.messageText = setting
        alert.informativeText = "Can't listen: \(why)."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        refresh()
    }
    @objc private func toggleAway() {
        guard let phone = agent.phone else { return }
        phone.setAway(!phone.away)
        refresh()
    }
    @objc private func pairPhone() {
        guard let link = agent.phone?.config.pairLink else { return }
        let alert = NSAlert()
        alert.messageText = "Pair a phone"
        alert.informativeText = "Point the phone's camera at this while it's on your tailnet. The link is the key to your terminals: don't share it."
        if let qr = PhonePair.qr(link, side: 240) {
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
            view.image = qr
            alert.accessoryView = view
        }
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Copy Link")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        }
    }
    @objc private func openHotkeyConfig() {
        HotkeyConfig.ensureFile()   // create it if missing; never overwrite a broken one you're fixing
        NSWorkspace.shared.open(URL(fileURLWithPath: HotkeyConfig.path))
    }
    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/chris-jk/SpeakHUD")!)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

// ---------------------------------------------------------------------------
// Entry point: dispatch on mode. Compiled out for tests (tests/run.sh builds with
// -D TESTING), so a test main can link everything above without launching the app.
// @main rather than top-level code, because Swift rejects top-level statements in
// any file but main.swift, even inside an inactive #if.
// ---------------------------------------------------------------------------
#if !TESTING
@main
enum Main {
    static func main() {
        let argv = CommandLine.arguments

        if let i = argv.firstIndex(of: "--set-hotkey") {
            guard i + 1 < argv.count, parseHotkey(argv[i + 1]) != nil else {
                FileHandle.standardError.write(
                    "usage: speak-hud --set-hotkey \"ctrl+opt+s\"  (need ≥1 modifier + a key)\n".data(using: .utf8)!)
                exit(2)
            }
            let outcome = SetHotkey.run(argv[i + 1])
            if outcome.exitCode == 0 {
                print(outcome.message)
            } else {
                FileHandle.standardError.write((outcome.message + "\n").data(using: .utf8)!)
            }
            exit(outcome.exitCode)
        }

        if argv.contains("--setup-claude") || argv.contains("--remove-claude") {
            let r = argv.contains("--setup-claude") ? ClaudeHook.install() : ClaudeHook.remove()
            print(r); exit(r.hasPrefix("error") ? 1 : 0)
        }
        if argv.contains("--refresh-claude-files") {
            let r = ClaudeHook.refreshFiles()
            print(r); exit(r.hasPrefix("error") ? 1 : 0)
        }
        if argv.contains("--claude-status") {
            // "installed" | "stale: <why>" | "not installed" — build.sh matches on these.
            let c = ClaudeHook.check()
            print(c.problems.isEmpty ? c.status.rawValue
                                     : c.status.rawValue + ": " + c.problems.joined(separator: "; "))
            exit(0)
        }

        if argv.contains("--setup-phone") {
            let outcome = PhonePair.setup(argv)
            if outcome.exitCode == 0 {
                print(outcome.message)
            } else {
                FileHandle.standardError.write((outcome.message + "\n").data(using: .utf8)!)
            }
            exit(outcome.exitCode)
        }

        if argv.contains("--agent") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let agent = Agent()
            let agentDelegate = AgentDelegate(agent)
            app.delegate = agentDelegate          // handles double-click "reopen" -> read clipboard
            agent.run()
            let menuController = MenuController(agent)   // menu-bar settings surface
            _ = menuController
            app.run()
            exit(0)
        }

        // Default: a one-shot reader HUD. Used for `speak-hud "text"` and as the Claude
        // Code hook's fallback when the agent isn't running to serialize things for us.
        let text = resolveText(argv).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { exit(0) }

        var sourceName = "Claude Code"
        if let i = argv.firstIndex(of: "--source"), i + 1 < argv.count { sourceName = argv[i + 1] }
        var origin: Origin?
        if let i = argv.firstIndex(of: "--origin"), i + 1 < argv.count { origin = Origin(jsonString: argv[i + 1]) }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // no Dock icon, doesn't steal focus
        let controller = Controller(listens: false)
        controller.onIdle = { NSApp.terminate(nil) }
        controller.watchMic()
        HotKeyCenter.shared.register(.togglePause,
                                     keyCode: UInt32(kVK_ANSI_P),
                                     mods: UInt32(controlKey | optionKey)) { [weak controller] in
            controller?.togglePause()
        }
        controller.enqueue(SpeechItem(text: text, source: sourceName, key: UUID().uuidString, created: Date(),
                                      origin: origin))
        app.run()
    }
}
#endif
