import Foundation
import CoreAudio

// ---------------------------------------------------------------------------
// The mic. When something else starts recording — Claude Code's hold-space
// dictation, a call, system dictation — we shut up until it stops, or whatever
// we're saying ends up in the transcript.
// ---------------------------------------------------------------------------

/// Who's recording comes from CoreAudio's per-process "running input" flag (macOS 14+).
/// Deliberately not the device-wide "running somewhere" flag as the answer: a headset
/// is one device for mic and speaker, so that flips the moment we start talking.
/// But the per-process flag never notifies, so the device flag, the process list, and
/// the default-input choice are just triggers to go and look again.
/// And they miss some recorders: macOS dictation records through a system daemon
/// (historicalaudiod) on a mic that isn't the default input, so nothing fired when it
/// stopped and the hold stuck until some other app touched the mic. So it also looks
/// on a timer, nudged or not.
@available(macOS 14.0, *)
final class MicWatch {
    /// How often it looks without being nudged.
    static let pollEvery: TimeInterval = 0.5

    private(set) var busy = false
    private let recorders: () -> [String]?
    private let onChange: (Bool, String?) -> Void
    private var poll: Timer?
    private var inputDevice = AudioObjectID(kAudioObjectUnknown)
    private var trigger: AudioObjectPropertyListenerBlock!
    private var deviceChanged: AudioObjectPropertyListenerBlock!
    private let system = AudioObjectID(kAudioObjectSystemObject)

    /// `recorders` names who else is recording right now (nil: couldn't tell); tests
    /// stand in for CoreAudio there. `onChange` gets the first name with a hold.
    init(recorders: @escaping () -> [String]? = MicWatch.otherRecorders,
         every: TimeInterval = MicWatch.pollEvery,
         onChange: @escaping (Bool, String?) -> Void) {
        self.recorders = recorders
        self.onChange = onChange
        trigger = { [weak self] _, _ in self?.recheck() }
        deviceChanged = { [weak self] _, _ in self?.followDefaultInput() }
        var list = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(system, &list, .main, trigger)
        var def = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(system, &def, .main, deviceChanged)
        followDefaultInput()
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in self?.look() }
        timer.tolerance = every / 5
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    deinit { poll?.invalidate() }

    static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T: FixedWidthInteger>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> T? {
        var addr = address(sel)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// Plugging in a headset moves the default input; the old device goes quiet on us.
    private func followDefaultInput() {
        var running = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if inputDevice != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(inputDevice, &running, .main, trigger)
        }
        inputDevice = Self.read(system, kAudioHardwarePropertyDefaultInputDevice) ?? AudioObjectID(kAudioObjectUnknown)
        if inputDevice != kAudioObjectUnknown {
            AudioObjectAddPropertyListenerBlock(inputDevice, &running, .main, trigger)
        }
        recheck()
    }

    private func recheck() {
        look()
        // A recorder's process shows up a beat before its input is actually running;
        // look once more so that ordering can't leave us talking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.look() }
    }

    private func look() {
        guard let others = recorders() else { return }   // couldn't tell: what we knew stands
        let now = !others.isEmpty
        guard now != busy else { return }
        busy = now
        onChange(now, others.first)
    }

    /// Every other process whose input is running, by name. Ours doesn't count.
    static func otherRecorders() -> [String]? {
        processes(running: kAudioProcessPropertyIsRunningInput)?.map(\.name)
    }

    /// Every other process with the given running flag (input or output) set. Ours
    /// doesn't count. nil: couldn't ask.
    static func processes(running flag: AudioObjectPropertySelector) -> [(id: AudioObjectID, name: String)]? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        let me = getpid()
        return ids.compactMap { id in
            let running: UInt32? = read(id, flag)
            guard (running ?? 0) != 0 else { return nil }
            let pid: Int32? = read(id, kAudioProcessPropertyPID)
            guard pid != me else { return nil }
            let who = name(of: pid)
            return ignored(who) ? nil : (id: id, name: who)
        }
    }

    /// Apps that hold the mic or play sound all day without anyone using them, so they
    /// never hold speech. Vorssaint (a menu bar utility) keeps the mic open from launch
    /// (Chris, 10-26: "make it ignore that shit").
    static let ignoredPrograms: Set<String> = ["Vorssaint"]
    static func ignored(_ name: String) -> Bool { ignoredPrograms.contains(name) }

    /// What to call a recorder in the log. macOS dictation and Siri have no process of
    /// their own on the mic: both show up as the system's historicalaudiod. Claude Code's
    /// program file is named for its version (…/claude/versions/2.1.293).
    private static func name(of pid: Int32?) -> String {
        guard let pid = pid else { return "an unknown process" }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "pid \(pid)" }
        return name(ofProgram: String(cString: buf))
    }

    static func name(ofProgram path: String) -> String {
        let file = (path as NSString).lastPathComponent
        if file == "historicalaudiod" { return "macOS dictation or Siri (historicalaudiod)" }
        if path.contains("/claude/versions/") { return "Claude Code \(file)" }
        return file
    }
}

/// Between MicWatch and Playback: whether "someone's recording" should hold speech.
/// Owns the "Pause While Recording" setting and the release debounce. A hold starts at
/// once; a release from the mic waits a beat (recorders drop and reopen the mic between
/// chunks, and you may just be pausing for breath); a release because you switched the
/// setting off is immediate. `deliver` only ever sees transitions.
final class MicHold {
    /// Key in the shared prefs suite, so the agent and the standalone reader agree.
    static let prefKey = "pauseWhileRecording"
    static let releaseDelay: TimeInterval = 0.6

    /// On unless you've turned it off.
    static func storedEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: prefKey) as? Bool ?? true
    }
    static func store(_ on: Bool, in defaults: UserDefaults) { defaults.set(on, forKey: prefKey) }

    private(set) var enabled: Bool
    private(set) var recording = false   // what MicWatch last said, whatever the setting
    private(set) var holding = false     // what Playback was last told
    private var cancelRelease: (() -> Void)?
    private let deliver: (Bool) -> Void
    private let debounce: (@escaping () -> Void) -> () -> Void

    /// `debounce` runs work after `releaseDelay` and returns its cancel; tests run it by hand.
    init(enabled: Bool,
         deliver: @escaping (Bool) -> Void,
         debounce: @escaping (@escaping () -> Void) -> () -> Void = { work in
             let item = DispatchWorkItem(block: work)
             DispatchQueue.main.asyncAfter(deadline: .now() + MicHold.releaseDelay, execute: item)
             return item.cancel
         }) {
        self.enabled = enabled
        self.deliver = deliver
        self.debounce = debounce
    }

    func recordingChanged(_ busy: Bool) {
        recording = busy
        guard enabled else { return }
        if busy { hold() } else if holding, cancelRelease == nil {
            cancelRelease = debounce { [weak self] in
                self?.cancelRelease = nil
                self?.release()
            }
        }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if !on { release() } else if recording { hold() }
    }

    private func hold() {
        cancelRelease?(); cancelRelease = nil
        guard !holding else { return }
        holding = true
        deliver(true)
    }

    private func release() {
        cancelRelease?(); cancelRelease = nil
        guard holding else { return }
        holding = false
        deliver(false)
    }
}
