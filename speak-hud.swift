import Cocoa
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox

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
        if a == "--source" { i += 2; continue }   // flag + its value
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
}

// Claude Code turns arrive as files here rather than as processes, so a finished
// turn can never interrupt one that's already speaking. The hook writes `<name>.tmp`
// and renames it to `<name>.json`, which is atomic within a filesystem — the agent
// therefore never observes a half-written item.
enum Spool {
    static let maxAge: TimeInterval = 600   // a stopped agent shouldn't wake up and read you the backlog
    static var dir: String { NSString(string: "~/.local/state/speakhud/queue").expandingTildeInPath }

    static func ensure() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    /// Items a previous agent had picked up but never finished speaking — it was
    /// restarted or crashed mid-queue. Hand them back so they get another turn.
    static func recover() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in names where name.hasSuffix(".taken") {
            let stem = String(name.dropLast(6))
            try? fm.moveItem(atPath: dir + "/" + name, toPath: dir + "/" + stem + ".json")
        }
    }

    /// Take every queued item, in arrival order. A taken item is renamed rather than
    /// deleted, so it still exists on disk until it has actually been spoken; `done()`
    /// is what finally removes it.
    static func drain() -> [SpeechItem] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [SpeechItem] = []
        for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let stem = String(name.dropLast(5))
            let taken = dir + "/" + stem + ".taken"
            // Claim it atomically; if the rename loses, someone else has it.
            guard (try? fm.moveItem(atPath: dir + "/" + name, toPath: taken)) != nil else { continue }
            guard let data = fm.contents(atPath: taken),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["text"] as? String, !text.isEmpty
            else { done(taken); continue }   // malformed: drop it, don't wedge the queue
            let created = Date(timeIntervalSince1970: obj["created"] as? Double ?? 0)
            guard Date().timeIntervalSince(created) < maxAge else { done(taken); continue }
            out.append(SpeechItem(text: text,
                                  source: obj["source"] as? String ?? "Claude Code",
                                  key: obj["key"] as? String ?? stem,
                                  created: created,
                                  file: taken))
        }
        return out
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
// Global hotkeys. One Carbon handler for the whole process, dispatching on the
// hotkey id — installing a handler per feature would fire all of them on any key.
// ---------------------------------------------------------------------------

enum HotKeyAction: UInt32 { case read = 1, togglePause = 2 }

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
}

/// A colored pill naming whoever is speaking.
final class SourceBadge: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var accent: NSColor = .systemBlue { didSet { needsDisplay = true } }

    private static let dot: CGFloat = 7
    private static let padX: CGFloat = 11
    private static let gap: CGFloat = 7
    private static let maxWidth: CGFloat = 260
    static let height: CGFloat = 24

    private var textAttrs: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail   // long repo names shouldn't stretch the pill
        return [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: accent,
                .paragraphStyle: p]
    }

    override var intrinsicContentSize: NSSize {
        let w = (text as NSString).size(withAttributes: textAttrs).width
        return NSSize(width: min(ceil(w) + Self.padX * 2 + Self.dot + Self.gap, Self.maxWidth),
                      height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let pill = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: r.height / 2, yRadius: r.height / 2)
        accent.withAlphaComponent(0.18).setFill(); pill.fill()
        accent.withAlphaComponent(0.5).setStroke(); pill.lineWidth = 1; pill.stroke()

        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: Self.padX, y: (r.height - Self.dot) / 2,
                                    width: Self.dot, height: Self.dot)).fill()

        let attrs = textAttrs
        let s = text as NSString
        let th = s.size(withAttributes: attrs).height
        let x = Self.padX + Self.dot + Self.gap
        s.draw(in: NSRect(x: x, y: (r.height - th) / 2, width: r.width - x - Self.padX, height: th),
               withAttributes: attrs)
    }
}

// ---------------------------------------------------------------------------
// The HUD. Owns the queue: exactly one item speaks at a time, and a finished
// Claude Code turn waits its turn instead of killing the one you're listening to.
// ---------------------------------------------------------------------------

