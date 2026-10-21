import Foundation
import AVFoundation
import Speech

// ---------------------------------------------------------------------------
// Dictation from the phone: the page records what you say and sends it here, and the
// Mac's own transcriber turns it into words for the page's answer box. The sound goes
// from your phone to your Mac and no further; it's deleted once it has been heard.
// ---------------------------------------------------------------------------

enum Dictation {
    /// What the page sends: plain 16-bit sound in a WAV, which any Mac reads.
    static let type = "audio/wav"
    /// The least a recording can be and still be one: a WAV's 44-byte header and a
    /// tenth of a second at the page's 16,000 samples a second.
    static let least = 44 + 3_200

    /// How long the transcriber gets with one recording before it's given up on. Three
    /// minutes of speech takes it a few seconds; a recording it can't make sense of has
    /// been seen to keep it for ever (10-08: a WAV whose header didn't match its length).
    static let patience: TimeInterval = 45

    /// A number in a WAV's header: `bytes` of them at `at`, smallest first.
    private static func number(_ data: Data, _ at: Int, _ bytes: Int) -> Int {
        (0..<bytes).reduce(0) { $0 | Int(data[data.startIndex + at + $1]) << (8 * $1) }
    }

    /// Whether `data` is exactly what the page makes, by its own bytes and whatever the
    /// request called it: a 44-byte header saying plain 16-bit sound on one channel, then
    /// just as much sound as the header says. Anything else never reaches the transcriber.
    static func looksRight(_ data: Data) -> Bool {
        guard data.count >= least else { return false }
        func tag(_ at: Int) -> String { String(decoding: data.dropFirst(at).prefix(4), as: UTF8.self) }
        return tag(0) == "RIFF" && tag(8) == "WAVE" && tag(12) == "fmt " && number(data, 16, 4) == 16
            && number(data, 20, 2) == 1 && number(data, 22, 2) == 1 && (8_000...48_000).contains(number(data, 24, 4))
            && number(data, 34, 2) == 16 && tag(36) == "data" && number(data, 40, 4) == data.count - 44
    }

    /// How long `data` runs, in seconds, by its header's own figures. 0 if they're missing.
    static func seconds(_ data: Data) -> Double {
        guard data.count >= 44 else { return 0 }
        let perSecond = number(data, 28, 4)
        return perSecond > 0 ? Double(data.count - 44) / Double(perSecond) : 0
    }

    /// The transcriber a phone's recording is given to, or nil where there is none
    /// (before macOS 26). `done` is called on the main thread.
    static var transcriber: ((Data, @escaping (Result<String, Failure>) -> Void) -> Void)? {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else { return nil }
        return { data, done in
            Task {
                let result: Result<String, Failure>
                do { result = .success(try await words(in: data)) }
                catch { result = .failure(Failure((error as? MicEar.Failure)?.why ?? error.localizedDescription)) }
                await MainActor.run { done(result) }
            }
        }
    }

    struct Failure: Error, Equatable {
        let why: String
        init(_ why: String) { self.why = why }
    }

    /// Word for word: the page sends what you're saying a piece at a time (plain 16-bit
    /// sound, one channel, `rate` samples a second), and each piece's answer is the
    /// words so far, the newest of them still a guess. The piece marked `last` gets the
    /// words as they finally stand. One dictation at a time: a new `id` ends the one
    /// before. nil where there's no transcriber. `done` is called on the main thread.
    static var live: ((_ id: String, _ rate: Int, _ sound: Data, _ last: Bool,
                       _ done: @escaping (Result<String, Failure>) -> Void) -> Void)? {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else { return nil }
        return { id, rate, sound, last, done in
            // On the main thread, like everything the page's server does.
            let hearing: LiveDictation
            if let now = current as? LiveDictation, now.id == id {
                hearing = now
            } else {
                (current as? LiveDictation)?.end()
                hearing = LiveDictation(id: id, rate: rate)
                current = hearing
            }
            hearing.take(sound, last: last) { result in
                if last || (try? result.get()) == nil, (current as? LiveDictation) === hearing { current = nil }
                done(result)
            }
        }
    }
    /// The first dictation after the agent starts would wait some seconds for the
    /// transcriber's model to load (4 to 5 s, timed 10-08). A moment of silence put
    /// through it at start means the first one you say doesn't.
    static func warmUp() {
        live?("warmup", 16_000, Data(count: 9_600), true) { _ in }
    }

