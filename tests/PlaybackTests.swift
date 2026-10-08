// Playback tests. Registered in tests/main.swift.
// Drive Playback through its interface against a recording fake voice.
import Foundation

/// Records what Playback asked of the voice, and plays the engine's part on demand.
final class FakeVoice: Voice {
    enum Call: Equatable {
        case speak(String, from: Int, rate: Float)
        case pause(immediately: Bool)
        case resume
        case stop
    }
    weak var playback: Playback?
    private(set) var calls: [Call] = []
    private(set) var lastUtterance = 0

    func speak(_ text: String, from offset: Int, rate: Float, utterance: Int) {
        calls.append(.speak(text, from: offset, rate: rate))
        lastUtterance = utterance
    }
    func pause(immediately: Bool) { calls.append(.pause(immediately: immediately)) }
    func resume() { calls.append(.resume) }
    func stop() { calls.append(.stop) }

    /// Take the calls made so far, so each step asserts only on what it caused.
    func take() -> [Call] { defer { calls = [] }; return calls }
    /// The engine finishing an utterance: the latest one unless told otherwise.
    func finish(_ utterance: Int? = nil) { playback?.voiceFinished(utterance: utterance ?? lastUtterance) }
    func word(at location: Int) {
        playback?.voiceSpoke(NSRange(location: location, length: 1), utterance: lastUtterance)
    }
}

/// Records what Playback asked of the mic, and says things into it on demand.
final class FakeEar: Ear {
    /// `listen`: opened for a reply. `attend`: opened over the voice, for commands.
    enum Call: Equatable { case listen(Int), attend(Int), stop }
    weak var listener: Playback?
    private(set) var calls: [Call] = []
    private(set) var window = 0   // the last window opened, still the one a stale report names
    /// A real mic takes a moment to open; tests that care set this false and call open().
    var opensAtOnce = true
    /// How long this mic says opening may take, its own tries included (Ear.opensWithin).
    var patience: (plain: TimeInterval, overSpeech: TimeInterval) = (7, 11)
    func opensWithin(overSpeech: Bool) -> TimeInterval { overSpeech ? patience.overSpeech : patience.plain }

    func listen(window id: Int, overSpeech: Bool) {
        calls.append(overSpeech ? .attend(id) : .listen(id))
        window = id
        if opensAtOnce { open() }
    }
    func open() { listener?.earOpened(window: window) }
    func stop() { calls.append(.stop) }

    func take() -> [Call] { defer { calls = [] }; return calls }
    /// The transcriber reporting everything heard so far, for the latest window unless told otherwise.
    func hear(_ text: String, window id: Int? = nil) { listener?.earHeard(text, window: id ?? window) }
    func fail(_ why: String) { listener?.earFailed(why, window: window) }
}

/// A Playback on a fake voice and a fake mic, with retirements and events captured.
final class Rig {
    /// Work Playback asked to have run after a while. Tests fire it by hand.
    final class Pending {
        let seconds: TimeInterval
        let work: () -> Void
        var cancelled = false, fired = false
        init(_ seconds: TimeInterval, _ work: @escaping () -> Void) { self.seconds = seconds; self.work = work }
    }

    let voice = FakeVoice()
    let ear = FakeEar()
    var timers: [Pending] = []
    /// The timer running now, if one is.
    var armed: Pending? { timers.last { !$0.cancelled && !$0.fired } }
    /// Let the running timer run out.
    func fire() { guard let t = armed else { return }; t.fired = true; t.work() }
    /// …or the one running for `seconds`, when more than one is.
    func fire(_ seconds: TimeInterval) {
        guard let t = timers.last(where: { !$0.cancelled && !$0.fired && $0.seconds == seconds }) else { return }
        t.fired = true
        t.work()
    }
    var commands: [SpokenCommand] = []     // commands Playback said it heard
    var listened: [String] = []            // texts of the turns the mic opened for
    var replied: [Reply.Outcome] = []
    var sent: [(text: String, to: String)] = []   // what `deliver` was handed
    var delivery = Reply.Outcome.sent      // and what it answers
    var earFailures: [String] = []
    private(set) var playback: Playback!
    var retired: [String] = []   // texts, in retirement order
    var ranDry = 0
    var shown: [String] = []     // texts handed to the HUD via onStart
    var deferred: [() -> Void] = []   // `later` work, when a test wants to hold it
    var holdLater = false
    var stopped = 0
    var logs: [String] = []

