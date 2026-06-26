import Cocoa
import AVFoundation
import Carbon.HIToolbox

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
        if let saved = UserDefaults.standard.object(forKey: Self.rateKey) as? Int,
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
        UserDefaults.standard.set(rateIndex, forKey: Self.rateKey)   // remember it
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

let text = resolveText().trimmingCharacters(in: .whitespacesAndNewlines)
if text.isEmpty { exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, doesn't steal focus
let controller = Controller(text: text)
controller.buildWindow()
controller.registerHotKey()
controller.speak()
app.run()
