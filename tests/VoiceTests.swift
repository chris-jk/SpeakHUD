// A Voice per Project tests. Registered in tests/main.swift.
// VoiceCast with made-up voices, and Playback naming whose turn each reading is.
import Foundation

let voiceSuite = Suite("Voice") { t in
    let pool = ["samantha", "daniel", "karen"]
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    do {  // each terminal its own voice, and the same one each time
        var cast = VoiceCast()
        t.expectEqual(cast.voice(for: "Grow guide", from: pool, now: at(0)), "samantha", "the first gets the Mac's own voice")
        t.expectEqual(cast.voice(for: "Strain guide", from: pool, now: at(1)), "daniel", "the next a voice nobody has")
        t.expectEqual(cast.voice(for: "SpeakHUD", from: pool, now: at(2)), "karen", "and the next")
        t.expectEqual(cast.voice(for: "Grow guide", from: pool, now: at(3)), "samantha", "a name keeps its voice")
        t.expectEqual(cast.voice(for: "Vera", from: pool, now: at(4)), "daniel",
                      "all taken: the voice heard longest ago (Strain guide's, not Grow guide's just now)")
        t.expectEqual(cast.voice(for: "Strain guide", from: pool, now: at(5)), "daniel", "the two share it from then on")
    }
    do {  // a name long gone gives its voice back; a voice gone from the Mac is recast
        var cast = VoiceCast()
        _ = cast.voice(for: "old", from: pool, now: at(0))
        _ = cast.voice(for: "new", from: pool, now: at(0) + VoiceCast.forget + 1)
        t.expectEqual(cast.parts.keys.sorted(), ["new"], "forgotten after a fortnight unheard")
        t.expectEqual(cast.voice(for: "new", from: ["daniel", "karen"], now: at(0) + VoiceCast.forget + 2), "daniel",
                      "its voice uninstalled: it gets one that's there")
        t.expect(cast.voice(for: "any", from: ["samantha"], now: at(0)) == nil, "one voice on the Mac: nothing to choose")
    }
    do {  // kept across restarts
        let suite = "speakhud.voicetest.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        t.expect(VoiceCast.enabled(in: d), "on by default")
        var cast = VoiceCast.load(from: d)
        _ = cast.voice(for: "Grow guide", from: pool, now: at(0))
        _ = cast.voice(for: "Strain guide", from: pool, now: at(0))
        cast.save(to: d)
        var again = VoiceCast.load(from: d)
        t.expectEqual(again.voice(for: "Strain guide", from: pool, now: at(1)), "daniel", "a name sounds the same after a restart")
        d.set(false, forKey: VoiceCast.prefKey)
        t.expect(!VoiceCast.enabled(in: d), "off is remembered")
    }

    // -- which voices -------------------------------------------------------
    let installed = [
        (id: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", quality: 1, novelty: false),
        (id: "com.apple.voice.enhanced.en-US.Samantha", name: "Samantha", language: "en-US", quality: 2, novelty: false),
        (id: "com.apple.voice.compact.en-GB.Daniel", name: "Daniel", language: "en-GB", quality: 1, novelty: false),
        (id: "com.apple.voice.super-compact.en-AU.Karen", name: "Karen", language: "en-AU", quality: 1, novelty: false),
        (id: "com.apple.voice.compact.fr-FR.Thomas", name: "Thomas", language: "fr-FR", quality: 1, novelty: false),
        (id: "com.apple.eloquence.en-US.Reed", name: "Reed", language: "en-US", quality: 1, novelty: false),
        (id: "com.apple.speech.synthesis.voice.Fred", name: "Fred", language: "en-US", quality: 1, novelty: false),
        (id: "com.apple.speech.synthesis.voice.Bubbles", name: "Bubbles", language: "en-US", quality: 1, novelty: true),
    ]
    t.expectEqual(VoiceCast.pool(installed, default: (name: "Karen", language: "en-AU")),
                  ["com.apple.voice.super-compact.en-AU.Karen", "com.apple.voice.compact.en-GB.Daniel",
                   "com.apple.voice.enhanced.en-US.Samantha"],
                  "Apple's current voices in the Mac's language, each at its best, the Mac's own first; no novelty or old synth voices")

    // -- Playback says whose turn it is ---------------------------------------
    do {
        let r = Rig(), p = r.playback!
        p.enqueue(SpeechItem(text: "a", source: "Grow guide", key: "A", created: Date(), file: "/tmp/a.taken"))
        p.enqueue(SpeechItem(text: "b", source: "Strain guide", key: "B", created: Date(), file: "/tmp/b.taken"))
        r.voice.finish()
        t.expectEqual(r.voice.speakers, ["Grow guide", "Strain guide"], "each reading is named for its source")
    }
}