final class Controller: NSObject, AVSpeechSynthesizerDelegate, NSWindowDelegate {
    // Replaced on every (re)start: stopSpeaking(.immediate) poisons an instance so
    // the next utterance silently finishes with no audio. A fresh synth avoids that.
    var synth = AVSpeechSynthesizer()

    private(set) var current: SpeechItem?
    private(set) var queue: [SpeechItem] = []
    /// Standalone reader exits; the agent just hides the panel and keeps listening.
    var onIdle: () -> Void = { NSApp.terminate(nil) }
    /// Where queue transitions go. The agent points this at its log file.
    var log: (String) -> Void = { _ in }
    private var startedSpeaking = Date()

    var panel: NSPanel!
    var statusLabel: NSTextField!
    var queueLabel: NSTextField!
    var sourceBadge: SourceBadge!
    var nextLabel: NSTextField!
    var pauseBtn: NSButton!
    var speedBtn: NSButton!
    var skipBtn: NSButton!
    var textView: NSTextView!
    var closeTimer: Timer?

    // Speed control. AVSpeech can't change rate mid-utterance, so changing speed
    // restarts speaking from the current word at the new rate. macOS default rate
    // (0.5) == 1×; the steps below scale around it.
    let rateSteps: [Float]  = [0.375, 0.5, 0.625, 0.75, 0.875, 1.0]
    let rateLabels: [String] = ["0.75×", "1×", "1.25×", "1.5×", "1.75×", "2×"]
    static let rateKey = "speakRateIndex"   // UserDefaults key for persisted speed
    var rateIndex = 1
    var nsText: NSString = ""
    var speakStart = 0     // char offset in the current item where the utterance begins
    var lastWordStart = 0  // char offset of the word currently being spoken

    override init() {
        super.init()
        synth.delegate = self
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

    // -- queue -------------------------------------------------------------

    /// An item that will never be spoken again releases its spool file.
    private func retire(_ item: SpeechItem?) { Spool.done(item?.file) }

    /// Wait your turn. A second turn from the same session replaces the first one
    /// still waiting in line — you want the latest answer, not a stale one.
    /// Returns true if nothing was speaking and this item started straight away.
    @discardableResult
    func enqueue(_ item: SpeechItem) -> Bool {
        if let i = queue.firstIndex(where: { $0.key == item.key }) {
            retire(queue[i])  // the stale turn is never spoken; let go of its file
            queue[i] = item   // keep its place in line; a chatty session shouldn't jump the queue
        } else {
            queue.append(item)
        }
        guard current == nil else { updateQueueUI(); return false }
        // current == nil only ever happens with an empty queue, so advance() picks
        // up the item we just appended.
        advance()
        return true
    }

    /// Jump the queue. Used for hotkey reads: you highlighted that text and asked
    /// for it now, so it shouldn't sit behind Claude's narration.
    func playNow(_ item: SpeechItem) {
        closeTimer?.invalidate()
        if let c = current { log("preempted \(c.source)"); retire(c) }
        start(item)
    }

    @objc func skip() {
        if let c = current { log("skipped \(c.source)"); retire(c) }
        synth.stopSpeaking(at: .immediate)
        advance()
    }

    private func advance() {
        if queue.isEmpty {
            current = nil
            statusLabel?.stringValue = "Done"
            clearHighlight()
            updateQueueUI()
            scheduleAutoClose(after: 8)
        } else {
            start(queue.removeFirst())
        }
    }

    private func start(_ item: SpeechItem) {
        closeTimer?.invalidate()
        current = item
        startedSpeaking = Date()
        nsText = item.text as NSString
        speakStart = 0
        lastWordStart = 0
        buildWindowIfNeeded()
        textView.string = item.text
        sourceBadge.text = item.source
        sourceBadge.accent = Accent.color(for: item.source)
        sourceBadge.setFrameSize(sourceBadge.intrinsicContentSize)
        updateQueueUI()
        panel.orderFrontRegardless()
        log("start \(item.source) (\(item.text.count) chars)")
        speak()
    }

    private func updateQueueUI() {
        guard queueLabel != nil else { return }
        queueLabel.stringValue = queue.isEmpty ? "" : "▸ \(queue.count) queued"
        nextLabel.attributedStringValue = queuePreview()
        skipBtn.isEnabled = !queue.isEmpty
    }

    /// "next: Alpha, Beta", each name in its project's color.
    private func queuePreview() -> NSAttributedString {
        guard !queue.isEmpty else { return NSAttributedString(string: "") }
        let dim: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let out = NSMutableAttributedString(string: "next: ", attributes: dim)
        for (i, item) in queue.prefix(3).enumerated() {
            if i > 0 { out.append(NSAttributedString(string: ", ", attributes: dim)) }
            out.append(NSAttributedString(string: item.source, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: Accent.color(for: item.source),
            ]))
        }
        if queue.count > 3 { out.append(NSAttributedString(string: "…", attributes: dim)) }
        return out
    }

