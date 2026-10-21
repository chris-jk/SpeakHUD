import Foundation

// Installs/removes the Claude Code hooks that read aloud, so a downloaded copy can
// replicate the author's setup with one click: the "Stop" hook that reads each response
// (read-summary.py) and, with it, the AskUserQuestion hook that reads a question and its
// options (read-question.py, on PreToolUse and PostToolUse). They go in and come out
// together: the question hook runs on the Stop hook's code, and "off" has to mean
// nothing is read. This is the one install path: the menu item, --setup-claude, and
// build.sh (which shells out to --setup-claude) all land here. An install is the two
// scripts, the reader binary the Stop hook falls back to, and the three settings.json
// entries, and status() checks every one, so a missing or out-of-date piece shows up as
// `.stale` rather than hiding behind a present settings entry. Edits to settings.json
// are merges: other keys, groups and sibling hooks are preserved.
// Set SPEAKHUD_CLAUDE_DIR to point at a different dir (used by tests).
enum ClaudeHook {
    enum Status: String {
        case installed
        case stale                          // partly there: an entry or a file is missing or out of date
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
    /// The question hook goes one folder down, where it was first put by hand; from there
    /// it finds read-summary.py in ~/.claude (tests/read_question_test.py runs it so).
    static var hooksDir: String { dir + "/hooks" }
    static var questionPath: String { hooksDir + "/read-question.py" }
    static var binDir: String { dir + "/bin" }
    static var binPath: String { binDir + "/speak-hud" }