    /// The dictation being heard word for word, if one is. Main thread.
    private static var current: AnyObject?
    /// A live dictation the page has stopped sending to is let go after this long.
    static let liveIdle: TimeInterval = 20
    /// The most one live dictation may run: the page stops at two minutes.
    static let liveLongest: TimeInterval = 180

    /// What a recording's file is called while the transcriber reads it.
    static let filePrefix = "speakhud-dictation-"

    /// Delete any recording left behind in `dir`: one the transcriber never finished
    /// with outlives the agent that was waiting on it. Run when the agent starts, when
    /// nothing can be in the middle of being heard. Returns how many went.
    @discardableResult
    static func sweep(in dir: String = NSTemporaryDirectory()) -> Int {
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(filePrefix) }
        return left.filter { (try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent($0))) != nil }.count
    }

    /// The words said in a recording. It's written to a file of your own for the
    /// transcriber to read, and the file goes as soon as it has been.
    @available(macOS 26.0, *)
    static func words(in data: Data) async throws -> String {
        let path = NSTemporaryDirectory() + "\(filePrefix)\(UUID().uuidString).wav"
        guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw MicEar.Failure("the recording couldn't be kept long enough to hear it")
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: URL(fileURLWithPath: path)) }
        catch { throw MicEar.Failure("the recording isn't sound this Mac can read") }
        let transcriber = await MicEar.transcriber()
        try await MicEar.install(transcriber)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // A transcriber that hasn't finished in `patience` is stopped where it is.
        let began = Date()
        let watch = Task {
            try? await Task.sleep(nanoseconds: UInt64(patience * 1_000_000_000))
            if !Task.isCancelled { await analyzer.cancelAndFinishNow() }
        }
        defer { watch.cancel() }
        // Each result is one stretch of speech, guessed at and then final: the finals are it.
        async let heard: String = {
            var settled = ""
            for try await result in transcriber.results where result.isFinal { settled += String(result.text.characters) }
            return settled
        }()
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let words = try await heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Date().timeIntervalSince(began) < patience else { throw MicEar.Failure("the Mac took too long to hear it") }
        return words
    }
}

/// One dictation from the phone, heard as it's said: the transcriber is kept open, each
/// piece of sound the page sends is fed to it, and its words so far are there to read.
/// Everything here runs on the main thread except the transcriber's own work.
@available(macOS 26.0, *)
final class LiveDictation: @unchecked Sendable {
    let id: String
    private let rate: Int
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var converter: AVAudioConverter?
    private var from: AVAudioFormat?
    private var to: AVAudioFormat?
    private var opening: Task<Void, Never>?
    private var results: Task<Void, Never>?
    private var problem: String?
    private var settled = ""      // the stretches of speech that are final
    private var guess = ""        // the stretch being said: it changes as more is heard
    private var samples = 0
    private var idle: DispatchWorkItem?
    private var ended = false

    init(id: String, rate: Int) {
        self.id = id
        self.rate = rate
    }