    init() {
        let p = Playback(voice: voice, rateIndex: 1, retire: { [unowned self] in self.retired.append($0.text) },
                         later: { [unowned self] work in
                             if self.holdLater { self.deferred.append(work) } else { work() } },
                         ear: ear,
                         timer: { [unowned self] seconds, work in
                             let t = Pending(seconds, work)
                             self.timers.append(t)
                             return { t.cancelled = true } })
        ear.listener = p
        p.onListen = { [unowned self] in self.listened.append($0.text) }
        p.onReplied = { [unowned self] in self.replied.append($0) }
        p.onEarFailed = { [unowned self] in self.earFailures.append($0) }
        p.onCommand = { [unowned self] in self.commands.append($0) }
        p.deliver = { [unowned self] text, item in self.sent.append((text, item.source)); return self.delivery }
        p.onStart = { [unowned self] in self.shown.append($0.text) }
        p.onRanDry = { [unowned self] in self.ranDry += 1 }
        p.onStopped = { [unowned self] in self.stopped += 1 }
        p.log = { [unowned self] in self.logs.append($0) }
        voice.playback = p
        playback = p
    }
}

private let r1: Float = Playback.rateSteps[1], r2: Float = Playback.rateSteps[2]

/// A Claude Code turn (spool-backed) or an ad-hoc hotkey read (no file).
private func turn(_ text: String, key: String) -> SpeechItem {
    SpeechItem(text: text, source: key, key: key, created: Date(), file: "/tmp/\(text).taken")
}
private func read(_ text: String) -> SpeechItem {
    SpeechItem(text: text, source: "Selection", key: UUID().uuidString, created: Date())
}
/// A finished Claude Code turn from an iTerm2 pane: the kind you can answer, and the phone shows.
private func answerable(_ text: String, key: String) -> SpeechItem {
    SpeechItem(text: text, source: key, key: key, created: Date(), file: "/tmp/\(text).taken",
               origin: Origin(term: "iTerm.app", session: "1A2B3C4D-0000-4000-8000-00000000ABCD"), answerable: true)
}

