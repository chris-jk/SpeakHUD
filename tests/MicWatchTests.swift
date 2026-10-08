// MicWatch tests. Registered in tests/main.swift.
//
// The real MicWatch on its real timer, with a stand-in for CoreAudio's list of who's
// recording. Nothing here nudges it: macOS dictation starts and stops without CoreAudio
// telling us, and a stop it never saw left speech held until another app touched the mic.
import Foundation

/// Keep the main run loop moving (the watch looks from there) until `done` or `seconds` pass.
private func spin(_ seconds: TimeInterval, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

let micWatchSuite = Suite("MicWatch") { t in
    guard #available(macOS 14.0, *) else {
        t.expect(true, "no per-process mic flag before macOS 14: nothing to try")
        return
    }
    var recording: [String]? = []
    var seen: [String] = []
    let watch = MicWatch(recorders: { recording }, every: 0.02) { busy, who in
        seen.append(busy ? "held for \(who ?? "nobody")" : "released")
    }
    spin(0.2) { !seen.isEmpty }
    t.expectEqual(seen, [], "nobody recording: nothing to report")

    recording = ["dictation"]
    spin(2) { seen.count == 1 }
    t.expectEqual(seen, ["held for dictation"], "a recorder that starts with no nudge is noticed, and named")

    recording = nil
    spin(0.2) { seen.count > 1 }
    t.expectEqual(seen, ["held for dictation"], "a look that couldn't tell changes nothing")

    recording = []
    spin(2) { seen.count == 2 }
    t.expectEqual(seen, ["held for dictation", "released"], "a recorder that stops with no nudge is noticed: the hold can't stick")
    t.expect(!watch.busy, "and the watch says the mic is free")
}