    var text: String { (settled + guess).trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether this dictation is holding a transcriber open. One that has ended must
    /// not be, whenever it was ended (tests/EarTests.swift).
    var isOpen: Bool { analyzer != nil || feed != nil || results != nil }

    /// Feed it `sound`; `done` gets the words so far, or, for the `last` piece, the words
    /// as they finally stand once the transcriber has heard everything.
    func take(_ sound: Data, last: Bool, done: @escaping (Result<String, Dictation.Failure>) -> Void) {
        guard !ended else { return done(.failure(Dictation.Failure("that dictation is over"))) }
        idle?.cancel()
        let quiet = DispatchWorkItem { [weak self] in self?.end() }
        idle = quiet
        DispatchQueue.main.asyncAfter(deadline: .now() + Dictation.liveIdle, execute: quiet)
        if opening == nil { opening = Task { await self.open() } }
        let ready = opening
        Task {
            await ready?.value   // the first piece waits for the transcriber; the rest find it open
            await MainActor.run {
                // Ended first: shutting a transcriber can leave a problem of its own behind.
                guard !self.ended else { return done(.failure(Dictation.Failure("that dictation is over"))) }
                if let problem = self.problem { self.end(); return done(.failure(Dictation.Failure(problem))) }
                self.samples += sound.count / 2
                if Double(self.samples) / Double(self.rate) > Dictation.liveLongest {
                    self.end()
                    return done(.failure(Dictation.Failure("that's more than the Mac hears in one go")))
                }
                self.hand(sound)
                if last { self.finish(done) } else { done(.success(self.text)) }
            }
        }
    }

    /// Ready the transcriber and start reading its results. Leaves `problem` set if it can't.
    private func open() async {
        do {
            let transcriber = await MicEar.transcriber()
            try await MicEar.install(transcriber)
            guard let to = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
                  let from = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: from, to: to) else {
                throw MicEar.Failure("the phone's sound can't be made into what the transcriber takes")
            }
            converter.primeMethod = .none
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: stream)
            let results = Task {
                do {
                    for try await result in transcriber.results {
                        let piece = String(result.text.characters), final = result.isFinal
                        await MainActor.run {
                            if final { self.settled += piece; self.guess = "" } else { self.guess = piece }
                        }
                    }
                } catch {
                    let why = error.localizedDescription
                    await MainActor.run { self.problem = self.problem ?? why }
                }
            }
            // On the main thread, where end() runs. A dictation ended while all this was
            // being readied found nothing open to shut, so what was started is shut here.
            let kept = await MainActor.run { () -> Bool in
                guard !self.ended else { return false }
                (self.analyzer, self.feed, self.results) = (analyzer, feed, results)
                (self.converter, self.from, self.to) = (converter, from, to)
                return true
            }
            if !kept {
                feed.finish()
                results.cancel()
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            let why = (error as? MicEar.Failure)?.why ?? error.localizedDescription
            await MainActor.run { self.problem = why }
        }
    }

    /// One piece of the page's sound, to the transcriber.
    private func hand(_ sound: Data) {
        let frames = sound.count / 2
        guard frames > 0, let from = from, let to = to, let converter = converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(frames)),
              let room = buffer.int16ChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        sound.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(room[0], base, frames * 2) }
        }
        if let out = MicEar.convert(buffer, with: converter, to: to) { feed?.yield(AnalyzerInput(buffer: out)) }
    }

    /// No more sound is coming: let the transcriber finish what it has, then say the words.
    private func finish(_ done: @escaping (Result<String, Dictation.Failure>) -> Void) {
        ended = true
        idle?.cancel()
        feed?.finish()
        let analyzer = self.analyzer, results = self.results
        Task {
            var failure: String?
            do { try await analyzer?.finalizeAndFinishThroughEndOfInput() }
            catch { failure = error.localizedDescription }
            await results?.value
            let trouble = failure
            await MainActor.run {
                (self.analyzer, self.feed, self.results) = (nil, nil, nil)   // finished: nothing is open now
                if let why = trouble ?? self.problem { done(.failure(Dictation.Failure(why))) } else { done(.success(self.text)) }
            }
        }
    }

    /// Stop hearing it, with nothing more to say: a new dictation has begun, or the page
    /// went quiet. If its transcriber is still being readied there's nothing to shut
    /// yet: `open` sees that it has ended and shuts what it started.
    func end() {
        guard !ended else { return }
        ended = true
        idle?.cancel()
        feed?.finish()
        results?.cancel()
        if let analyzer = analyzer { Task { await analyzer.cancelAndFinishNow() } }
        (analyzer, feed, results) = (nil, nil, nil)
    }
}
