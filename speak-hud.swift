import Cocoa
import AVFoundation
import Carbon.HIToolbox

// Shared prefs domain so the speed setting is the same no matter how the reader
// was launched (double-click app, Claude Code hook, or the global hotkey).
// NB: the suite name must NOT equal the app's bundle id, or macOS rejects it.
let prefs = UserDefaults(suiteName: "com.chris.speakhud.shared") ?? .standard

// Text source priority: explicit arg → piped stdin (the Claude Code hook) →
// clipboard. The clipboard fallback is what makes the .app useful when launched
// on its own (double-click / Spotlight / a hotkey), where there's no stdin pipe.
func resolveText() -> String {
    let args = CommandLine.arguments
    if args.count > 1, !args[1].isEmpty { return args[1] }
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

final class Controller: NSObject, AVSpeechSynthesizerDelegate {
    // Replaced on every (re)start: stopSpeaking(.immediate) poisons an instance so
    // the next utterance silently finishes with no audio. A fresh synth avoids that.
    var synth = AVSpeechSynthesizer()
    let text: String
    let nsText: NSString
    var panel: NSPanel!
    var statusLabel: NSTextField!
    var pauseBtn: NSButton!
    var speedBtn: NSButton!
    var textView: NSTextView!
    var closeTimer: Timer?
    var hotKeyRef: EventHotKeyRef?
    static weak var shared: Controller?

    // Speed control. AVSpeech can't change rate mid-utterance, so changing speed
    // restarts speaking from the current word at the new rate. macOS default rate
    // (0.5) == 1×; the steps below scale around it.
    let rateSteps: [Float]  = [0.375, 0.5, 0.625, 0.75, 0.875, 1.0]
    let rateLabels: [String] = ["0.75×", "1×", "1.25×", "1.5×", "1.75×", "2×"]
    static let rateKey = "speakRateIndex"   // UserDefaults key for persisted speed
    var rateIndex = 1
    var speakStart = 0     // char offset in `text` where the current utterance begins
    var lastWordStart = 0  // char offset of the word currently being spoken

    init(text: String) {
        self.text = text
        self.nsText = text as NSString
        super.init()
        synth.delegate = self
        Controller.shared = self
        // Restore the last speed the user picked…
        if let saved = prefs.object(forKey: Self.rateKey) as? Int,
           saved >= 0, saved < rateSteps.count {
            rateIndex = saved
        }
        // …but let an explicit SPEAK_RATE env override win for this invocation.
        if let r = ProcessInfo.processInfo.environment["SPEAK_RATE"], let f = Float(r), f > 0 {
            rateIndex = rateSteps.enumerated().min(by: { abs($0.1 - f) < abs($1.1 - f) })!.0
        }
    }

    // System-wide ⌃⌥P toggles pause/resume. Carbon hotkeys need no Accessibility permission.
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, _) -> OSStatus in
            Controller.shared?.togglePause()
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x53504b59) /* 'SPKY' */, id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey),
                            id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func utterance() -> AVSpeechUtterance {
        // Speak from the current resume point so a mid-stream speed change picks up
        // where we left off rather than restarting from the top.
        let start = nsText.length > 0 ? min(speakStart, nsText.length) : 0
        let slice = nsText.substring(from: start)
        let u = AVSpeechUtterance(string: slice)
        let env = ProcessInfo.processInfo.environment
        if let id = env["SPEAK_VOICE"], !id.isEmpty {
            // Accept either a voice identifier or a name; fall back gracefully.
            if let v = AVSpeechSynthesisVoice(identifier: id) { u.voice = v }
            else if let v = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == id }) { u.voice = v }
        }
        u.rate = rateSteps[rateIndex]
        return u
    }

    func speak() {
        closeTimer?.invalidate()
        // Swap in a fresh synthesizer — reusing one after .immediate stop drops audio.
        synth.stopSpeaking(at: .immediate)
        synth = AVSpeechSynthesizer()
        synth.delegate = self
        statusLabel?.stringValue = "🔊 Speaking…  \(rateLabels[rateIndex])"
        pauseBtn?.title = "❚❚ Pause"
        synth.speak(utterance())
    }

    @objc func replay() { speakStart = 0; lastWordStart = 0; speak() }

    // Cycle the playback speed; resume speaking from the current word at the new rate.
    @objc func changeSpeed() {
        rateIndex = (rateIndex + 1) % rateSteps.count
        prefs.set(rateIndex, forKey: Self.rateKey)   // remember it
        speedBtn?.title = "⏩ \(rateLabels[rateIndex])"
        let wasActive = synth.isSpeaking || synth.isPaused
        if wasActive {
            speakStart = lastWordStart   // pick up from the word we were on
            speak()
        }
    }
    @objc func togglePause() {
        if synth.isPaused {
            synth.continueSpeaking()
            statusLabel?.stringValue = "🔊 Speaking…"
            pauseBtn?.title = "❚❚ Pause"
        } else if synth.isSpeaking {
            synth.pauseSpeaking(at: .word)
            statusLabel?.stringValue = "⏸ Paused"
            pauseBtn?.title = "▶ Resume"
        }
    }
    @objc func stopAndClose() { synth.stopSpeaking(at: .immediate); NSApp.terminate(nil) }
    @objc func closeOnly() { NSApp.terminate(nil) }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        statusLabel?.stringValue = "Done"
        clearHighlight()
        scheduleAutoClose(after: 8)
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {}

    // Karaoke-style follow: highlight + scroll to the word currently being spoken.
    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        // Ranges are relative to the (possibly sliced) utterance; shift to full-text coords.
        let full = NSRange(location: speakStart + characterRange.location, length: characterRange.length)
        lastWordStart = full.location
        guard let tv = textView, let storage = tv.textStorage else { return }
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        if NSMaxRange(full) <= storage.length {
            storage.addAttribute(.backgroundColor, value: NSColor.findHighlightColor, range: full)
            tv.scrollRangeToVisible(full)
        }
    }

    private func clearHighlight() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
    }

    private func scheduleAutoClose(after seconds: TimeInterval) {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            NSApp.terminate(nil)
        }
    }

    func buildWindow() {
        let w: CGFloat = 440, h: CGFloat = 300
        let panel = NSPanel(
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
        panel.minSize = NSSize(width: 360, height: 200)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // Status (pinned to top)
        let label = NSTextField(labelWithString: "🔊 Speaking…")
        label.frame = NSRect(x: 16, y: h - 30, width: w - 32, height: 20)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.autoresizingMask = [.width, .minYMargin]
        content.addSubview(label)
        statusLabel = label

        // Full response text — scrollable, auto-follows speech (fills the middle)
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 78, width: w - 32, height: h - 114))
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
        tv.string = text
        scroll.documentView = tv
        content.addSubview(scroll)
        textView = tv

        // Hotkey hint (above buttons, pinned to bottom)
        let hint = NSTextField(labelWithString: "Pause / Resume anywhere:  ⌃⌥P")
        hint.frame = NSRect(x: 16, y: 52, width: w - 32, height: 14)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(hint)

        // Buttons (pinned to bottom)
        func button(_ title: String, _ x: CGFloat, _ width: CGFloat, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.frame = NSRect(x: x, y: 14, width: width, height: 26)
            b.bezelStyle = .rounded
            b.autoresizingMask = [.maxYMargin]
            return b
        }
        content.addSubview(button("↻ Replay", 14, 78, #selector(replay)))
        pauseBtn = button("❚❚ Pause", 96, 86, #selector(togglePause))
        content.addSubview(pauseBtn)
        speedBtn = button("⏩ \(rateLabels[rateIndex])", 186, 70, #selector(changeSpeed))
        content.addSubview(speedBtn)
        content.addSubview(button("■ Stop", 260, 66, #selector(stopAndClose)))
        content.addSubview(button("Close", 330, 62, #selector(closeOnly)))

        panel.contentView = content

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.maxX - w - 20, y: vf.maxY - h - 20))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

// ---------------------------------------------------------------------------
// Global hotkey + background agent (read the clipboard from anywhere)
// ---------------------------------------------------------------------------

// Stored at ~/.config/speakhud/config.json so you can set your own combo.
enum HotkeyConfig {
    static let defaultSpec = "ctrl+opt+s"
    static var dir: String { NSString(string: "~/.config/speakhud").expandingTildeInPath }
    static var path: String { dir + "/config.json" }
    static func load() -> String {
        if let data = FileManager.default.contents(atPath: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hk = (obj["hotkey"] as? String)?.trimmingCharacters(in: .whitespaces),
           !hk.isEmpty { return hk }
        return defaultSpec
    }
    @discardableResult
    static func save(_ spec: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let json = "{\n  \"hotkey\": \"\(spec)\"\n}\n"
        return (try? json.write(toFile: path, atomically: true, encoding: .utf8)) != nil
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

// Background listener: registers the global hotkey and, on press, launches the
// reader (which reads the clipboard). Runs from a LaunchAgent; no window/Dock.
final class Agent {
    static weak var shared: Agent?
    var hotKeyRef: EventHotKeyRef?
    var reader: Process?
    var usr1: DispatchSourceSignal?
    let readerPath = CommandLine.arguments[0]

    func run() {
        Agent.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            Agent.shared?.trigger(); return noErr
        }, 1, &spec, nil, nil)
        register()
        // SIGUSR1 also triggers a read — lets the install step self-test without keys.
        signal(SIGUSR1, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s.setEventHandler { Agent.shared?.trigger() }
        s.resume()
        usr1 = s
    }

    func register() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        let spec = HotkeyConfig.load()
        guard let hk = parseHotkey(spec) else {
            FileHandle.standardError.write("SpeakHUD agent: invalid hotkey \"\(spec)\"\n".data(using: .utf8)!)
            return
        }
        let id = EventHotKeyID(signature: OSType(0x53504b41) /* 'SPKA' */, id: 1)
        RegisterEventHotKey(hk.keyCode, hk.mods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        FileHandle.standardError.write("SpeakHUD agent: listening for \(spec)\n".data(using: .utf8)!)
    }

    func trigger() {
        reader?.terminate()                 // replace any in-progress read
        let p = Process()
        p.executableURL = URL(fileURLWithPath: readerPath)   // no args -> reads clipboard
        p.standardInput = FileHandle.nullDevice
        try? p.run()
        reader = p
    }
}

// Because the agent is a running instance of the app bundle, double-clicking
// SpeakHUD.app doesn't launch a new reader — macOS just "reopens" the agent.
// Treat that reopen as "read the clipboard", so double-click does what you'd expect.
final class AgentDelegate: NSObject, NSApplicationDelegate {
    let agent: Agent
    init(_ agent: Agent) { self.agent = agent }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        agent.trigger()
        return true
    }
}

// ---------------------------------------------------------------------------
// Entry point: dispatch on mode.
// ---------------------------------------------------------------------------
let argv = CommandLine.arguments

if let i = argv.firstIndex(of: "--set-hotkey") {
    guard i + 1 < argv.count, parseHotkey(argv[i + 1]) != nil else {
        FileHandle.standardError.write(
            "usage: speak-hud --set-hotkey \"ctrl+opt+s\"  (need ≥1 modifier + a key)\n".data(using: .utf8)!)
        exit(2)
    }
    let spec = argv[i + 1]
    HotkeyConfig.save(spec)
    // Restart the agent so it picks up the new combo (no-op if it isn't installed).
    let kick = Process()
    kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    kick.arguments = ["kickstart", "-k", "gui/\(getuid())/com.chris.speakhud.agent"]
    try? kick.run(); kick.waitUntilExit()
    print("hotkey set to \(spec)")
    exit(0)
}

if argv.contains("--agent") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let agent = Agent()
    let agentDelegate = AgentDelegate(agent)
    app.delegate = agentDelegate          // handles double-click "reopen" -> read clipboard
    agent.run()
    app.run()
    exit(0)
}

// Default: the reader HUD.
let text = resolveText().trimmingCharacters(in: .whitespacesAndNewlines)
if text.isEmpty { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, doesn't steal focus
let controller = Controller(text: text)
controller.buildWindow()
controller.registerHotKey()
controller.speak()
app.run()
