// Ear tests. Registered in tests/main.swift.
//
// The real MicEar on this Mac's real transcriber, with a recording where the mic would
// be: `say` writes the words to a file (no sound is made), MicEar hears the file, and a
// real Playback's reply window, on its real timers, does what was said. Skipped where
// there's no on-device transcriber (before macOS 26).
import Foundation
import Speech

private let fm = FileManager.default

/// A recording of `phrase` in the system voice, written without playing it.
private func recording(of phrase: String, in dir: String, _ name: String) -> String? {
    let path = dir + "/" + name + ".aiff"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-o", path, phrase]
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    return p.terminationStatus == 0 && fm.fileExists(atPath: path) ? path : nil
}

/// Keep the main thread's queue moving (the ear reports there) until `done` or `seconds` pass.
private func spin(_ seconds: TimeInterval, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        usleep(5_000)
    }
}

let earSuite = Suite("Ear") { t in
    guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else {
        t.expect(true, "no on-device transcriber on this Mac: nothing to try")
        return
    }
    let dir = fm.temporaryDirectory.appendingPathComponent("speakhud-ear-\(UUID().uuidString)").path
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }

    /// A turn is read, then `phrase` is "said". Returns what was sent to the terminal,
    /// what the voice was asked to do after the turn ended, and anything that went wrong.
    @available(macOS 26.0, *)
    func say(_ phrase: String, _ name: String) -> (sent: [String], voice: [FakeVoice.Call], failure: String?, logs: [String]) {
        guard let file = recording(of: phrase, in: dir, name) else { return ([], [], "say could not write a recording", []) }
        let ear = MicEar(source: .recording(file))
        let voice = FakeVoice()
        let p = Playback(voice: voice, retire: { _ in }, later: { $0() }, ear: ear)
        voice.playback = p
        ear.listener = p
        var sent: [String] = [], failure: String?, logs: [String] = []
        p.deliver = { text, _ in sent.append(text); return .sent }
        p.onEarFailed = { failure = $0 }
        p.log = { logs.append($0) }
        p.listens = true
        p.enqueue(SpeechItem(text: "the turn", source: "Proj", key: "s1", created: Date(),
                             origin: Origin(term: "iTerm.app", session: "1A2B3C4D-0000-4000-8000-00000000ABCD"),
                             answerable: true))
        voice.finish()
        _ = voice.take()
        spin(40) { !sent.isEmpty || failure != nil || !voice.calls.isEmpty }
        let calls = voice.take()
        p.stop()
        spin(0.2) { false }   // let the mic's own shutdown land
        return (sent, calls, failure, logs)
    }

    let reply = say("Yes, go ahead and commit that.", "reply")
    t.expect(reply.failure == nil, "the transcriber opened (\(reply.failure ?? "no failure"))")
    t.expectEqual(reply.sent.map(SpokenCommand.words), ["yes go ahead and commit that"],
                  "what was said, once you'd stopped, is what's sent")
    t.expect(reply.voice.isEmpty, "and nothing is read meanwhile")
    t.expect(reply.logs.contains { $0.range(of: #"^mic shut after [1-9]\d* buffers$"#, options: .regularExpression) != nil },
             "the log says how much sound arrived (\(reply.logs.last ?? ""))")

    let again = say("Say that again.", "again")
    t.expect(again.failure == nil, "…and opened a second time (\(again.failure ?? "no failure"))")
    t.expect(again.sent.isEmpty, "a command isn't sent to Claude")
    t.expectEqual(again.voice, [.speak("the turn", from: 0, rate: Playback.rateSteps[1])], "it's done: the turn is read again")
}
