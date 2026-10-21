import Foundation
import AVFoundation

/// The app's voice: AVSpeechSynthesizer behind the `Voice` seam.
final class SpeechVoice: NSObject, Voice, AVSpeechSynthesizerDelegate {
    weak var listener: Playback?
    var speaker: String?

    /// The voices a Voice per Project casts from, read once: asking is slow.
    static let pool: [String] = {
        let mine = AVSpeechSynthesisVoice(language: nil)
        func novelty(_ v: AVSpeechSynthesisVoice) -> Bool {
            if #available(macOS 14.0, *) { return v.voiceTraits.contains(.isNoveltyVoice) }
            return false   // and they're not among Apple's current voices anyway
        }
        let all = AVSpeechSynthesisVoice.speechVoices().map {
            (id: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality.rawValue, novelty: novelty($0))
        }
        return VoiceCast.pool(all, default: mine.map { (name: $0.name, language: $0.language) })
    }()

    // Replaced on every (re)start: stopSpeaking(.immediate) poisons an instance so
    // the next utterance silently finishes with no audio. A fresh synth avoids that.
    private var synth: AVSpeechSynthesizer?
    private var utterance = 0
    private var sliceStart = 0   // where in the full text the live utterance begins

    func speak(_ text: String, from offset: Int, rate: Float, utterance id: Int) {
        stop()
        request = (text, offset, rate, id)
        let ns = text as NSString
        sliceStart = min(max(offset, 0), ns.length)
        utterance = id
        // Speak from the resume point so a speed change picks up where we left off
        // rather than restarting from the top.
        let u = AVSpeechUtterance(string: ns.substring(from: sliceStart))
        let env = ProcessInfo.processInfo.environment
        if let v = env["SPEAK_VOICE"], !v.isEmpty {
            // Accept either a voice identifier or a name; fall back gracefully.
            if let voice = AVSpeechSynthesisVoice(identifier: v) { u.voice = voice }
            else if let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == v }) { u.voice = voice }
        } else if let name = speaker, VoiceCast.enabled(in: prefs) {
            var cast = VoiceCast.load(from: prefs)
            if let id = cast.voice(for: name, from: Self.pool, now: Date()) {
                cast.save(to: prefs)
                u.voice = AVSpeechSynthesisVoice(identifier: id)
            }
        }
        u.rate = rate
        let s = AVSpeechSynthesizer()
        s.delegate = self
        synth = s
        spoke = false
        s.speak(u)
    }

    /// A fresh synth ignores a pause that arrives before its first word — it reports
    /// isPaused and talks anyway, even if the pause is sent from didStart or a hop after
    /// it (all verified on this machine) — and every utterance is a fresh synth. Nothing
    /// has been heard yet in that window, so drop the synth and speak the same request
    /// again on resume.
    private var spoke = false
    private var request: (text: String, offset: Int, rate: Float, id: Int)?
    private var parked = false

    func pause(immediately: Bool) {
        if spoke {
            synth?.pauseSpeaking(at: immediately ? .immediate : .word)
        } else if synth != nil {
            let r = request
            stop()
            request = r
            parked = true
        }
    }
    func resume() {
        if parked, let r = request {
            speak(r.text, from: r.offset, rate: r.rate, utterance: r.id)
        } else {
            synth?.continueSpeaking()
        }
    }

    /// stopSpeaking(.immediate) delivers didFinish — not didCancel — on both a speaking
    /// and a paused synth (verified on this machine). Letting go of the instance first
    /// makes that late finish come from a synth that isn't live, which is ignored; a
    /// stop must never reach Playback as "finished".
    func stop() {
        parked = false
        request = nil
        guard let s = synth else { return }
        synth = nil
        s.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        guard s === synth else { return }   // replaced or stopped: not ours to report
        // Playback records the finish now and hops out of this callback before starting
        // the next item: that replaces `synth`, deallocating the very instance calling
        // us, and the next utterance can be dropped without a sound.
        listener?.voiceFinished(utterance: utterance)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {}

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance u: AVSpeechUtterance) {
        guard s === synth else { return }
        spoke = true
        // Ranges are relative to the (possibly sliced) utterance; shift to full-text coords.
        listener?.voiceSpoke(NSRange(location: sliceStart + characterRange.location,
                                     length: characterRange.length), utterance: utterance)
    }
}
