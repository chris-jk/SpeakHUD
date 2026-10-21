import Foundation

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
    private var audioBusy = false   // another app is making sound: wait, don't talk over it
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

    /// Another app started (or stopped) making sound. Like the mic: mid-speech this pauses
    /// on the spot and resumes on release, nothing new starts meanwhile, and the queue
    /// keeps its order. Unlike the mic it never closes a reply window. Debouncing is
    /// AudioHold's job.
    func audioChanged(busy: Bool) {
        guard busy != audioBusy else { return }
        audioBusy = busy
        log(busy ? "audio playing — holding speech" : "audio stopped")
        proceed()
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
            if window?.phase == .sending {   // you'd finished saying it: it goes now, not lost
                cancelTimer?()
                sendReply(movingOn: false)
            } else {
                closeWindow("away")
            }
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
        // Not under your pause: caught on its last word, the voice ran on to the end of
        // the turn, and a mic opening then is the opposite of the quiet you asked for.
        // Not while another app is making sound: the mic would hear that as your answer.
        // Not when its session has more to say already: that turn gets the window.
        listens && ear != nil && item.answerable && Reply.canReach(item.origin) && !micBusy && !userPaused
            && !audioBusy && !queue.contains { $0.key == item.key }
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

    private func sendReply(movingOn: Bool = true) {
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
        if movingOn { moveOn() }
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
    private var canSound: Bool { !userPaused && !micBusy && !audioBusy && !away }

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
        } else if audioBusy {
            s.status = sound == .paused ? "🔈 Audio playing — paused" : "🔈 Audio playing — waiting"
        } else {
            s.status = "🔊 Speaking…  \(Self.rateLabels[rateIndex])"
                + (attending != nil ? "   🎙 again · later · skip · pause" : "")
        }
        s.listening = attending != nil
        return s
    }
}
