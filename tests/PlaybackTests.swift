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

/// A Playback on a fake voice, with retirements and events captured.
final class Rig {
    let voice = FakeVoice()
    private(set) var playback: Playback!
    var retired: [String] = []   // texts, in retirement order
    var ranDry = 0
    var stopped = 0
    var logs: [String] = []

    init() {
        let p = Playback(voice: voice, rateIndex: 1, retire: { [unowned self] in self.retired.append($0.text) })
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
        t.expectEqual(p.queue.count, 1, "it's waiting in the queue")
        t.expectEqual(p.state.status, "🎙 Mic in use — waiting", "status says waiting")
        t.expectEqual(r.voice.take(), [], "nothing spoken")
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
}
