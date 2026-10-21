import Foundation
import AVFoundation
import Speech

// ---------------------------------------------------------------------------
// The ear: the mic, and the Mac's own transcriber turning what it hears into words
// (SpeechAnalyzer, macOS 26). On-device: nothing said leaves the Mac. The model is the
// system's; this app's first use registers it, and downloads it if the Mac lacks it.
// ---------------------------------------------------------------------------

@available(macOS 26.0, *)
final class MicEar: Ear, @unchecked Sendable {
    weak var listener: Playback?

    // Main thread only, like everything Playback calls. The work of getting ready
    // happens off it and comes back to it before the mic opens.
    private var window = 0   // the window being listened for; 0 when shut
    private var task: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?

    struct Failure: Error {
        let why: String
        init(_ why: String) { self.why = why }
    }

    /// Where the sound comes from: the mic, or a recording played in as if it were said
    /// (tests/EarTests.swift, so the transcriber is tried for real without a sound).
    enum Source { case microphone, recording(String) }
    private let source: Source
    init(source: Source = .microphone) { self.source = source }

    /// Buffers handed to the transcriber for the open window, counted from the audio
    /// thread. Logged when the window shuts: none at all means the mic gave nothing.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
    private var tally: Tally?
    private var player: Task<Void, Never>?

    static let micDenied = "microphone access is off for SpeakHUD (System Settings › Privacy & Security › Microphone)"

    func listen(window id: Int, overSpeech: Bool) {
        stop()
        window = id
        task = Task { [weak self] in await self?.run(id, overSpeech: overSpeech) }
    }

    func stop() {
        window = 0
        task?.cancel()
        task = nil
        player?.cancel()
        player = nil
        if let t = tally { listener?.log("mic shut after \(t.count) buffers") }
        tally = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        feed?.finish()
        feed = nil
        if let a = analyzer { Task { await a.cancelAndFinishNow() } }
        analyzer = nil
    }

    /// Ask for the mic and ready the model now, so the first reply window doesn't open
    /// onto a permission prompt. `done` gets what's wrong, or nil, on the main thread.
    func prepare(_ done: @escaping (String?) -> Void) {
        Task {
            var problem: String?
            if !SpeechTranscriber.isAvailable {
                problem = "this Mac's transcriber isn't available"
            } else if !(await AVCaptureDevice.requestAccess(for: .audio)) {
                problem = Self.micDenied
            } else {
                do { try await Self.install(await Self.transcriber()) }
                catch { problem = "the speech model couldn't be readied: \(error.localizedDescription)" }
            }
            let result = problem
            await MainActor.run { done(result) }
        }
    }

    static func transcriber() async -> SpeechTranscriber {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            ?? Locale(identifier: "en-US")
        // Progressive: words are reported as they're heard, and firmed up after.
        return SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    static func install(_ transcriber: SpeechTranscriber) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    private func run(_ id: Int, overSpeech: Bool) async {
        do {
            if case .microphone = source {
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure(Self.micDenied) }
            }
            let transcriber = await Self.transcriber()
            try await Self.install(transcriber)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw Failure("the transcriber offers no audio format")
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
            // For a moment after one mic session shuts, the next can fail to start, or
            // start and then give nothing. Going from the echo-cancelling mic straight to
            // the plain one failed 8 times in 8 ("bad device", tried 10-07), and in use it
            // twice opened to silence. Playback no longer asks for that switch, but a mic
            // is a mic: try again a few times, and don't call it open until sound is
            // arriving and keeps arriving.
            var tries = 0
            while true {
                tries += 1
                do {
                    let open = try await MainActor.run {
                        try self.openMic(for: id, overSpeech: overSpeech, feed: feed, as: format, analyzer: analyzer)
                    }
                    guard open else { feed.finish(); return }
                    if try await soundArrives(for: id, within: Self.tryWait(overSpeech: overSpeech)) { break }
                    if tries >= Self.openTries { throw Failure("the microphone opened but gave no sound") }
                } catch let failure as Failure {
                    if tries >= Self.openTries { throw failure }
                }
                await MainActor.run { self.shutEngine() }
                try await Task.sleep(nanoseconds: UInt64(Self.tryGap * 1_000_000_000))
            }
            if tries > 1 {
                let n = tries
                await MainActor.run { self.listener?.log("mic opened on try \(n)") }
            }
            try await analyzer.start(inputSequence: stream)
            await MainActor.run {
                if self.window == id { self.listener?.earOpened(window: id) }
            }
            // Each result is one stretch of speech: guessed at while it's being said,
            // then final. What's reported is everything final plus the current guess.
            var settled = ""
            for try await result in transcriber.results {
                let piece = String(result.text.characters)
                if result.isFinal { settled += piece }
                let text = result.isFinal ? settled : settled + piece
                await MainActor.run {
                    if self.window == id { self.listener?.earHeard(text, window: id) }
                }
                // Over speech the mic is open for as long as there's reading to do, and
                // only short phrases matter: start afresh at a pause rather than grow.
                if overSpeech, result.isFinal, settled.count > 200 { settled = "" }
            }
        } catch is CancellationError {
        } catch {
            let why = (error as? Failure)?.why ?? error.localizedDescription
            await MainActor.run {
                if self.window == id { self.listener?.earFailed(why, window: id) }
            }
        }
    }

