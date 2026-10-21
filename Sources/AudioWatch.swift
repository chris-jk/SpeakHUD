import Cocoa
import CoreAudio

// ---------------------------------------------------------------------------
// Wait While Audio Plays: another app is making sound, so we don't talk over it.
// ---------------------------------------------------------------------------

/// A process that has CoreAudio output running.
struct AudioSource: Equatable {
    let id: AudioObjectID
    let name: String
}

/// Measures how loud the given processes are. `takePeak` is the loudest sample (linear,
/// 0...1) since the last call, nil when it can't hear. The real one is a Core Audio
/// process tap; tests stand in.
protocol AudioMeter: AnyObject {
    func start(_ sources: [AudioSource]) -> Bool
    func stop()
    func takePeak() -> Float?
}

/// Process tap on the given processes' output (macOS 14.2+), read by an IOProc on a private
/// aggregate device. Unmuted: what you hear is untouched. Needs the system-audio-recording
/// permission; without it the tap can't be made, or only ever hears silence, and either
/// way nothing holds.
@available(macOS 14.2, *)
final class TapMeter: AudioMeter {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let lock = NSLock()
    private var peak: Float = 0
    private var heard = false

    func start(_ sources: [AudioSource]) -> Bool {
        stop()
        guard !sources.isEmpty else { return false }
        let desc = CATapDescription(stereoMixdownOfProcesses: sources.map(\.id))
        desc.uuid = UUID()
        desc.muteBehavior = CATapMuteBehavior.unmuted
        desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { tap = AudioObjectID(kAudioObjectUnknown); return false }
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpeakHUD audio check",
            kAudioAggregateDeviceUIDKey: "com.chris.speakhud.tap.\(desc.uuid.uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregate) == noErr else {
            stop(); return false
        }
        let queue = DispatchQueue(label: "speakhud.audio-meter", qos: .utility)
        let made = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { [weak self] _, input, _, _, _ in
            var top: Float = 0
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            for b in buffers {
                guard let data = b.mData else { continue }
                let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                let p = data.assumingMemoryBound(to: Float.self)
                for i in 0..<n { top = max(top, abs(p[i])) }
            }
            guard let self = self else { return }
            self.lock.lock(); self.peak = max(self.peak, top); self.heard = true; self.lock.unlock()
        }
        guard made == noErr, let id = procID, AudioDeviceStart(aggregate, id) == noErr else { stop(); return false }
        return true
    }

    func stop() {
        if let id = procID, aggregate != kAudioObjectUnknown {
            AudioDeviceStop(aggregate, id)
            AudioDeviceDestroyIOProcID(aggregate, id)
        }
        procID = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
        lock.lock(); peak = 0; heard = false; lock.unlock()
    }

    func takePeak() -> Float? {
        lock.lock(); defer { lock.unlock() }
        guard heard else { return nil }
        defer { peak = 0 }
        return peak
    }

    deinit { stop() }
}

/// Watches for real sound from other apps. Output-running is only the cheap first
/// filter: a paused player still reports it, so the loudness is measured with a tap,
/// and only while some other process has output running. Never holds on the flag alone.
@available(macOS 14.0, *)
final class AudioWatch {
    static let pollEvery: TimeInterval = 0.25
    /// About -50 dBFS.
    static let threshold: Float = 0.00316

    private(set) var playing = false
    private let outputs: () -> [AudioSource]?
    private let meter: AudioMeter
    private let onChange: (Bool, String?) -> Void
    private let onUnavailable: () -> Void
    private var poll: Timer?
    private var tapped: [AudioSource] = []
    private var refused: [AudioSource]?   // the apps a tap was last refused for: not asked again until they change
    private var warned = false
    private var trigger: AudioObjectPropertyListenerBlock!

