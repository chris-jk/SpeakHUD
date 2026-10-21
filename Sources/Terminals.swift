import Cocoa

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
        return window(typing: "cd " + LoadCommand.shellQuote(session.cwd) + " && claude --resume " + session.id)
    }

    /// The AppleScript that opens a new iTerm2 window and runs `line` in it, which must
    /// already be isLoadable.
    static func window(typing line: String) -> String {
        """
        tell application id "\(Reveal.iTerm)"
            set w to (create window with default profile)
            tell current session of w to write text \(LoadCommand.literal(line))
            return "ok"
        end tell
        """
    }

    /// Open it. `run` is what executes the script; tests keep it instead.
    static func resume(_ session: Session, run: (String) -> Reply.Answer = OldSessions.run) -> Reply.Outcome {
        open(script(session), in: session.cwd, refused: "that isn't a session that can be resumed", run: run)
    }

    /// Run `source`, a window's script, if `folder` is still there. Nil `source`: refused.
    static func open(_ source: String?, in folder: String, refused: String, run: (String) -> Reply.Answer) -> Reply.Outcome {
        guard NewTerminal.isFolder(folder) else { return .failed("its folder isn't there any more") }
        guard let source = source else { return .failed(refused) }
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

/// A fresh Claude Code, started from the phone: a new iTerm2 window in one of your
/// folders, running `claude`, with your first message if you wrote one. The folders on
/// offer are the ones you pinned, your home folder, the ones this Mac's own transcripts
/// were started in, most used first, then the project folders Claude Code remembers.
/// The page picks one of those and never names a path of its own.
enum NewTerminal {
    struct Project: Equatable {
        var folder: String
        var name: String
        var pinned: Bool
    }

    static let limit = 20   // suggestions; pinned folders are always offered

    static func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static var config: String { NSString(string: "~/.claude.json").expandingTildeInPath }
    static var roots: [String] { ["~/GitHub", "~/Desktop/Projects"].map { NSString(string: $0).expandingTildeInPath } }

    /// The folders Claude Code itself remembers being opened in (`projects` in
    /// ~/.claude.json, kept long after their transcripts are cleaned away), newest first.
    /// Only those under `roots`: the rest is mostly scratch folders.
    static func known(in path: String = NewTerminal.config, roots: [String] = NewTerminal.roots) -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = o["projects"] as? [String: Any] else { return [] }
        func at(_ folder: String) -> Double {
            let p = projects[folder] as? [String: Any] ?? [:]
            return ["lastStartTime", "lastSessionModified"].compactMap { (p[$0] as? NSNumber)?.doubleValue }.max() ?? 0
        }
        return projects.keys.filter { folder in roots.contains { folder.hasPrefix($0 + "/") } }
            .sorted { at($0) != at($1) ? at($0) > at($1) : $0 < $1 }
    }

    /// `sessions` newest first, as `OldSessions.recent` gives them; `known` as `known()` does.
    static func projects(pinned: [String], sessions: [OldSessions.Session], known: [String] = [], home: String,
                         isFolder: (String) -> Bool = NewTerminal.isFolder) -> [Project] {
        var uses: [String: Int] = [:], order: [String] = []
        for s in sessions {
            if uses[s.cwd] == nil { order.append(s.cwd) }
            uses[s.cwd, default: 0] += 1
        }
        let suggested = order.enumerated().sorted { a, b in
            uses[a.element]! != uses[b.element]! ? uses[a.element]! > uses[b.element]! : a.offset < b.offset
        }.map { $0.element }
        var found: [Project] = []
        for (folder, pin) in pinned.map({ ($0, true) }) + ([home] + suggested + known).map({ ($0, false) }) {
            guard pin || found.count < limit, !found.contains(where: { $0.folder == folder }),
                  folder.hasPrefix("/"), LoadCommand.isLoadable(folder), isFolder(folder) else { continue }
            found.append(Project(folder: folder, name: "", pinned: pin))
        }
        // By the folder's own name, with its parent's where two would read the same.
        let last = found.map { ($0.folder as NSString).lastPathComponent }
        for i in found.indices {
            let folder = found[i].folder as NSString
            found[i].name = found[i].folder == home ? "Home"
                : last.filter({ $0 == last[i] }).count > 1
                ? (folder.deletingLastPathComponent as NSString).lastPathComponent + "/" + last[i] : last[i]
        }
        return found
    }

    /// What's typed into the new window. A first message goes in as `claude`'s prompt.
    /// One with no space in it gets a space on the end: `claude purge` would run Claude
    /// Code's own `purge` (it deletes a project's transcripts), and `update`, `install`
    /// and the rest are commands too, to `claude` and to the shell's `claude` wrapper.
    /// Both take a word as a command only when it is the whole argument.
    static func line(folder: String, message: String?) -> String? {
        guard folder.hasPrefix("/"), LoadCommand.isLoadable(folder) else { return nil }
        var line = "cd " + LoadCommand.shellQuote(folder) + " && claude"
        if let message = message {
            guard LoadCommand.isLoadable(message) else { return nil }
            line += " " + LoadCommand.shellQuote(message.contains(" ") ? message : message + " ")
        }
        return LoadCommand.isLoadable(line) ? line : nil
    }

    static func start(folder: String, message: String?, run: (String) -> Reply.Answer = OldSessions.run) -> Reply.Outcome {
        OldSessions.open(line(folder: folder, message: message).map(OldSessions.window(typing:)), in: folder,
                         refused: "that message is too long to type into a terminal", run: run)
    }
}

