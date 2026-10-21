// Wait While Audio Plays tests. Registered in tests/main.swift.
// AudioHold's two debounces driven by hand, Playback waiting and pausing, and
// AudioWatch's decision with CoreAudio and the tap stood in.
import Foundation

private let r1: Float = Playback.rateSteps[1]

private func turn(_ text: String) -> SpeechItem {
    SpeechItem(text: text, source: "A", key: "A", created: Date(), file: "/tmp/\(text).taken")
}

/// An AudioHold on a real Playback (fake voice), with both delays held by hand.
private final class AudioRig {
    let rig = Rig()
    var pending: [(delay: TimeInterval, run: () -> Void)] = []
    var delivered: [Bool] = []
    private(set) var hold: AudioHold!
    init(enabled: Bool = true) {
        hold = AudioHold(enabled: enabled, deliver: { [unowned self] busy in
            self.delivered.append(busy)
            self.rig.playback.audioChanged(busy: busy)
        }, later: { [unowned self] delay, work in
            var live = true
            self.pending.append((delay, { if live { work() } }))
            return { live = false }
        })
    }
    /// Let the scheduled delays elapse.
    func elapse() { let p = pending; pending = []; p.forEach { $0.run() } }
}

private final class FakeMeter: AudioMeter {
    var peak: Float? = 0
    var canStart = true
    var started: [[AudioSource]] = []
    var tries = 0   // every start asked for, made or not
    var stops = 0
    func start(_ s: [AudioSource]) -> Bool { tries += 1; if canStart { started.append(s) }; return canStart }
    func stop() { stops += 1 }
    func takePeak() -> Float? { peak }
}