    // -- speech ------------------------------------------------------------

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
            statusLabel?.stringValue = "🔊 Speaking…  \(rateLabels[rateIndex])"
            pauseBtn?.title = "❚❚ Pause"
        } else if synth.isSpeaking {
            synth.pauseSpeaking(at: .word)
            statusLabel?.stringValue = "⏸ Paused"
            pauseBtn?.title = "▶ Resume"
        }
    }

    /// Stop everything and throw the queue away. Note this discards what's waiting —
    /// "Skip" is the one that moves on to the next item.
    @objc func stopAll() {
        closeTimer?.invalidate()
        synth.stopSpeaking(at: .immediate)
        log("stop: discarded \(queue.count) queued item(s)")
        retire(current)
        queue.forEach { retire($0) }
        queue.removeAll()
        current = nil
        updateQueueUI()
        onIdle()
    }

    func hidePanel() {
        closeTimer?.invalidate()
        panel?.orderOut(nil)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        // A synth we already replaced can still deliver this; ignore it or we'd
        // advance the queue twice for one item.
        guard s === synth else { return }
        let elapsed = Date().timeIntervalSince(startedSpeaking)
        if let c = current {
            log(String(format: "finish %@ after %.1fs", c.source, elapsed))
            retire(c)
        }
        // Never re-enter AVSpeechSynthesizer from inside its own delegate callback:
        // advance() replaces `synth`, deallocating the very instance calling us, and
        // the next utterance can be dropped without a sound. Hop out of the callback.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, s === self.synth else { return }  // superseded meanwhile
            self.advance()
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {}

    // Karaoke-style follow: highlight + scroll to the word currently being spoken.
    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        guard s === synth else { return }
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
        closeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.onIdle()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        stopAll()
        return false   // stopAll already hid (or terminated) us
    }

    // -- window ------------------------------------------------------------

    func buildWindowIfNeeded() {
        guard panel == nil else { return }
        let w: CGFloat = 440, h: CGFloat = 330
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
        panel.minSize = NSSize(width: 380, height: 260)
        panel.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // Who's talking — the loudest thing in the window, because with several
        // terminals queued it's the first thing you need to know. Indented past the
        // traffic lights, which float over this content view (.fullSizeContentView).
        let badge = SourceBadge(frame: NSRect(x: 80, y: h - 34, width: 140, height: SourceBadge.height))
        badge.autoresizingMask = [.minYMargin]
        content.addSubview(badge)
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
        let label = NSTextField(labelWithString: "🔊 Speaking…")
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
        let hint = NSTextField(labelWithString: "Pause / Resume anywhere:  ⌃⌥P")
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
        pauseBtn = button("❚❚ Pause", 96, 86, #selector(togglePause))
        content.addSubview(pauseBtn)
        speedBtn = button("⏩ \(rateLabels[rateIndex])", 186, 70, #selector(changeSpeed))
        content.addSubview(speedBtn)
        skipBtn = button("⏭ Skip", 260, 66, #selector(skip))
        skipBtn.isEnabled = false
        content.addSubview(skipBtn)
        content.addSubview(button("■ Stop", 330, 66, #selector(stopAll)))

        panel.contentView = content

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.maxX - w - 20, y: vf.maxY - h - 20))
        }
        self.panel = panel
    }
}

// ---------------------------------------------------------------------------
// Global hotkey + background agent (read the selection from anywhere)
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

// Installs/removes the Claude Code "Stop" hook that reads each response aloud, so
// a downloaded copy can replicate the author's setup with one click. All edits to
// ~/.claude/settings.json are idempotent merges — existing keys are preserved.
// Set SPEAKHUD_CLAUDE_DIR to point at a different dir (used by tests).
enum ClaudeHook {
    static var dir: String {
        if let d = ProcessInfo.processInfo.environment["SPEAKHUD_CLAUDE_DIR"], !d.isEmpty {
            return NSString(string: d).expandingTildeInPath
        }
        return NSString(string: "~/.claude").expandingTildeInPath
    }
    static var settingsPath: String { dir + "/settings.json" }
    static var scriptPath: String { dir + "/read-summary.py" }
    static var binDir: String { dir + "/bin" }
    static var binPath: String { binDir + "/speak-hud" }
    static let hookCommand = "python3 ~/.claude/read-summary.py"

    private static func stopGroups(_ root: [String: Any]) -> [[String: Any]] {
        (root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
    }
    private static func groupHasOurs(_ group: [String: Any]) -> Bool {
        guard let inner = group["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String)?.contains("read-summary.py") == true }
    }

    static func isInstalled() -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return stopGroups(root).contains(where: groupHasOurs)
    }

    @discardableResult
    static func install() -> String {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        // 1) Drop read-summary.py and the reader binary into ~/.claude.
        if let src = Bundle.main.url(forResource: "read-summary", withExtension: "py"),
           let data = try? Data(contentsOf: src) {
            try? data.write(to: URL(fileURLWithPath: scriptPath))
        }
        try? fm.removeItem(atPath: binPath)
        try? fm.copyItem(atPath: CommandLine.arguments[0], toPath: binPath)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binPath)
        // 2) Merge the Stop hook into settings.json (preserving everything else).
        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "error: ~/.claude/settings.json is not valid JSON — left it untouched"
            }
            root = parsed
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var stop = hooks["Stop"] as? [[String: Any]] ?? []
        if !stop.contains(where: groupHasOurs) {
            stop.append(["hooks": [["type": "command", "command": hookCommand, "async": true]]])
        }
        hooks["Stop"] = stop
        root["hooks"] = hooks
        return write(root) ? "installed" : "error: could not write settings.json"
    }

    @discardableResult
    static func remove() -> String {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: settingsPath),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "nothing to remove" }
        if var hooks = root["hooks"] as? [String: Any],
           var stop = hooks["Stop"] as? [[String: Any]] {
            stop.removeAll(where: groupHasOurs)
            if stop.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = stop }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
        return write(root) ? "removed" : "error: could not write settings.json"
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

