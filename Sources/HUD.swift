import Cocoa

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

    // Audio wait: another app is making sound, so we stay quiet until it stops.
    private var audioWatch: AnyObject?
    private var audioHold: AudioHold!
    private var audioWho: String?   // who started the current sound, for the log

    /// "Wait While Audio Plays". Off releases any hold now. Persisted in the shared suite.
    var waitWhileAudioPlays: Bool {
        get { audioHold.enabled }
        set {
            audioHold.setEnabled(newValue)
            AudioHold.store(newValue, in: prefs)
            log("wait while audio plays: \(newValue ? "on" : "off")")
        }
    }

    /// "Read Responses Aloud": the one switch over every tool's turns (Claude Code, Codex,
    /// OpenCode). Off, turns still reach the phone but nothing is read here. The hotkey and
    /// Read Clipboard still read: those are asked for by hand. Persisted in the shared suite.
    static let readTurnsKey = "readTurns"
    var readTurns: Bool {
        get { prefs.object(forKey: Controller.readTurnsKey) as? Bool ?? true }
        set {
            prefs.set(newValue, forKey: Controller.readTurnsKey)
            log("read responses aloud: \(newValue ? "on" : "off")")
        }
    }

    /// "A Voice per Project". Takes effect from the next turn read. Persisted in the shared suite.
    var voicePerProject: Bool {
        get { VoiceCast.enabled(in: prefs) }
        set {
            prefs.set(newValue, forKey: VoiceCast.prefKey)
            log("a voice per project: \(newValue ? "on" : "off")")
        }
    }

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
            // Listening isn't speaking: a HUD clicked out of the way stays there.
            if !self.isMinimized, self.panel?.isBehind == false { self.panel?.orderFrontRegardless() }
            NSSound(named: "Tink")?.play()   // your turn
        }
        playback.onReplied = { outcome in
            NSSound(named: outcome == .sent ? "Pop" : "Basso")?.play()
        }
        playback.onEarFailed = { _ in NSSound(named: "Basso")?.play() }
        micHold = MicHold(enabled: MicHold.storedEnabled(in: prefs)) { [weak self] busy in
            self?.playback.micChanged(busy: busy)
        }
        audioHold = AudioHold(enabled: AudioHold.storedEnabled(in: prefs)) { [weak self] busy in
            if busy, let who = self?.audioWho { self?.log("audio from \(who) — holding speech") }
            self?.playback.audioChanged(busy: busy)
        }
        playback.log = { [weak self] in self?.log($0) }
        playback.onChange = { [weak self] in self?.render($0) }
        playback.onStart = { [weak self] in self?.show($0) }
        playback.onAsked = { [weak self] in
            if self?.isMinimized == false { self?.panel?.comeForward() }
        }
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
            if panel.isVisible { panel.comeForward() }   // the HUD stays lit, above the dimming
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

    /// Start listening for other apps making sound. Silently a no-op before macOS 14.2;
    /// if the tap can't be made (no permission) there is no audio hold, logged once.
    func watchAudio() {
        guard audioWatch == nil, #available(macOS 14.2, *) else { return }
        audioWatch = AudioWatch(meter: TapMeter(), onUnavailable: { [weak self] in
            self?.log("audio check unavailable (no system-audio permission?) — not waiting for audio")
        }) { [weak self] playing, who in
            if playing { self?.audioWho = who ?? "an unknown process" }
            self?.audioHold.playingChanged(playing)
        }
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
        if !isMinimized { panel.comeForward() }
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
        panel.comeForward()
        log("hud shown")
        if !playback.state.isActive { scheduleAutoClose(after: idleHideDelay) }
        onVisibilityChange()
    }

    /// Stop also leaves the panel off-screen, so "is it up right now" is the honest
    /// question to toggle on — not whether the user pressed Hide.
    var isPanelVisible: Bool { panel?.isVisible == true }

    /// Asked for from the menu bar or the hotkey: a HUD that's up belongs in front of
    /// everything, wherever a click sent it. One put away with Hide stays away.
    func bringForward() {
        guard Self.shouldComeForward(minimized: isMinimized, visible: isPanelVisible,
                                     active: playback.state.isActive) else { return }
        panel?.comeForward()
        lastInteraction = Date()   // looking at it: the idle close counts from here
        onVisibilityChange()
    }

    enum Summon { case nothing, reopen, forward }

    /// What a click on the menu bar icon does: always shows the HUD if there is one,
    /// whether it hid itself after a reading, was put away with Hide, or sits behind a window.
    static func summonAction(built: Bool, minimized: Bool, visible: Bool) -> Summon {
        guard built else { return .nothing }
        return minimized || !visible ? .reopen : .forward
    }

    /// The menu bar icon was clicked. Shown this way it stays up until Hide or the end
    /// of the next reading: no idle close 15 s later.
    func summon() {
        switch Self.summonAction(built: panel != nil, minimized: isMinimized, visible: isPanelVisible) {
        case .nothing: return
        case .reopen:
            isMinimized = false
            closeTimer?.invalidate()
            panel.comeForward()
            log("hud shown from the menu bar")
        case .forward:
            panel.comeForward()
        }
        lastInteraction = Date()
        onVisibilityChange()
    }

    /// Up, or supposed to be: on screen, or with something being read or waiting.
    static func shouldComeForward(minimized: Bool, visible: Bool, active: Bool) -> Bool {
        !minimized && (visible || active)
    }

    /// A HUD sitting behind a window comes forward; only one already in front gets hidden.
    @objc func toggleMinimized() {
        if panel?.isBehind == true, isPanelVisible { bringForward(); return }
        isPanelVisible ? minimize() : restore()
    }

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
        // Not .stationary: that keeps Mission Control from picking the HUD's thumbnail.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .managed]
        panel.minSize = NSSize(width: w, height: 260)   // narrower than this clips the button row
        panel.standardWindowButton(.zoomButton)?.isHidden = true   // zoom is refused; don't advertise it
        panel.delegate = self
        panel.watchClicks()
        panel.onWentBehind = { [weak self] in self?.log("hud behind a clicked window") }

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