let playbackSuite = Suite("Playback") { t in
    // -- queue -------------------------------------------------------------

    do {  // first item starts; the rest wait, newest per session wins and keeps its place
        let r = Rig(), p = r.playback!
        t.expect(p.enqueue(turn("a1", key: "A")), "first item starts straight away")
        t.expectEqual(r.voice.take(), [.speak("a1", from: 0, rate: r1)], "speaks the first item from the top")
        t.expect(!p.enqueue(turn("b1", key: "B")), "second item waits")
        t.expect(!p.enqueue(turn("c1", key: "C")), "third item waits")
        t.expect(!p.enqueue(turn("b2", key: "B")), "newer turn for B waits")
        t.expectEqual(p.queue.map(\.text), ["b2", "c1"], "b2 replaced b1 in b1's place")
        t.expectEqual(r.retired, ["b1"], "the replaced turn is retired")
        t.expectEqual(r.voice.take(), [], "queueing never touches the voice")
        t.expectEqual(p.state.queued, ["B", "C"], "state previews the queue")
        t.expect(p.state.canSkip, "skip is offered with something waiting")
    }

    do {  // a new turn for the session that's speaking queues behind it
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a1", key: "A"))
        p.enqueue(turn("a2", key: "A"))
        t.expectEqual(p.current?.text, "a1", "current item is not replaced by its own session")
        t.expectEqual(p.queue.map(\.text), ["a2"], "the newer turn waits")
    }

    do {  // finishing retires and advances; running dry says so
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a", key: "A")); p.enqueue(turn("b", key: "B"))
        _ = r.voice.take()
        r.voice.finish()
        t.expectEqual(r.retired, ["a"], "finished item retired")
        t.expectEqual(r.voice.take(), [.speak("b", from: 0, rate: r1)], "next item starts")
        r.voice.finish()
        t.expectEqual(r.retired, ["a", "b"], "last item retired")
        t.expect(p.current == nil, "nothing current once dry")
        t.expectEqual(r.ranDry, 1, "ran-dry reported once")
        t.expectEqual(p.state.status, "Done", "state says done")
        t.expect(!p.state.isActive, "idle once dry, so the HUD may auto-hide")
    }

    // -- playNow -----------------------------------------------------------

    do {  // an interrupted spool turn goes back to the head of the line
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a", key: "A")); p.enqueue(turn("b", key: "B"))
        _ = r.voice.take()
        p.playNow(read("sel"))
        t.expectEqual(r.voice.take(), [.stop, .speak("sel", from: 0, rate: r1)], "stops the turn, speaks the read")
        t.expectEqual(p.queue.map(\.text), ["a", "b"], "interrupted turn requeued at the head")
        t.expectEqual(r.retired, [], "requeued turn keeps its file")
        t.expect(r.logs.contains("preempted A — requeued"), "logs the requeue")
    }

    do {  // …unless a newer turn from its session is already waiting
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a1", key: "A")); p.enqueue(turn("a2", key: "A"))
        p.playNow(read("sel"))
        t.expectEqual(p.queue.map(\.text), ["a2"], "stale turn not requeued")
        t.expectEqual(r.retired, ["a1"], "stale turn retired")
    }

    do {  // an ad-hoc read that's interrupted is just gone
        let r = Rig(), p = r.playback!
        p.playNow(read("one"))
        p.playNow(read("two"))
        t.expect(p.queue.isEmpty, "ad-hoc read not requeued")
        t.expectEqual(r.retired, ["one"], "ad-hoc read retired")
        t.expectEqual(p.current?.text, "two", "the new read is current")
    }

    // -- skip / stop never double-advance ------------------------------------

    do {
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a", key: "A")); p.enqueue(turn("b", key: "B")); p.enqueue(turn("c", key: "C"))
        let first = r.voice.lastUtterance
        _ = r.voice.take()
        p.skip()
        t.expectEqual(r.voice.take(), [.stop, .speak("b", from: 0, rate: r1)], "skip stops a and speaks b")
        t.expectEqual(r.retired, ["a"], "skipped item retired")
        r.voice.finish(first)   // the stopped synth's late didFinish
        t.expectEqual(p.current?.text, "b", "late finish from the skipped utterance ignored")
        t.expectEqual(p.queue.map(\.text), ["c"], "queue not advanced twice")
        t.expectEqual(r.retired, ["a"], "nothing else retired")
        t.expectEqual(r.voice.take(), [], "voice untouched by the stale finish")
    }

    do {
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a", key: "A")); p.enqueue(turn("b", key: "B"))
        _ = r.voice.take()
        p.stop()
        t.expectEqual(r.voice.take(), [.stop], "stop silences the voice")
        t.expectEqual(r.retired, ["a", "b"], "current and queue retired")
        t.expectEqual(r.stopped, 1, "stop reported")
        r.voice.finish()   // stopSpeaking(.immediate) delivers didFinish
        t.expect(p.current == nil && p.queue.isEmpty, "late finish after stop starts nothing")
        t.expectEqual(r.voice.take(), [], "nothing spoken after stop")
        t.expectEqual(r.retired, ["a", "b"], "nothing retired twice")
        t.expectEqual(r.ranDry, 0, "a stop isn't a run-dry")
    }

    do {  // replay/speed restarts drop the old utterance; its finish is stale
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a", key: "A")); p.enqueue(turn("b", key: "B"))
        let first = r.voice.lastUtterance
        p.replay()
        r.voice.finish(first)
        t.expectEqual(p.current?.text, "a", "finish of the replaced utterance ignored")
        t.expectEqual(r.retired, [], "nothing retired by a stale finish")
    }

    // -- mic hold ----------------------------------------------------------

    do {  // mid-speech: pause on the spot, resume on release
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a", key: "A"))
        _ = r.voice.take()
        p.micChanged(busy: true)
        t.expectEqual(r.voice.take(), [.pause(immediately: true)], "mic pauses immediately")
        t.expectEqual(p.state.status, "🎙 Mic in use — paused", "status says mic paused")
        p.micChanged(busy: false)
        t.expectEqual(r.voice.take(), [.resume], "release resumes")
        t.expectEqual(p.state.status, "🔊 Speaking…  1×", "status back to speaking")
    }

    do {  // nothing new starts while the mic is busy
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a", key: "A"))
        p.micChanged(busy: true)
        r.voice.finish()
        _ = r.voice.take()
        p.enqueue(turn("b", key: "B"))
        t.expectEqual(r.voice.take(), [], "b doesn't start while the mic is busy")
        t.expect(p.state.isActive, "a held item keeps the HUD from auto-hiding")
        p.micChanged(busy: false)
        t.expectEqual(r.voice.take(), [.speak("b", from: 0, rate: r1)], "b starts on release")
    }

    do {  // your pause wins over the mic's release
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a", key: "A"))
        p.micChanged(busy: true)
        p.togglePause()
        t.expectEqual(p.state.pauseTitle, "▶ Resume", "button offers resume")
        _ = r.voice.take()
        p.micChanged(busy: false)
        t.expectEqual(r.voice.take(), [], "release doesn't resume your pause")
        t.expectEqual(p.state.status, "⏸ Paused", "still paused")
        p.togglePause()
        t.expectEqual(r.voice.take(), [.resume], "your resume resumes")
    }

    do {  // user pause is at a word boundary, not mid-word
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a", key: "A"))
        _ = r.voice.take()
        p.togglePause()
        t.expectEqual(r.voice.take(), [.pause(immediately: false)], "user pause waits for the word")
    }

    // -- defect 1: speed while paused stays paused --------------------------

    do {
        let r = Rig(), p = r.playback!
        p.enqueue(turn("hello world", key: "A"))
        r.voice.word(at: 6)
        p.togglePause()
        _ = r.voice.take()
        p.cycleSpeed()
        t.expectEqual(r.voice.take(), [.stop], "speed while paused drops the utterance but says nothing")
        t.expectEqual(p.state.status, "⏸ Paused", "still paused after speed change")
        t.expectEqual(p.state.pauseTitle, "▶ Resume", "button still offers resume")
        t.expectEqual(p.state.speedTitle, "⏩ 1.25×", "new speed shown")
        p.togglePause()
        t.expectEqual(r.voice.take(), [.speak("hello world", from: 6, rate: r2)],
                      "resume continues from the current word at the new rate")
    }

    do {  // speed while speaking restarts from the current word straight away
        let r = Rig(), p = r.playback!
        p.enqueue(turn("hello world", key: "A"))
        r.voice.word(at: 6)
        _ = r.voice.take()
        p.cycleSpeed()
        t.expectEqual(r.voice.take(), [.stop, .speak("hello world", from: 6, rate: r2)], "restart at new rate")
    }

    do {  // speed / replay while you paused on top of a mic hold: release doesn't start it
        let r = Rig(), p = r.playback!
        p.enqueue(turn("hello world", key: "A"))
        r.voice.word(at: 6)
        p.micChanged(busy: true)
        p.togglePause()
        p.cycleSpeed()
        p.replay()
        _ = r.voice.take()
        p.micChanged(busy: false)
        t.expectEqual(r.voice.take(), [], "mic release doesn't auto-start after speed/replay")
        t.expectEqual(p.state.status, "⏸ Paused", "still paused")
        p.togglePause()
        t.expectEqual(r.voice.take(), [.speak("hello world", from: 0, rate: r2)], "resume replays from the top at the new rate")
    }

    // -- defect 2: after Stop the state is idle, not "Speaking" --------------

    do {
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a", key: "A"))
        p.togglePause()
        p.stop()
        t.expectEqual(p.state.status, "■ Stopped", "status says stopped")
        t.expectEqual(p.state.pauseTitle, "❚❚ Pause", "pause button reset")
        t.expect(!p.state.isActive, "idle, so a restored panel auto-hides")
        t.expect(!p.state.canSkip, "nothing to skip")
    }

    // -- defect 3: enqueue's answer is truthful under a mic hold ------------

    do {
        let r = Rig(), p = r.playback!
        p.micChanged(busy: true)
        t.expect(!p.enqueue(turn("a", key: "A")), "not reported as started while the mic holds it")
        t.expectEqual(p.current?.text, "a", "it's current, so the HUD can show it")
        t.expectEqual(r.shown, ["a"], "the HUD was told to show it")
        t.expectEqual(p.state.status, "🎙 Mic in use — waiting", "status says waiting")
        t.expectEqual(r.logs.last, "holding A — mic in use or paused", "and so does the log")
        t.expectEqual(r.voice.take(), [], "nothing spoken")
        p.micChanged(busy: false)
        t.expectEqual(r.voice.take(), [.speak("a", from: 0, rate: r1)], "spoken once the mic lets go")
    }

    do {  // skipping under a mic hold shows the next item instead of leaving the skipped one up
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a", key: "A")); p.enqueue(turn("b", key: "B"))
        p.micChanged(busy: true)
        _ = r.voice.take()
        p.skip()
        t.expectEqual(p.current?.text, "b", "next item is current (shown) while held")
        t.expectEqual(r.shown, ["a", "b"], "the HUD was told to show it")
        t.expectEqual(r.voice.take(), [.stop], "and nothing new is spoken")
    }

    // -- the hop between a finish and starting the next item ----------------

    do {  // a hotkey read landing in the hop must not requeue the turn that just finished
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a", key: "A"))
        r.holdLater = true
        r.voice.finish()
        t.expect(p.current == nil, "the finish is recorded straight away")
        t.expectEqual(r.retired, ["a"], "and its file released")
        p.playNow(read("sel"))
        t.expect(!p.queue.contains { $0.text == "a" }, "finished turn not requeued")
        r.deferred.forEach { $0() }
        t.expectEqual(p.current?.text, "sel", "the deferred advance doesn't clobber the read")
    }

    // -- defect 4: pause while an item waits on the mic ---------------------

    do {  // a queued item waiting on the mic
        let r = Rig(), p = r.playback!
        p.micChanged(busy: true)
        p.enqueue(turn("a", key: "A"))
        p.togglePause()
        t.expectEqual(p.state.pauseTitle, "▶ Resume", "pause while waiting is honoured")
        t.expectEqual(p.state.status, "⏸ Paused", "status says paused")
        p.micChanged(busy: false)
        t.expectEqual(r.voice.take(), [], "stays paused after the mic frees up")
        p.togglePause()
        t.expectEqual(r.voice.take(), [.speak("a", from: 0, rate: r1)], "resume starts it")
    }

    do {  // a hotkey read made current while the mic is busy
        let r = Rig(), p = r.playback!
        p.micChanged(busy: true)
        p.playNow(read("sel"))
        t.expectEqual(p.current?.text, "sel", "the read is current (shown) while it waits")
        p.togglePause()
        p.micChanged(busy: false)
        t.expectEqual(r.voice.take(), [], "stays paused after release")
        p.togglePause()
        t.expectEqual(r.voice.take(), [.speak("sel", from: 0, rate: r1)], "resume speaks it")
    }

    // -- defect 5: replay after the queue ran dry ---------------------------

    do {
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a", key: "A"))
        r.voice.finish()
        t.expectEqual(r.retired, ["a"], "a finished and retired")
        _ = r.voice.take()
        p.replay()
        t.expectEqual(p.current?.text, "a", "replay makes the last item current again")
        t.expect(p.current?.file == nil, "without the spool file it already released")
        t.expectEqual(r.voice.take(), [.speak("a", from: 0, rate: r1)], "replays from the top")
        t.expect(!p.enqueue(turn("b", key: "B")), "a turn arriving during the replay waits")
        t.expectEqual(r.voice.take(), [], "…without cutting the replay off")
        r.voice.finish()
        t.expectEqual(r.voice.take(), [.speak("b", from: 0, rate: r1)], "b starts after the replay")
        r.voice.finish()
        t.expectEqual(r.retired, ["a", "a", "b"], "each retired at its own finish (replay's is file-less)")
    }

    do {  // replay with nothing ever spoken does nothing
        let r = Rig(), p = r.playback!
        p.replay()
        t.expectEqual(r.voice.take(), [], "nothing to replay")
        t.expect(p.current == nil, "still idle")
    }

    // -- away ----------------------------------------------------------------
    //
    // Nobody is at the Mac, and the phone has the turns: `onPhone` is what the phone
    // said when it was handed each one (Phone.took).

    do {  // Away goes on mid-turn: the voice stops, and what the phone has is let go
        let r = Rig(), p = r.playback!
        p.awayChanged(on: false)
        t.expect(r.logs.isEmpty && r.ranDry == 0, "told it's off when it already is: nothing happens")
        p.enqueue(turn("a", key: "A"), onPhone: true); p.enqueue(turn("b", key: "B"), onPhone: true)
        t.expectEqual(r.logs, ["start A (1 chars)", "speaking A", "queued B — 1 waiting"], "what became of each arrival is in the log")
        _ = r.voice.take()
        p.awayChanged(on: true)
        t.expectEqual(r.voice.take(), [.stop], "away: the turn being read stops")
        t.expectEqual(r.retired, ["a", "b"], "it and what was waiting are let go, spool files and all: the phone has them")
        t.expect(p.current == nil && p.queue.isEmpty, "nothing is left to read")
        t.expect(!p.state.isActive, "idle, so the HUD may hide")
        t.expectEqual(p.state.status, "📱 Away: turns go to your phone", "and says why it's quiet")
        t.expect(r.logs.contains("away: A not read, the phone has it") && r.logs.contains("away: B not read, the phone has it"),
                 "the log says what became of each")
        r.voice.finish()   // the stopped synth's late didFinish
        t.expect(p.current == nil && r.retired == ["a", "b"], "the stopped voice's late finish changes nothing")

        t.expect(!p.enqueue(turn("c", key: "C"), onPhone: true), "a turn arriving while away is not read")
        t.expectEqual(r.voice.take(), [], "the voice says nothing")
        t.expectEqual(r.retired, ["a", "b", "c"], "it's let go at once: the phone has it")
        t.expectEqual(r.shown, ["a"], "and the HUD isn't brought up for it")
        t.expectEqual(r.logs.last, "away: C not read, the phone has it", "the log says so")
        p.awayChanged(on: true)
        t.expectEqual(r.retired, ["a", "b", "c"], "told it's on when it already is: nothing happens")

        p.awayChanged(on: false)
        t.expectEqual(r.voice.take(), [], "back: nothing that went to the phone is read after all")
        t.expect(p.current == nil && p.queue.isEmpty && !p.state.isActive, "there's nothing to read")
        t.expect(p.enqueue(turn("d", key: "D"), onPhone: true), "and the next turn to arrive is read as it always was")
        t.expectEqual(r.voice.take(), [.speak("d", from: 0, rate: r1)], "aloud")
    }

    do {  // …with Listen After Reading on, no reply mic opens for a turn Away cut off
        let r = Rig(), p = r.playback!
        p.listens = true
        p.enqueue(answerable("a", key: "A"), onPhone: true); p.enqueue(answerable("b", key: "B"), onPhone: true)
        p.awayChanged(on: true)
        r.voice.finish()
        t.expectEqual(r.ear.take(), [], "away: no mic opens")
        t.expect(r.listened.isEmpty && r.shown == ["a"], "nobody is asked for a reply, and the next turn isn't started")
        p.awayChanged(on: false)
        _ = r.voice.take()
        p.replay()
        t.expectEqual(r.voice.take(), [.speak("a", from: 0, rate: r1)], "back, Replay still brings the cut-off turn back if you ask for it")
    }

    do {  // your own pause outlasts Away, as it does a mic hold
        let r = Rig(), p = r.playback!
        p.enqueue(turn("note", key: "N"))
        p.togglePause()
        p.awayChanged(on: true)
        _ = r.voice.take()
        p.awayChanged(on: false)
        t.expectEqual(r.voice.take(), [], "back, what you'd paused stays paused")
        t.expectEqual(p.state.status, "⏸ Paused", "and says so")
        p.togglePause()
        t.expectEqual(r.voice.take(), [.speak("note", from: 0, rate: r1)], "Resume reads it, from the top")
    }

    do {  // a reply window open when Away goes on is shut, and nothing is sent
        let r = Rig(), p = r.playback!
        p.listens = true
        p.enqueue(answerable("a", key: "A"), onPhone: true); p.enqueue(answerable("b", key: "B"), onPhone: true)
        r.voice.finish()
        r.ear.hear("half a sen")
        t.expectEqual(r.ear.take(), [.listen(1)], "the reply window is open")
        _ = r.voice.take()
        p.awayChanged(on: true)
        t.expectEqual(r.ear.take(), [.stop], "away: the mic shuts")
        t.expect(r.armed == nil && r.sent.isEmpty && p.state.heard == nil, "what was half heard is never sent")
        t.expectEqual(r.voice.take(), [], "and the turn behind it isn't read")
        t.expectEqual(r.retired, ["a", "b"], "it's let go with the rest")
    }

    do {  // the mic open for commands shuts too, and stays shut
        let r = Rig(), p = r.playback!
        p.obeys = true
        p.enqueue(turn("a", key: "A"), onPhone: true)
        p.enqueue(turn("note", key: "N"))   // the phone couldn't show this one
        t.expectEqual(r.ear.take(), [.attend(1)], "the mic is open for commands")
        p.awayChanged(on: true)
        t.expectEqual(r.ear.take(), [.stop], "away: it shuts")
        t.expect(!p.state.listening, "and the HUD knows")
        t.expectEqual(p.current?.text, "note", "with something still waiting to be read")
        t.expect(!p.enqueue(turn("note2", key: "M")), "and more arriving")
        t.expectEqual(r.ear.take(), [], "it stays shut")
        p.awayChanged(on: false)
        t.expectEqual(r.ear.take(), [.attend(2)], "back: it opens again with the reading")
    }

    do {  // what the phone couldn't show isn't lost: it waits, and is read when you're back
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a", key: "A"), onPhone: true)
        p.enqueue(turn("note", key: "N"))
        p.enqueue(turn("b", key: "B"), onPhone: true)
        _ = r.voice.take()
        p.awayChanged(on: true)
        t.expectEqual(r.retired, ["a", "b"], "away lets go of what the phone has, and only that")
        t.expectEqual(p.current?.text, "note", "the one it couldn't show is up next")
        t.expectEqual(r.shown, ["a", "note"], "on the HUD")
        t.expectEqual(r.voice.take(), [.stop], "but not read")
        t.expectEqual(p.state.status, "📱 Away: this is read when you're back", "the HUD says what it's waiting for")
        t.expect(r.logs.contains("away: N waits to be read: the phone can't show it"), "and the log says why it was kept")

        t.expect(!p.enqueue(turn("note2", key: "M")), "another the phone can't show, arriving while away, isn't read either")
        t.expectEqual(p.queue.map(\.text), ["note2"], "it waits in line")
        t.expectEqual(r.retired, ["a", "b"], "with its spool file")
        t.expectEqual(r.logs.last, "away: M waits to be read: the phone can't show it", "the log doesn't say it went to the phone")
        t.expectEqual(r.voice.take(), [], "and still nothing is said")

        p.awayChanged(on: false)
        t.expectEqual(r.voice.take(), [.speak("note", from: 0, rate: r1)], "back: what waited is read")
        r.voice.finish()
        t.expectEqual(r.voice.take(), [.speak("note2", from: 0, rate: r1)], "all of it")
    }

    do {  // what the phone has is remembered per turn, and forgotten with the turn
        let r = Rig(), p = r.playback!
        p.enqueue(turn("x", key: "A"), onPhone: true)
        r.voice.finish()
        p.awayChanged(on: true)
        p.enqueue(turn("x", key: "N"))   // the same spool file name, used again, for something the phone can't show
        t.expect(r.retired == ["x"] && p.current?.key == "N", "a spool file that was once the phone's doesn't make the next one the phone's")
    }

    do {  // …and if it was the one being read, it starts again from the top
        let r = Rig(), p = r.playback!
        p.enqueue(turn("one two three", key: "N"))
        r.voice.word(at: 4)
        _ = r.voice.take()
        p.awayChanged(on: true)
        t.expectEqual(r.voice.take(), [.stop], "away: it stops")
        t.expect(r.retired.isEmpty && p.current?.text == "one two three", "and is kept: the phone hasn't got it")
        p.awayChanged(on: false)
        t.expectEqual(r.voice.take(), [.speak("one two three", from: 0, rate: r1)], "back: read from the top, not from the middle of a sentence")
    }

    do {  // reads asked for by hand
        let r = Rig(), p = r.playback!
        p.playNow(read("sel"))
        _ = r.voice.take()
        p.awayChanged(on: true)
        t.expectEqual(r.voice.take(), [.stop], "away: a hotkey read stops like anything else")
        t.expect(r.retired == ["sel"] && p.current == nil, "and is let go: nothing on disk backs it, and whoever asked has left")

        p.playNow(read("later sel"))
        t.expectEqual(p.current?.text, "later sel", "a hotkey read asked for while away is shown")
        t.expectEqual(r.voice.take(), [], "but nothing is read while away")
        t.expectEqual(p.state.status, "📱 Away: this is read when you're back", "and the HUD says why")
        p.awayChanged(on: false)
        t.expectEqual(r.voice.take(), [.speak("later sel", from: 0, rate: r1)], "back: it's read")
    }

    do {  // a turn put off with "later" is on the phone too
        let r = Rig(), p = r.playback!
        p.obeys = true
        p.enqueue(turn("a", key: "A"), onPhone: true)
        r.ear.hear("later"); r.fire(Playback.commandPause)
        t.expectEqual(p.state.putOff, 1, "put off, with nothing else waiting")
        p.awayChanged(on: true)
        t.expect(r.retired == ["a"] && p.state.putOff == 0, "away lets go of it with the rest")
    }

    do {  // the agent's forward: what the phone kept is what Away lets go of
        let suite = "speakhud-away-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let phone = Phone(config: PhoneConfig(token: String(repeating: "k", count: 32)), defaults: defaults)
        phone.transport = { _, done in done(nil) }
        let r = Rig(), p = r.playback!
        phone.onAwayChange = { p.awayChanged(on: $0) }
        func arrives(_ item: SpeechItem) -> Bool { p.enqueue(item, onPhone: phone.took(item)) }   // Agent.drainSpool

        t.expect(arrives(answerable("a", key: "A")), "at the Mac, a turn is read")
        phone.setAway(true)
        t.expectEqual(r.retired, ["a"], "the phone's switch reaches the reading: the turn stops and is let go")
        t.expectEqual(phone.desk.turn("A")?.text, "a", "the phone has it")
        t.expect(!arrives(answerable("b", key: "B")), "away, a finished turn is not read")
        t.expect(!arrives(turn("which one?", key: "B" + PhoneDesk.questionSuffix)), "nor a question")
        t.expectEqual(r.retired, ["a", "b", "which one?"], "both are let go")
        t.expect(phone.desk.turn("B")?.text == "b" && phone.desk.turn("B")?.question == "which one?", "to the phone, which has them")
        t.expect(!arrives(turn("note", key: "N")), "something with no terminal to answer in is not read either")
        t.expect(phone.desk.turn("N") == nil && r.retired == ["a", "b", "which one?"] && p.current?.text == "note",
                 "but the phone didn't keep it, so the Mac does")
        t.expectEqual(r.voice.take(), [.speak("a", from: 0, rate: r1), .stop], "nothing has been read since Away went on")
        phone.setAway(false)
        t.expectEqual(r.voice.take(), [.speak("note", from: 0, rate: r1)], "back: only what the phone never had is read")
    }
}
