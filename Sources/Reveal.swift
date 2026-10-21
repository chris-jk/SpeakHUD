import Cocoa

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