let audioSuite = Suite("Audio") { t in
    // -- AudioHold ---------------------------------------------------------

    do {  // sound has to last before it holds; silence has to last before it lets go
        let a = AudioRig()
        a.hold.playingChanged(true)
        t.expectEqual(a.delivered, [], "sound alone doesn't hold yet")
        t.expectEqual(a.pending.map(\.delay), [AudioHold.holdDelay], "the hold waits holdDelay")
        a.elapse()
        t.expectEqual(a.delivered, [true], "sound that lasts holds")
        a.hold.playingChanged(false)
        t.expectEqual(a.delivered, [true], "silence doesn't release yet")
        t.expectEqual(a.pending.map(\.delay), [AudioHold.releaseDelay], "the release waits releaseDelay")
        a.elapse()
        t.expectEqual(a.delivered, [true, false], "silence that lasts releases")
    }
    do {  // a beep never holds
        let a = AudioRig()
        a.hold.playingChanged(true)
        a.hold.playingChanged(false)
        a.elapse()
        t.expectEqual(a.delivered, [], "sound that stops inside holdDelay never held")
    }
    do {  // a gap between songs never releases
        let a = AudioRig()
        a.hold.playingChanged(true); a.elapse()
        a.hold.playingChanged(false)
        a.hold.playingChanged(true)
        a.elapse()
        t.expectEqual(a.delivered, [true], "sound back inside releaseDelay keeps the hold, no flap")
    }
    do {  // setting off releases at once; on while playing holds after the delay
        let a = AudioRig()
        a.hold.playingChanged(true); a.elapse()
        a.hold.setEnabled(false)
        t.expectEqual(a.delivered, [true, false], "turning it off releases at once")
        a.hold.playingChanged(false); a.hold.playingChanged(true); a.elapse()
        t.expectEqual(a.delivered, [true, false], "off: sound doesn't hold")
        a.hold.setEnabled(true)
        a.elapse()
        t.expectEqual(a.delivered, [true, false, true], "turned on during sound: holds")
    }
    do {
        let d = UserDefaults(suiteName: "speakhud.audiotest.\(UUID().uuidString)")!
        t.expect(AudioHold.storedEnabled(in: d), "on by default")
        AudioHold.store(false, in: d)
        t.expect(!AudioHold.storedEnabled(in: d), "off is remembered")
        t.expectEqual(AudioHold.prefKey, "waitWhileAudioPlays", "pref key")
    }

    // -- Playback ----------------------------------------------------------

    do {  // mid-speech: pause, resume
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a"))
        _ = r.voice.take()
        p.audioChanged(busy: true)
        t.expectEqual(r.voice.take(), [.pause(immediately: false)], "audio pauses mid-sentence")
        t.expectEqual(p.state.status, "🔈 Audio playing — paused", "status says audio paused")
        p.audioChanged(busy: false)
        t.expectEqual(r.voice.take(), [.resume], "silence resumes")
        t.expectEqual(p.state.status, "🔊 Speaking…  1×", "status back to speaking")
    }
    do {  // waits to start, queue order unchanged
        let r = Rig(), p = r.playback!
        p.audioChanged(busy: true)
        p.enqueue(turn("a"))
        p.enqueue(SpeechItem(text: "b", source: "B", key: "B", created: Date(), file: "/tmp/b.taken"))
        t.expectEqual(r.voice.take(), [], "nothing starts while audio plays")
        t.expectEqual(p.state.status, "🔈 Audio playing — waiting", "status says waiting")
        p.audioChanged(busy: false)
        t.expectEqual(r.voice.take(), [.speak("a", from: 0, rate: r1)], "a starts first on silence")
    }
    do {  // combines with the mic, the user's pause
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a")); _ = r.voice.take()
        p.audioChanged(busy: true); _ = r.voice.take()
        p.micChanged(busy: true)
        p.audioChanged(busy: false)
        t.expectEqual(r.voice.take(), [], "audio ending doesn't resume while the mic holds")
        t.expectEqual(p.state.status, "🎙 Mic in use — paused", "the mic's status shows")
        p.micChanged(busy: false)
        t.expectEqual(r.voice.take(), [.resume], "mic release resumes")
        p.audioChanged(busy: true); _ = r.voice.take()
        p.togglePause(); _ = r.voice.take()
        p.audioChanged(busy: false)
        t.expectEqual(r.voice.take(), [], "audio ending doesn't resume your pause")
    }
    do {  // audio never closes a reply window
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a")); _ = r.voice.take()
        p.audioChanged(busy: true)
        t.expect(p.state.isActive, "still active")
        p.audioChanged(busy: false)
        t.expectEqual(r.voice.take().filter { $0 == .stop }.count, 0, "no stop from audio")
    }

    // -- the decision, with CoreAudio and the tap stood in ----------------

    guard #available(macOS 14.0, *) else { return }
    let song = AudioSource(id: 7, name: "Music")
    t.expect(AudioWatch.decide(others: [song], peak: 0.1), "output running and loud: playing")
    t.expect(!AudioWatch.decide(others: [song], peak: 0.001), "output running but silent (paused player): not playing")
    t.expect(!AudioWatch.decide(others: [song], peak: nil), "nothing heard (no permission): not playing")
    t.expect(!AudioWatch.decide(others: [], peak: 0.5), "no other output: not playing, whatever the level")

    var running: [AudioSource]? = []
    let meter = FakeMeter()
    var seen: [String] = []
    var unavailable = 0
    let watch = AudioWatch(outputs: { running }, meter: meter, every: 3600,
                           onUnavailable: { unavailable += 1 }) { playing, who in
        seen.append(playing ? "playing \(who ?? "?")" : "quiet")
    }
    watch.look()
    t.expectEqual(meter.started.count, 0, "quiet Mac: no tap made")
    running = [song]; meter.peak = 0
    watch.look()
    t.expectEqual(meter.started, [[song]], "output running: tap made on that process")
    t.expectEqual(seen, [], "paused player: silence, no report")
    meter.peak = 0.05
    watch.look()
    t.expectEqual(seen, ["playing Music"], "sound is reported with the app's name")
    watch.look()
    t.expectEqual(meter.started.count, 1, "same process: tap kept")
    running = nil
    watch.look()
    t.expectEqual(seen, ["playing Music"], "couldn't tell: stands")
    running = []
    let stopsBefore = meter.stops
    watch.look()
    t.expectEqual(seen, ["playing Music", "quiet"], "output gone: quiet")
    t.expectEqual(meter.stops, stopsBefore + 1, "tap torn down when nothing has output")

    let denied = FakeMeter(); denied.canStart = false
    var deniedSeen: [Bool] = []
    var warned = 0
    let w2 = AudioWatch(outputs: { [song] }, meter: denied, every: 3600, onUnavailable: { warned += 1 }) { p, _ in deniedSeen.append(p) }
    w2.look(); w2.look()
    t.expectEqual(deniedSeen, [], "tap can't be made: never holds on the flag alone")
    t.expectEqual(warned, 1, "and says so once")
    t.expectEqual(denied.tries, 1, "a tap refused for these apps isn't asked for again on every look (4 a second)")

    // Refused, it's tried again only once something changes: another app, or quiet first.
    let refusing = FakeMeter(); refusing.canStart = false
    var outputs: [AudioSource] = [song]
    let w3 = AudioWatch(outputs: { outputs }, meter: refusing, every: 3600) { _, _ in }
    w3.look(); w3.look()
    t.expectEqual(refusing.tries, 1, "the same apps: not tried again")
    outputs = [song, AudioSource(id: 99, name: "Safari")]
    w3.look()
    t.expectEqual(refusing.tries, 2, "another app starts making sound: tried again")
    outputs = []; w3.look()
    outputs = [song]; refusing.canStart = true; w3.look()
    t.expectEqual(refusing.started, [[song]], "after quiet, the same app is tried again (permission may have come since)")
    withExtendedLifetime((watch, w2, w3)) {}
}