    /// A mic gets this many tries at starting. Each is given a while to hand sound on
    /// (longer over speech), with a breath between one try and the next.
    static let openTries = 5
    static func tryWait(overSpeech: Bool) -> TimeInterval { overSpeech ? 2.0 : 1.2 }
    static let tryGap: TimeInterval = 0.35
    /// Readying the transcriber before the first try and starting it after the last.
    /// With its model cold that alone has taken 4 to 5 s (timed 10-08).
    static let readying: TimeInterval = 6

    /// Every try run to its end, and the readying: 13.4 s, or 17.4 s over speech. All
    /// of it is worked out from the numbers the tries themselves run on.
    func opensWithin(overSpeech: Bool) -> TimeInterval {
        Self.readying + Double(Self.openTries) * Self.tryWait(overSpeech: overSpeech)
            + Double(Self.openTries - 1) * Self.tryGap
    }

    /// Whether the mic just opened for `id` is handing sound on, steadily. Throws if
    /// the window is shut meanwhile.
    private func soundArrives(for id: Int, within seconds: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let count = await MainActor.run { self.window == id ? (self.tally?.count ?? 0) : -1 }
            if count < 0 { throw CancellationError() }
            if count >= 3 { return true }   // one buffer and then nothing has been seen
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// Let go of a mic that failed to start or gave nothing, keeping the window, the
    /// feed and the transcriber for the next try. Main thread.
    private func shutEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        tally = nil
    }

    /// Runs on the main thread, where stop() does: a window shut while the model was
    /// being readied must not open the mic after all. False means it was.
    private func openMic(for id: Int, overSpeech: Bool, feed: AsyncStream<AnalyzerInput>.Continuation,
                         as format: AVAudioFormat, analyzer: SpeechAnalyzer) throws -> Bool {
        guard window == id else { return false }
        let tally = Tally()
        if case .recording(let path) = source {
            let file: AVAudioFile
            do { file = try AVAudioFile(forReading: URL(fileURLWithPath: path)) }
            catch { throw Failure("can't read \(path)") }
            let native = file.processingFormat
            guard let converter = AVAudioConverter(from: native, to: format) else {
                throw Failure("the recording can't be converted for the transcriber")
            }
            converter.primeMethod = .none
            // The recording, then quiet for as long as the window stays open, as a mic gives.
            player = Task.detached {
                var playing = true
                while !Task.isCancelled {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: native, frameCapacity: 4096) else { return }
                    if playing {
                        if (try? file.read(into: buffer)) == nil || buffer.frameLength == 0 { playing = false }
                    }
                    if !playing {
                        buffer.frameLength = buffer.frameCapacity
                        for c in 0..<Int(native.channelCount) {
                            if let samples = buffer.floatChannelData?[c] {
                                memset(samples, 0, Int(buffer.frameCapacity) * MemoryLayout<Float>.size)
                            }
                        }
                        try? await Task.sleep(nanoseconds: UInt64(4096 / native.sampleRate * 1_000_000_000))
                    }
                    if let out = Self.convert(buffer, with: converter, to: format) {
                        feed.yield(AnalyzerInput(buffer: out))
                        tally.add()
                    }
                }
            }
            self.tally = tally
            self.feed = feed
            self.analyzer = analyzer
            return true
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if overSpeech {
            // Voice processing cancels what the Mac is playing out of what the mic hears.
            // Tried here 10-07 with the voice reading a 24-word phrase over the speakers:
            // the plain mic gave the transcriber 20 of the words, this gave it none.
            do { try input.setVoiceProcessingEnabled(true) } catch {
                throw Failure("echo cancelling wouldn't start: \(error.localizedDescription)")
            }
            // It also turns other sound down while it's on. As little as it allows: the
            // other sound is the voice.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else { throw Failure("no microphone") }
        // The first channel alone. With voice processing on, the mic reports nine, and
        // converting all nine down to one gave the transcriber silence (same trial): the
        // first is the processed one. A plain mic has only the one.
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: native.sampleRate,
                                       channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: format) else {
            throw Failure("the mic's audio can't be converted for the transcriber")
        }
        converter.primeMethod = .none   // no lead-in: every buffer is converted whole
        input.installTap(onBus: 0, bufferSize: 4096, format: native) { tapped, _ in
            guard let source = tapped.floatChannelData,
                  let first = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: tapped.frameLength),
                  let samples = first.floatChannelData else { return }
            first.frameLength = tapped.frameLength
            memcpy(samples[0], source[0], Int(tapped.frameLength) * MemoryLayout<Float>.size)
            if let out = Self.convert(first, with: converter, to: format) {
                feed.yield(AnalyzerInput(buffer: out))
                tally.add()
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw Failure("the microphone wouldn't start: \(error.localizedDescription)")
        }
        self.engine = engine
        self.tally = tally
        self.feed = feed
        self.analyzer = analyzer
        return true
    }

    /// One mic buffer in the transcriber's format (its sample rate and layout differ).
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, state in
            if fed { state.pointee = .noDataNow; return nil }
            fed = true
            state.pointee = .haveData
            return buffer
        }
        return status != .error && out.frameLength > 0 ? out : nil
    }
}
