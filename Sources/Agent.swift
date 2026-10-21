import Cocoa
import Carbon.HIToolbox

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
    private static let stamp = ISO8601DateFormatter()   // one, not one per line: they're slow to make
    func log(_ message: String) {
        let ts = Self.stamp.string(from: Date())
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
        hud.watchAudio()
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