    /// `outputs` names the other processes with output running (nil: couldn't tell).
    init(outputs: @escaping () -> [AudioSource]? = AudioWatch.otherOutputs,
         meter: AudioMeter,
         every: TimeInterval = AudioWatch.pollEvery,
         onUnavailable: @escaping () -> Void = {},
         onChange: @escaping (Bool, String?) -> Void) {
        self.outputs = outputs
        self.meter = meter
        self.onChange = onChange
        self.onUnavailable = onUnavailable
        trigger = { [weak self] _, _ in self?.look() }
        var list = MicWatch.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &list, .main, trigger)
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in self?.look() }
        timer.tolerance = every / 5
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    deinit { poll?.invalidate(); meter.stop() }

    /// The decision: with other output running, loud enough means playing. No output
    /// running, or nothing heard (no permission, not started yet), means not playing.
    static func decide(others: [AudioSource], peak: Float?) -> Bool {
        !others.isEmpty && (peak ?? 0) > threshold
    }

    func look() {
        guard let others = outputs() else { return }   // couldn't tell: what we knew stands
        if others.isEmpty {
            if !tapped.isEmpty { meter.stop(); tapped = [] }   // quiet Mac: nothing runs
            refused = nil   // permission may have come by the next sound
            set(false, nil)
            return
        }
        if others != tapped {
            tapped = []
            // Refused for these same apps: asking again four times a second won't change it.
            guard others != refused else { set(false, nil); return }
            if meter.start(others) {
                tapped = others
                refused = nil
            } else {
                refused = others
                if !warned { warned = true; onUnavailable() }
                set(false, nil)
                return
            }
        }
        set(Self.decide(others: others, peak: meter.takePeak()), others.first?.name)
    }

    private func set(_ now: Bool, _ who: String?) {
        guard now != playing else { return }
        playing = now
        onChange(now, who)
    }

    /// Every other process with output running. Ours doesn't count (our voice is ours).
    static func otherOutputs() -> [AudioSource]? {
        MicWatch.processes(running: kAudioProcessPropertyIsRunningOutput).map {
            $0.map { AudioSource(id: $0.id, name: $0.name) }
        }
    }
}

/// Between AudioWatch and Playback, as MicHold is for the mic: owns the "Wait While Audio
/// Plays" setting and both debounces. Sound has to last `holdDelay` before it holds (a
/// system beep shouldn't pause a sentence); silence has to last `releaseDelay` before it
/// lets go (gaps between songs, a pause in dialogue). Switching the setting off lets go
/// at once. `deliver` only ever sees transitions.
final class AudioHold {
    static let prefKey = "waitWhileAudioPlays"
    static let holdDelay: TimeInterval = 0.3
    static let releaseDelay: TimeInterval = 1.5

    static func storedEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: prefKey) as? Bool ?? true
    }
    static func store(_ on: Bool, in defaults: UserDefaults) { defaults.set(on, forKey: prefKey) }

    private(set) var enabled: Bool
    private(set) var playing = false   // what AudioWatch last said, whatever the setting
    private(set) var holding = false   // what Playback was last told
    private var cancelHold: (() -> Void)?
    private var cancelRelease: (() -> Void)?
    private let deliver: (Bool) -> Void
    private let later: (TimeInterval, @escaping () -> Void) -> () -> Void

    /// `later` runs work after the delay and returns its cancel; tests run it by hand.
    init(enabled: Bool,
         deliver: @escaping (Bool) -> Void,
         later: @escaping (TimeInterval, @escaping () -> Void) -> () -> Void = { delay, work in
             let item = DispatchWorkItem(block: work)
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
             return item.cancel
         }) {
        self.enabled = enabled
        self.deliver = deliver
        self.later = later
    }

    func playingChanged(_ now: Bool) {
        playing = now
        guard enabled else { return }
        if now { sound() } else { silence() }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if !on { release() } else if playing { sound() }
    }

    private func sound() {
        cancelRelease?(); cancelRelease = nil
        guard !holding, cancelHold == nil else { return }
        cancelHold = later(Self.holdDelay) { [weak self] in
            self?.cancelHold = nil
            self?.hold()
        }
    }

    private func silence() {
        cancelHold?(); cancelHold = nil
        guard holding, cancelRelease == nil else { return }
        cancelRelease = later(Self.releaseDelay) { [weak self] in
            self?.cancelRelease = nil
            self?.release()
        }
    }

    private func hold() {
        guard !holding else { return }
        holding = true
        deliver(true)
    }

    private func release() {
        cancelHold?(); cancelHold = nil
        cancelRelease?(); cancelRelease = nil
        guard holding else { return }
        holding = false
        deliver(false)
    }
}