    /// The command registered in settings.json. For the real dir it stays the portable
    /// `~` form; with SPEAKHUD_CLAUDE_DIR set it names the overridden script, so the entry
    /// and the file it runs never disagree. (read-summary.py's own fallback still looks
    /// for ~/.claude/bin/speak-hud, and read-question.py for ~/.claude/read-summary.py:
    /// the override exists for tests, which never run them.)
    static var hookCommand: String { command(scriptPath, "~/.claude/read-summary.py") }
    /// The question hook's, before AskUserQuestion; after it, the same with ` --answered`.
    static var questionCommand: String { command(questionPath, "~/.claude/hooks/read-question.py") }
    private static func command(_ path: String, _ portable: String) -> String {
        if dir == defaultDir { return "python3 " + portable }
        return "python3 '" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// read-summary.py shipped inside SpeakHUD.app. Nil when running outside the bundle
    /// (e.g. as ~/.claude/bin/speak-hud).
    static var bundledScript: URL? { Bundle.main.url(forResource: "read-summary", withExtension: "py") }
    /// read-question.py, bundled beside it by build.sh.
    static var bundledQuestionScript: URL? { Bundle.main.url(forResource: "read-question", withExtension: "py") }

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

    /// One settings.json entry of ours: the event it's on, the script it runs (which is
    /// how an entry already there is known as ours), and the group an install adds.
    private struct Piece {
        let event: String, script: String
        let group: [String: Any]
    }
    /// The three an install owns: the Stop hook, and the question hook before and after
    /// AskUserQuestion. The question hook's two are written exactly as they were first
    /// put in by hand (hook/README.md), and nothing else is ever written to settings.json.
    private static var pieces: [Piece] {
        func group(_ matcher: String?, _ command: String, _ more: [String: Any]) -> [String: Any] {
            let entry = more.merging(["type": "command", "command": command]) { a, _ in a }
            return matcher.map { ["matcher": $0, "hooks": [entry]] } ?? ["hooks": [entry]]
        }
        return [
            Piece(event: "Stop", script: "read-summary.py",
                  group: group(nil, hookCommand, ["async": true])),
            // Async: it waits on the HUD to read the question, then its options.
            Piece(event: "PreToolUse", script: "read-question.py",
                  group: group("AskUserQuestion", questionCommand, ["async": true, "timeout": 600])),
            // Not async: it only drops the question's marker.
            Piece(event: "PostToolUse", script: "read-question.py",
                  group: group("AskUserQuestion", questionCommand + " --answered", ["timeout": 5])),
        ]
    }

    /// The groups under one event, as written. Read loosely (`Any`), so a group or entry
    /// of a shape we don't know is carried through a rewrite instead of dropped.
    private static func groups(_ root: [String: Any], _ event: String) -> [Any] {
        (root["hooks"] as? [String: Any])?[event] as? [Any] ?? []
    }
    /// One hook entry (not a group) is ours if its command names our script, however the
    /// path is spelt: `~/.claude/…`, absolute, quoted, or typed in by hand.
    private static func runs(_ entry: Any, _ script: String) -> Bool {
        ((entry as? [String: Any])?["command"] as? String)?.contains(script) == true
    }
    private static func groupRuns(_ group: Any, _ script: String) -> Bool {
        ((group as? [String: Any])?["hooks"] as? [Any])?.contains(where: { runs($0, script) }) == true
    }
    private static func registered(_ root: [String: Any], _ piece: Piece) -> Bool {
        groups(root, piece.event).contains(where: { groupRuns($0, piece.script) })
    }
    /// Why we won't add to this settings.json: `hooks`, or one of our events under it,
    /// isn't the object or list Claude Code writes. Adding ours would mean replacing it.
    private static func unknownShape(_ root: [String: Any]) -> String? {
        guard let hooks = root["hooks"] else { return nil }
        guard let events = hooks as? [String: Any] else { return "\"hooks\" in \(settingsPath) is not an object" }
        for piece in pieces {
            if let there = events[piece.event], !(there is [Any]) {
                return "\"hooks.\(piece.event)\" in \(settingsPath) is not a list"
            }
        }
        return nil
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

    /// Three-way status plus, when stale, what's wrong. `script`/`question`/`binary` are
    /// what an install would copy from; a nil source can't be compared, so only presence
    /// counts. Not installed means none of our three entries is there; with some but not
    /// all (an install from before the question hook was ours, or what unticking used to
    /// leave behind) it is stale, and the install that repairs it adds the rest.
    static func check(script: URL? = bundledScript, question: URL? = bundledQuestionScript,
                      binary: URL? = runningExecutable) -> (status: Status, problems: [String]) {
        let root: [String: Any]
        switch readSettings() {
        case .missing: return (.notInstalled, [])
        case .invalid: return (.notInstalled, ["\(settingsPath) is not valid JSON"])
        case .ok(let r): root = r
        }
        let missing = pieces.filter { !registered(root, $0) }
        guard missing.count < pieces.count else { return (.notInstalled, []) }
        let fm = FileManager.default
        var problems = missing.map { "\($0.event) hook not registered" }
        for (what, source, path) in [("script", script, scriptPath), ("question script", question, questionPath)] {
            if !fm.fileExists(atPath: path) {
                problems.append("\(what) missing")
            } else if let s = source, !sameContents(s.path, path) {
                problems.append("\(what) differs from bundled copy")
            }
        }
        if !fm.isExecutableFile(atPath: binPath) {
            problems.append("binary missing")
        } else if let b = binary, !sameContents(b.path, binPath) {
            problems.append("binary differs from this build")
        }
        return (problems.isEmpty ? .installed : .stale, problems)
    }

    static func status(script: URL? = bundledScript, question: URL? = bundledQuestionScript,
                       binary: URL? = runningExecutable) -> Status {
        check(script: script, question: question, binary: binary).status
    }

    /// Refresh the two scripts and the binary where copies already exist, without touching
    /// settings.json. For a hook registered somewhere we don't read (settings.local.json,
    /// a project's settings) or a settings.json we can't parse: a rebuild still shouldn't
    /// leave those copies running old code. Returns what it did, or "error: …".
    static func refreshFiles(script: URL? = bundledScript, question: URL? = bundledQuestionScript,
                             binary: URL? = runningExecutable) -> String {
        let fm = FileManager.default
        var done: [String] = [], problems: [String] = []
        for (what, source, path) in [("script", script, scriptPath), ("question script", question, questionPath)] {
            guard let s = source, fm.fileExists(atPath: path) else { continue }
            if let e = placeFile(from: s.path, to: path, mode: 0o644) { problems.append("\(what): \(e)") }
            else { done.append(what) }
        }
        if let b = binary, fm.fileExists(atPath: binPath) {
            if let e = placeFile(from: b.path, to: binPath, mode: 0o755) { problems.append("binary: \(e)") }
            else { done.append("binary") }
        }
        if !problems.isEmpty { return "error: " + problems.joined(separator: "; ") }
        return done.isEmpty ? "nothing to refresh" : "refreshed " + done.joined(separator: ", ")
    }

    /// Install or repair every piece: both scripts, the binary, and the three settings
    /// entries. Returns "installed", or "error: …" naming every step that failed.
    /// Idempotent: re-running refreshes the files and leaves an existing settings entry
    /// alone, one put in by hand included; an install that had only the Stop entry (from
    /// before the question hook was ours) gains the other two.
    @discardableResult
    static func install(script: URL? = bundledScript, question: URL? = bundledQuestionScript,
                        binary: URL? = runningExecutable) -> String {
        let fm = FileManager.default
        // Settings first: if the file can't be parsed, touch nothing at all.
        var root: [String: Any] = [:]
        switch readSettings() {
        case .invalid: return "error: \(settingsPath) is not valid JSON — left it untouched"
        case .ok(let r): root = r
        case .missing: break
        }
        if let why = unknownShape(root) { return "error: \(why) — left it untouched" }
        for d in [binDir, hooksDir] {
            do { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
            catch { return "error: couldn't create \(d): \(error.localizedDescription)" }
        }

        var problems: [String] = []
        for (what, source, path) in [("script", script, scriptPath), ("question script", question, questionPath)] {
            if let s = source {
                if let e = placeFile(from: s.path, to: path, mode: 0o644) { problems.append("\(what): \(e)") }
            } else if !fm.fileExists(atPath: path) {
                let name = (path as NSString).lastPathComponent
                problems.append("\(what): no bundled \(name) to install (run this from SpeakHUD.app)")
            }
        }
        // Registering a hook that points at nothing is the silent failure we're avoiding,
        // and the question hook runs on the Stop hook's code: both scripts, or neither hook.
        guard fm.fileExists(atPath: scriptPath), fm.fileExists(atPath: questionPath) else {
            return "error: " + problems.joined(separator: "; ") + " — hooks not registered"
        }
        if let b = binary {
            if let e = placeFile(from: b.path, to: binPath, mode: 0o755) { problems.append("binary: \(e)") }
        } else {
            problems.append("binary: couldn't locate the running executable")
        }

        // Only what's missing is added, each as a group of its own after whatever is on
        // that event; with all three there, settings.json isn't rewritten at all.
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let missing = pieces.filter { !registered(root, $0) }
        for piece in missing { hooks[piece.event] = groups(root, piece.event) + [piece.group] }
        if !missing.isEmpty {
            root["hooks"] = hooks
            if !write(root) { problems.append("settings: couldn't write \(settingsPath)") }
        }
        return problems.isEmpty ? "installed" : "error: " + problems.joined(separator: "; ")
    }

    /// Remove only our entries: the Stop hook's, and the question hook's two, so questions
    /// stop being read along with turns. Sibling hooks in the same group stay; a group is
    /// dropped only once it's empty, an event only once it has no groups. The scripts and
    /// binary are left in place.
    @discardableResult
    static func remove() -> String {
        var root: [String: Any]
        switch readSettings() {
        case .missing: return "nothing to remove"
        case .invalid: return "error: \(settingsPath) is not valid JSON — left it untouched"
        case .ok(let r): root = r
        }
        guard var hooks = root["hooks"] as? [String: Any] else { return "nothing to remove" }
        var found = false
        for piece in pieces where registered(root, piece) {
            found = true
            let kept: [Any] = groups(root, piece.event).compactMap { group -> Any? in
                guard groupRuns(group, piece.script), var g = group as? [String: Any],
                      var inner = g["hooks"] as? [Any] else { return group }
                inner.removeAll(where: { runs($0, piece.script) })
                if inner.isEmpty { return nil }
                g["hooks"] = inner
                return g
            }
            if kept.isEmpty { hooks.removeValue(forKey: piece.event) } else { hooks[piece.event] = kept }
        }
        guard found else { return "nothing to remove" }
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

// Codex uses a JSON argv notification rather than Claude's stdin Stop hook.
// The helper parses TOML with Python's standard library and preserves the user's
// config verbatim outside our own marked block. Shared speech code stays beside it.
enum CodexHook {
    static func run(_ action: String) -> String {
        let env = ProcessInfo.processInfo.environment
        let home = NSString(string: env["CODEX_HOME"] ?? "~/.codex").expandingTildeInPath
        let script = Bundle.main.url(forResource: "setup-codex", withExtension: "py")?.path
            ?? home + "/speakhud/setup-codex.py"
        guard FileManager.default.isReadableFile(atPath: script) else {
            return "error: no bundled setup-codex.py (run this from SpeakHUD.app)"
        }
        let candidates = (env["PATH"] ?? "").split(separator: ":").map { String($0) + "/python3" }
            + ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        var tried: Set<String> = []
        for python in candidates where tried.insert(python).inserted && FileManager.default.isExecutableFile(atPath: python) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script, action, ClaudeHook.runningExecutable?.path ?? ""]
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() }
            catch { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let result = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if result.hasPrefix("error: Codex setup needs Python") { continue }
            if process.terminationStatus != 0 && !result.hasPrefix("error") {
                return "error: Codex setup failed: " + result
            }
            return result
        }
        return "error: Codex setup needs Python 3.11 or later (brew install python)"
    }
}