/// A box Claude Code has up instead of its prompt, read off the terminal's own screen
/// (`Reply.showing`): a question with its choices, a permission prompt, the folder-trust
/// check. The screen is the one thing that's true for all of them, whoever put the box
/// there and whenever the agent started, so this, not the question hook, is what the
/// phone answers from.
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

    /// What a page drew of a box, sent back with every tap on it: what it asks, its strip
    /// of questions, and each choice's label from the top. Where the cursor is, what's
    /// ticked and the hint line are left out: they move while it is still the same box.
    struct Drawn: Equatable {
        var ask: String
        var tabs: String? = nil
        var rows: [String]

        init(ask: String, tabs: String? = nil, rows: [String]) { (self.ask, self.tabs, self.rows) = (ask, tabs, rows) }

        /// As the page sends it. Nil for anything else: a strip that is there and isn't
        /// words is not "no strip".
        init?(json: Any?) {
            guard let o = json as? [String: Any], let ask = o["ask"] as? String, let rows = o["rows"] as? [String] else { return nil }
            let tabs = o["tabs"]
            guard tabs == nil || tabs is NSNull || tabs is String else { return nil }
            self.init(ask: ask, tabs: tabs as? String, rows: rows)
        }
    }

    /// Whether this is the box that was `drawn`: it asks the same thing of the same
    /// choices. A row and its label don't say that (every permission box has "Yes"
    /// first). The strip counts by its questions' names: the mark beside one changes
    /// once it has an answer.
    func isBox(_ drawn: Drawn) -> Bool {
        func names(_ tabs: String?) -> [String] {
            (tabs ?? "").components(separatedBy: .whitespaces)
                .filter { $0.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }
        }
        return ask == drawn.ask && names(tabs) == names(drawn.tabs) && rows.map { $0.label } == drawn.rows
    }

    /// Whether this is the box for a question the hook read out as `asked`, and its
    /// choice numbered `number` the one the hook worded `option` ("Navy. Like the
    /// factory" for the row "Navy"). The page draws the hook's words until the screen
    /// has been read, and the numbers beside them are keys.
    func isChoice(_ number: Int, worded option: String, asked: String) -> Bool {
        func squash(_ s: String) -> String { String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }) }
        guard !ask.isEmpty, squash(asked).contains(squash(ask)), let row = rows.first(where: { $0.number == number }) else { return false }
        return squash(option).hasPrefix(squash(row.label))
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