// Background listener: owns the one HUD, the speech queue, and the global hotkey.
// Runs from a LaunchAgent; no window/Dock until something needs reading.
final class Agent {
    static weak var shared: Agent?
    let hud = Controller()
    var spoolSource: DispatchSourceFileSystemObject?
    var pollTimer: Timer?
    var usr1: DispatchSourceSignal?

    /// launchd routes stderr to ~/Library/Logs/speakhud-agent.log (see build.sh).
    func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write("[\(ts)] \(message)\n".data(using: .utf8)!)
    }

    func run() {
        Agent.shared = self
        hud.onIdle = { [weak self] in self?.hud.hidePanel() }
        hud.log = { [weak self] in self?.log($0) }
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
        watchSpool()
        // SIGUSR1 also triggers a read — lets the install step self-test without keys.
        signal(SIGUSR1, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s.setEventHandler { Agent.shared?.readClipboard() }
        s.resume()
        usr1 = s
    }

    func registerReadHotKey() {
        let spec = HotkeyConfig.load()
        guard let hk = parseHotkey(spec) else {
            log("invalid hotkey \"\(spec)\" — not registered")
            return
        }
        let ok = HotKeyCenter.shared.register(.read, keyCode: hk.keyCode, mods: hk.mods) { [weak self] in
            self?.readSelection()
        }
        log(ok ? "listening for \(spec)" : "could not register \(spec) — another app owns it")
    }

    // -- spool -------------------------------------------------------------

    private func watchSpool() {
        Spool.ensure()
        Spool.recover()   // whatever the last agent died holding gets another turn
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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.drainSpool()
        }
        drainSpool()
    }

    private func drainSpool() {
        for item in Spool.drain() {
            if hud.enqueue(item) {
                log("speaking \(item.source)")
            } else {
                log("queued \(item.source) — \(hud.queue.count) waiting")
            }
        }
    }

    // -- reads -------------------------------------------------------------

    /// Hotkey: read whatever is highlighted in the frontmost app.
    func readSelection() {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Selection"
        // No selection (or no Accessibility grant) falls back to the clipboard,
        // which is exactly what this hotkey did before it could see selections.
        play(Selection.current() ?? NSPasteboard.general.string(forType: .string) ?? "", source: app)
    }

    /// Menu item / double-clicking the app: there's no meaningful selection when
    /// SpeakHUD itself is frontmost, so read the clipboard.
    func readClipboard() {
        play(NSPasteboard.general.string(forType: .string) ?? "", source: "Clipboard")
    }

    private func play(_ raw: String, source: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { NSSound.beep(); return }
        hud.playNow(SpeechItem(text: text, source: source, key: UUID().uuidString, created: Date()))
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
    let hotkeyPresets = [("⌃⌥S", "ctrl+opt+s"), ("⌃⌥R", "ctrl+opt+r"),
                         ("⌃⌥Space", "ctrl+opt+space"), ("⌘⌥S", "cmd+opt+s")]
    var hotkeyItems: [NSMenuItem] = []

    init(_ agent: Agent) { self.agent = agent; super.init(); build() }

    private func build() {
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "SpeakHUD")
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("Read Clipboard Aloud", #selector(readClipboard)))
        menu.addItem(.separator())

        claudeItem = item("Read Claude Code Responses Aloud", #selector(toggleClaude))
        menu.addItem(claudeItem)

        let hk = NSMenu()
        for (label, spec) in hotkeyPresets {
            let it = item(label, #selector(pickHotkey(_:))); it.representedObject = spec
            hk.addItem(it); hotkeyItems.append(it)
        }
        hk.addItem(.separator())
        hk.addItem(item("Edit Config File…", #selector(openHotkeyConfig)))
        let hkParent = NSMenuItem(title: "Global Hotkey", action: nil, keyEquivalent: "")
        hkParent.submenu = hk
        menu.addItem(hkParent)

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
        claudeItem.state = ClaudeHook.isInstalled() ? .on : .off
        axItem.isHidden = Selection.isTrusted
        let current = HotkeyConfig.load()
        for it in hotkeyItems { it.state = (it.representedObject as? String == current) ? .on : .off }
    }

    @objc private func readClipboard() { agent.readClipboard() }
    @objc private func toggleClaude() {
        _ = ClaudeHook.isInstalled() ? ClaudeHook.remove() : ClaudeHook.install()
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
    @objc private func openHotkeyConfig() {
        HotkeyConfig.save(HotkeyConfig.load())   // make sure the file exists first
        NSWorkspace.shared.open(URL(fileURLWithPath: HotkeyConfig.path))
    }
    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/chris-jk/SpeakHUD")!)
    }
    @objc private func quit() { NSApp.terminate(nil) }
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

if argv.contains("--setup-claude")  { print(ClaudeHook.install()); exit(0) }
if argv.contains("--remove-claude") { print(ClaudeHook.remove());  exit(0) }
if argv.contains("--claude-status") { print(ClaudeHook.isInstalled() ? "installed" : "not installed"); exit(0) }

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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, doesn't steal focus
let controller = Controller()
controller.onIdle = { NSApp.terminate(nil) }
HotKeyCenter.shared.register(.togglePause,
                             keyCode: UInt32(kVK_ANSI_P),
                             mods: UInt32(controlKey | optionKey)) { [weak controller] in
    controller?.togglePause()
}
controller.enqueue(SpeechItem(text: text, source: sourceName, key: UUID().uuidString, created: Date()))
app.run()
