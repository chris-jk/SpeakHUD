import Cocoa
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import CoreAudio

// Shared prefs domain so the speed setting is the same no matter how the reader
// was launched (double-click app, Claude Code hook, or the global hotkey).
// NB: the suite name must NOT equal the app's bundle id, or macOS rejects it.
let prefs = UserDefaults(suiteName: "com.chris.speakhud.shared") ?? .standard

// Text source priority: explicit arg → piped stdin (the Claude Code hook) →
// clipboard. The clipboard fallback is what makes the .app useful when launched
// on its own (double-click / Spotlight / a hotkey), where there's no stdin pipe.
func resolveText(_ args: [String]) -> String {
    var i = 1
    while i < args.count {
        let a = args[i]
        if a == "--source" { i += 2; continue }   // flag + its value
        if a.hasPrefix("--") { i += 1; continue }
        if !a.isEmpty { return a }
        i += 1
    }
    // Only drain stdin when it's a pipe/file; reading an interactive TTY would block.
    if isatty(FileHandle.standardInput.fileDescriptor) == 0 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        if let s = String(data: data, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
    }
    return NSPasteboard.general.string(forType: .string) ?? ""
}

// ---------------------------------------------------------------------------
// The unit of speech: one thing to read, and where it came from.
// ---------------------------------------------------------------------------

struct SpeechItem {
    let text: String
    let source: String   // a project name, or the frontmost app
    let key: String      // coalescing key: one Claude Code session == one terminal
    let created: Date
    /// The spool file backing this item. Deleted only once the item has actually been
    /// spoken, so an agent restart can't swallow a queue. Nil for hotkey reads and the
    /// standalone reader, which have nothing on disk to recover.
    var file: String? = nil
}

// Claude Code turns arrive as files here rather than as processes, so a finished
// turn can never interrupt one that's already speaking. The hook writes `<name>.tmp`
// and renames it to `<name>.json`, which is atomic within a filesystem — the agent
// therefore never observes a half-written item.
//
// The contract with hook/read-summary.py (pinned by tests/SpoolTests.swift, which runs
// the real Python `enqueue()` against the real `drain`):
//   v        schema version, optional → legacy (read as 1); anything but 1 → dropped,
//            so a newer hook's items are never misread by an older agent
//   text     string, required; blank after trimming → dropped
//   source   string, optional → "Claude Code"
//   key      string, optional → the file stem (unique, so that item never coalesces)
//   created  epoch seconds, optional → the file's mtime (when the hook wrote it);
//            present but not a number → dropped. Either way older than maxAge → dropped.
// Every dropped item comes back as a `Drop` with its reason, for the agent to log.
//
// Liveness: the agent touches `heartbeatName` in the spool dir at startup and every
// `heartbeatInterval`; the hook queues only while that mtime is fresh, and otherwise
// speaks the turn itself (tests/HookTests.swift pins both sides).
enum Spool {
    static let maxAge: TimeInterval = 600   // a stopped agent shouldn't wake up and read you the backlog
    static let version = 1                  // the `v` this agent reads
    /// Deliberately not .json/.tmp/.taken, so drain and recover never touch it.
    static let heartbeatName = "agent.heartbeat"
    static let heartbeatInterval: TimeInterval = 3
    /// Points both sides at another queue — the hook reads the same variable. For tests;
    /// set it for one side only and the hook writes where nobody reads.
    static let dirEnv = "SPEAKHUD_QUEUE_DIR"
    static var dir: String {
        let override = ProcessInfo.processInfo.environment[dirEnv] ?? ""
        return NSString(string: override.isEmpty ? "~/.local/state/speakhud/queue" : override)
            .expandingTildeInPath
    }

    enum DropReason: Equatable, CustomStringConvertible {
        case malformed        // unreadable, or not a JSON object
        case emptyText        // text missing, not a string, or only whitespace
        case invalidCreated   // created present but not a number
        case tooOld           // waited longer than maxAge
        case staleTmp         // a hook died between writing and renaming
        case unsupportedVersion  // `v` present but not the version this agent reads

        var description: String {
            switch self {
            case .unsupportedVersion: return "unsupported schema version (this agent reads v\(Spool.version)) — update SpeakHUD"
            case .malformed: return "malformed JSON"
            case .emptyText: return "no text"
            case .invalidCreated: return "created is not a number"
            case .tooOld: return "older than \(Int(Spool.maxAge))s"
            case .staleTmp: return "abandoned .tmp"
            }
        }
    }
    struct Drop: Equatable { let name: String; let reason: DropReason }
    struct Batch { var items: [SpeechItem] = []; var dropped: [Drop] = [] }

    static func ensure(_ dir: String = Spool.dir) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    /// Items a previous agent had picked up but never finished speaking — it was
    /// restarted or crashed mid-queue. Hand them back so they get another turn.
    static func recover(in dir: String = Spool.dir) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in names where name.hasSuffix(".taken") {
            let stem = String(name.dropLast(6))
            try? fm.moveItem(atPath: dir + "/" + name, toPath: dir + "/" + stem + ".json")
        }
    }

    /// Take every queued item, in arrival order. A taken item is renamed rather than
    /// deleted, so it still exists on disk until it has actually been spoken; `done()`
    /// is what finally removes it. Also sweeps `.tmp` files older than maxAge: a hook
    /// killed between open and rename leaves one, and nothing else ever would.
    static func drain(in dir: String = Spool.dir, now: Date = Date()) -> Batch {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return Batch() }
        var batch = Batch()
        func mtime(_ path: String) -> Date? {
            (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        for name in names where name.hasSuffix(".tmp") {
            let path = dir + "/" + name
            // Young ones are a hook mid-write; leave those alone.
            guard let m = mtime(path), now.timeIntervalSince(m) >= maxAge,
                  (try? fm.removeItem(atPath: path)) != nil else { continue }
            batch.dropped.append(Drop(name: name, reason: .staleTmp))
        }
        for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let stem = String(name.dropLast(5))
            let taken = dir + "/" + stem + ".taken"
            // Claim it atomically; if the rename loses, someone else has it.
            guard (try? fm.moveItem(atPath: dir + "/" + name, toPath: taken)) != nil else { continue }
            func drop(_ reason: DropReason) {   // don't wedge the queue on a bad item
                done(taken)
                batch.dropped.append(Drop(name: name, reason: reason))
            }
            guard let data = fm.contents(atPath: taken),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { drop(.malformed); continue }
            // Before any field is read: a newer schema may have moved them all.
            if let raw = obj["v"] {
                guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue == Double(version)
                else { drop(.unsupportedVersion); continue }
            }
            guard let text = obj["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { drop(.emptyText); continue }
            let created: Date
            if let raw = obj["created"] {
                // JSON booleans also bridge to NSNumber; they aren't timestamps.
                guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue.isFinite
                else { drop(.invalidCreated); continue }
                created = Date(timeIntervalSince1970: n.doubleValue)
            } else {
                // Rename keeps mtime, so this is when the producer wrote the file.
                created = mtime(taken) ?? now
            }
            guard now.timeIntervalSince(created) < maxAge else { drop(.tooOld); continue }
            let source = obj["source"] as? String ?? ""
            let key = obj["key"] as? String ?? ""
            batch.items.append(SpeechItem(text: text,
                                          source: source.isEmpty ? "Claude Code" : source,
                                          key: key.isEmpty ? stem : key,
                                          created: created,
                                          file: taken))
        }
        return batch
    }

    /// "The agent is alive and draining": touch the heartbeat's mtime. Only its first
    /// write creates a directory entry; after that it's a pure mtime change, which the
    /// spool's directory watcher doesn't see, so beating never triggers a drain.
    @discardableResult
    static func beat(in dir: String = Spool.dir, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        let path = dir + "/" + heartbeatName
        // The dir can be removed from under a live agent; the hook only recreates it when
        // it queues, which it won't do while the heartbeat is missing. So bring it back here.
        if !fm.fileExists(atPath: dir) { ensure(dir) }
        if !fm.fileExists(atPath: path), !fm.createFile(atPath: path, contents: nil) { return false }
        return (try? fm.setAttributes([.modificationDate: now], ofItemAtPath: path)) != nil
    }

    /// This item will never be spoken again — finished, skipped, stopped, or superseded.
    static func done(_ path: String?) {
        guard let path = path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}

// ---------------------------------------------------------------------------
// Reading the text you've highlighted in whatever app is frontmost.
// ---------------------------------------------------------------------------

enum Selection {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "grant Accessibility" prompt. Returns true if already trusted.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Selected text from the frontmost app, or nil if there is none (or we're untrusted).
    static func current() -> String? {
        guard isTrusted else { return nil }
        return viaAccessibility() ?? viaSynthesizedCopy()
    }

    /// The clean path: ask the focused UI element for its selection. Doesn't touch
    /// the clipboard, but plenty of apps (Chrome, some terminals) don't implement it.
    private static func viaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)   // never hang on a wedged app
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID()
        else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(f as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let s = selected as? String
        else { return nil }
        return nonEmpty(s)
    }

    /// The fallback: press ⌘C for the user and put their clipboard back afterwards.
    private static func viaSynthesizedCopy() -> String? {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        else { return nil }
        // Set flags explicitly: the user is still holding the trigger hotkey's modifiers,
        // and we must not deliver ⌃⌥⌘C to the target app.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        // Nothing selected means ⌘C is a no-op and changeCount never moves.
        var waitedMs = 0
        while pb.changeCount == before && waitedMs < 300 { usleep(10_000); waitedMs += 10 }
        guard pb.changeCount != before else { return nil }

        let copied = pb.string(forType: .string)
        restore(saved, to: pb)
        return copied.flatMap(nonEmpty)
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { types[t] = item.data(forType: t) }
            return types
        }
    }

    private static func restore(_ snap: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        let items = snap.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, data) in types { item.setData(data, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}

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
@available(macOS 14.0, *)
final class MicWatch {
    private(set) var busy = false
    private let onChange: (Bool) -> Void
    private var inputDevice = AudioObjectID(kAudioObjectUnknown)
    private var trigger: AudioObjectPropertyListenerBlock!
    private var deviceChanged: AudioObjectPropertyListenerBlock!
    private let system = AudioObjectID(kAudioObjectSystemObject)

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        trigger = { [weak self] _, _ in self?.recheck() }
        deviceChanged = { [weak self] _, _ in self?.followDefaultInput() }
        var list = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(system, &list, .main, trigger)
        var def = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(system, &def, .main, deviceChanged)
        followDefaultInput()
    }

    private static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
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
        var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return }
        let me = getpid()
        let now = ids.contains { id in
            let pid: Int32? = Self.read(id, kAudioProcessPropertyPID)
            let running: UInt32? = Self.read(id, kAudioProcessPropertyIsRunningInput)
            return pid != me && (running ?? 0) != 0
        }
        guard now != busy else { return }
        busy = now
        onChange(now)
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

// ---------------------------------------------------------------------------
// Global hotkeys. One Carbon handler for the whole process, dispatching on the
// hotkey id — installing a handler per feature would fire all of them on any key.
// ---------------------------------------------------------------------------

enum HotKeyAction: UInt32 { case read = 1, togglePause = 2, toggleHUD = 3 }

final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private static let signature = OSType(0x53504b48)   // 'SPKH'
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event = event else { return noErr }
            var id = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id)
            if err == noErr { HotKeyCenter.shared.handlers[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    func register(_ action: HotKeyAction, keyCode: UInt32, mods: UInt32,
                  handler: @escaping () -> Void) -> Bool {
        installHandler()
        unregister(action)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        guard RegisterEventHotKey(keyCode, mods, id, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref = ref else { return false }
        refs[action.rawValue] = ref
        handlers[action.rawValue] = handler
        return true
    }

    func unregister(_ action: HotKeyAction) {
        if let ref = refs.removeValue(forKey: action.rawValue) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: action.rawValue)
    }
}

// ---------------------------------------------------------------------------
// Source identity: a stable color per project, so four terminals are four
// colors you learn rather than four names you have to read.
// ---------------------------------------------------------------------------

enum Accent {
    // Yellow and red are omitted: one is illegible, the other reads as an error.
    private static let palette: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple,
        .systemTeal, .systemPink, .systemIndigo, .systemBrown,
    ]
    /// djb2 rather than Swift's `hashValue`, whose seed is randomized per process —
    /// a project would otherwise change color every time the agent restarted.
    static func color(for source: String) -> NSColor {
        var h: UInt64 = 5381
        for byte in source.utf8 { h = (h &* 33) &+ UInt64(byte) }
        return palette[Int(h % UInt64(palette.count))]
    }
}

/// A colored pill naming whoever is speaking.
final class SourceBadge: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var accent: NSColor = .systemBlue { didSet { needsDisplay = true } }

    private static let dot: CGFloat = 7
    private static let padX: CGFloat = 11
    private static let gap: CGFloat = 7
    private static let maxWidth: CGFloat = 260
    static let height: CGFloat = 24

    private var textAttrs: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail   // long repo names shouldn't stretch the pill
        return [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: accent,
                .paragraphStyle: p]
    }

    override var intrinsicContentSize: NSSize {
        let w = (text as NSString).size(withAttributes: textAttrs).width
        return NSSize(width: min(ceil(w) + Self.padX * 2 + Self.dot + Self.gap, Self.maxWidth),
                      height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let pill = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: r.height / 2, yRadius: r.height / 2)
        accent.withAlphaComponent(0.18).setFill(); pill.fill()
        accent.withAlphaComponent(0.5).setStroke(); pill.lineWidth = 1; pill.stroke()

        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: Self.padX, y: (r.height - Self.dot) / 2,
                                    width: Self.dot, height: Self.dot)).fill()

        let attrs = textAttrs
        let s = text as NSString
        let th = s.size(withAttributes: attrs).height
        let x = Self.padX + Self.dot + Self.gap
        s.draw(in: NSRect(x: x, y: (r.height - th) / 2, width: r.width - x - Self.padX, height: th),
               withAttributes: attrs)
    }
}

/// SpeakHUD runs as an accessory app: no Dock icon, and no menu bar to own an Edit
/// menu. ⌘C is normally delivered *by* that menu, so without one a selection in the
/// transcript looks copyable but silently isn't. Route the few editing keys the panel
/// needs straight into the responder chain instead.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // …or it never sees a keystroke at all

    /// The panel is deliberately non-activating, so it can appear mid-sentence without
    /// stealing focus from whatever you're typing in. The cost is that an inactive app
    /// receives no keyboard input at all — which is why selecting text and pressing ⌘C
    /// did nothing. Clicking the HUD is an unambiguous "I want to use this", so take
    /// focus at that point, and only then.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !NSApp.isActive {
            focusDonor = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
        }
        super.sendEvent(event)
    }

    /// Whoever we took focus from. NSApp.deactivate() alone just leaves this app
    /// frontmost with no windows, so the app has to be reactivated by name.
    private var focusDonor: NSRunningApplication?

    func returnFocus() {
        guard NSApp.isActive, let donor = focusDonor,
              donor.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        donor.activate(options: [])
        focusDonor = nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector?
        switch key {
        case "c": action = #selector(NSText.copy(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        default:  action = nil
        }
        if let action = action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// ---------------------------------------------------------------------------
// Playback: every decision about what speaks, when, and from where. The queue,
// whose pause it is (yours or the mic's), the resume point, the speed. No AppKit
// and no AVFoundation — it drives a `Voice` and publishes one `State` for the HUD
// to render, so the rules run in tests against a fake voice.
// ---------------------------------------------------------------------------

/// What Playback needs from a speech engine. Offsets are UTF-16 positions in the
/// full item text. Progress and finishes come back tagged with the `utterance` they
/// belong to, so anything from an utterance Playback has since dropped is stale.
protocol Voice: AnyObject {
    /// Say `text` from `offset` at `rate`, replacing whatever was going.
    func speak(_ text: String, from offset: Int, rate: Float, utterance: Int)
    /// Hold mid-utterance: `immediately` cuts off mid-word (the mic is opening);
    /// otherwise at the next word boundary.
    func pause(immediately: Bool)
    func resume()
    /// Silence and forget the current utterance. Never reported back as finished.
    func stop()
}

final class Playback {
    /// Everything the HUD shows about playback, derived in one place so no label can
    /// drift from another.
    struct State: Equatable {
        var status = ""
        var pauseTitle = "❚❚ Pause"
        var speedTitle = ""
        var queued: [String] = []   // sources waiting behind the current item, in order
        var isActive = false        // something is current or waiting: don't auto-hide
        var canSkip = false
    }

    // macOS default rate (0.5) == 1×; the steps scale around it.
    static let rateSteps: [Float] = [0.375, 0.5, 0.625, 0.75, 0.875, 1.0]
    static let rateLabels = ["0.75×", "1×", "1.25×", "1.5×", "1.75×", "2×"]

    private(set) var current: SpeechItem?
    private(set) var queue: [SpeechItem] = []
    private(set) var rateIndex: Int
    private(set) var state = State()

    var onChange: (State) -> Void = { _ in }
    /// A new item became current: show its text.
    var onStart: (SpeechItem) -> Void = { _ in }
    /// The word being spoken, in full-text coordinates.
    var onWord: (NSRange) -> Void = { _ in }
    var onRanDry: () -> Void = {}
    var onStopped: () -> Void = {}
    var log: (String) -> Void = { _ in }

    private let voice: Voice
    private let retire: (SpeechItem) -> Void
    private let now: () -> Date

    private enum Sound { case silent, speaking, paused }
    /// What the voice is doing. Only Playback's own calls change it — never read back
    /// from the engine, whose idea of "speaking" lags and lies around stops.
    private var sound = Sound.silent
    private var utterance = 0      // id of the last utterance handed to the voice
    private var resumeAt = 0       // start of the word being spoken: where a restart picks up
    private var userPaused = false // yours; the mic never clears it
    private var micBusy = false
    private var lastItem: SpeechItem?   // what Replay replays once the queue has run dry
    private var stopped = false    // the HUD was emptied by Stop, not by running dry
    private var startedAt = Date()

    /// `retire` releases an item that will never be spoken again (its spool file).
    /// `later` runs work after the current event is done; tests run it inline.
    init(voice: Voice, rateIndex: Int = 1,
         retire: @escaping (SpeechItem) -> Void = { Spool.done($0.file) },
         now: @escaping () -> Date = Date.init,
         later: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.voice = voice
        self.later = later
        self.rateIndex = Self.rateSteps.indices.contains(rateIndex) ? rateIndex : 1
        self.retire = retire
        self.now = now
        state = makeState()
    }

    // -- commands ----------------------------------------------------------

    /// Wait your turn. A second turn from the same session replaces the first one
    /// still waiting in line — you want the latest answer, not a stale one.
    /// Returns true only if this item is now actually being spoken.
    @discardableResult
    func enqueue(_ item: SpeechItem) -> Bool {
        if let i = queue.firstIndex(where: { $0.key == item.key }) {
            retire(queue[i])  // the stale turn is never spoken; let go of its file
            queue[i] = item   // keep its place in line; a chatty session shouldn't jump the queue
        } else {
            queue.append(item)
        }
        // Nothing current means the queue was empty: this item becomes current, and
        // sounds unless the mic or your pause is holding us.
        let wasIdle = current == nil
        if wasIdle { advance() }
        publish()
        return wasIdle && sound == .speaking
    }

    /// Jump the queue: you highlighted that text and asked for it now. It becomes
    /// current even while the mic is busy (so you can see it), but waits to be heard.
    func playNow(_ item: SpeechItem) {
        if let c = current {
            silence()
            // A spool-backed turn was interrupted, not finished — put it back at the head
            // of the queue and keep its file, or a hotkey read silently destroys a Claude
            // response mid-sentence. Two exceptions retire it instead: an ad-hoc read
            // (no spool file) is superseded by the one you just asked for, and a session
            // with a newer turn already waiting follows "newest per session wins".
            if c.file != nil, !queue.contains(where: { $0.key == c.key }) {
                log("preempted \(c.source) — requeued")
                queue.insert(c, at: 0)
            } else {
                log("preempted \(c.source)")
                retire(c)
            }
            current = nil
        }
        userPaused = false   // asking for something now is not asking for silence
        start(item)
        publish()
    }

    /// Drop the current item and move on. Clears your pause: skipping is asking for
    /// the next one. The mic still holds it.
    func skip() {
        guard let c = current else { return }
        log("skipped \(c.source)")
        retire(c)
        silence()
        lastItem = c
        current = nil
        userPaused = false
        advance()
        publish()
    }

    /// Stop everything and throw the queue away. "Skip" is the one that moves on.
    func stop() {
        silence()
        log("stop: discarded \(queue.count) queued item(s)")
        if let c = current { retire(c); lastItem = c }
        queue.forEach(retire)
        queue.removeAll()
        current = nil
        userPaused = false
        stopped = true
        publish()
        onStopped()
    }

    /// Pause or resume. Also works while an item is waiting on the mic: a pause made
    /// then is kept when the mic frees up. Resuming while the mic is busy hands the
    /// hold back to the mic, which resumes on release.
    func togglePause() {
        guard current != nil || !queue.isEmpty else { return }
        userPaused.toggle()
        proceed()
        publish()
    }

    /// Cycle the speed. AVSpeech can't change rate mid-utterance, so a live utterance
    /// is dropped and restarted from the current word — immediately if we're sounding,
    /// otherwise on the next resume. Never un-pauses.
    func cycleSpeed() {
        rateIndex = (rateIndex + 1) % Self.rateSteps.count
        silence()
        drive()
        publish()
    }

    /// From the top. Like Speed, it doesn't un-pause. Once the queue has run dry it
    /// brings the last item back as current (without its spool file, which is gone),
    /// so a turn arriving meanwhile queues behind it instead of cutting it off.
    func replay() {
        if current == nil {
            guard var last = lastItem else { return }
            last.file = nil
            start(last)
        } else {
            silence()
            resumeAt = 0
            drive()
        }
        publish()
    }

    /// Something else is (or stopped) recording. Mid-speech this pauses on the spot
    /// and resumes on release; nothing new starts while it's busy. Debouncing the
    /// release is the caller's job.
    func micChanged(busy: Bool) {
        guard busy != micBusy else { return }
        micBusy = busy
        log(busy ? "mic in use — holding speech" : "mic released")
        proceed()
        publish()
    }

    // -- from the voice ----------------------------------------------------

    func voiceSpoke(_ range: NSRange, utterance id: Int) {
        guard id == utterance, sound != .silent else { return }
        resumeAt = range.location
        onWord(range)
    }

    /// A stale finish (a dropped utterance) is ignored, so a stop can never advance
    /// the queue a second time. Called from inside the synth's delegate callback: the
    /// finish is recorded now, so a command arriving before the hop sees the item as
    /// done (a hotkey read won't requeue it, Speed won't repeat its last word), but
    /// starting the next item — which hands the voice a new utterance — waits for
    /// `later`, because re-entering the synth from its own callback can drop audio.
    func voiceFinished(utterance id: Int) {
        guard id == utterance, sound != .silent, let c = current else { return }
        sound = .silent
        log(String(format: "finish %@ after %.1fs", c.source, now().timeIntervalSince(startedAt)))
        retire(c)
        lastItem = c
        current = nil
        publish()
        later { [weak self] in
            guard let self = self, self.current == nil else { return }  // something started meanwhile
            self.advance()
            self.publish()
        }
    }

    // -- policy ------------------------------------------------------------

    private let later: (@escaping () -> Void) -> Void
    private var canSound: Bool { !userPaused && !micBusy }

    /// Something that was holding us let go (or took hold): act on it.
    private func proceed() {
        if current != nil { drive() } else if !queue.isEmpty { advance() }
    }

    /// Nothing is current. Make the next item current even if something is holding
    /// us: the HUD shows what's up next, and drive() keeps it silent until we can sound.
    private func advance() {
        if queue.isEmpty {
            userPaused = false
            stopped = false
            onRanDry()
        } else {
            start(queue.removeFirst())
        }
    }

    private func start(_ item: SpeechItem) {
        current = item
        resumeAt = 0
        stopped = false
        startedAt = now()
        log("start \(item.source) (\(item.text.count) chars)")
        onStart(item)
        drive()
    }

    /// Make the voice match the policy.
    private func drive() {
        guard let c = current else { return }
        if canSound {
            switch sound {
            case .silent:
                utterance += 1
                sound = .speaking
                voice.speak(c.text, from: resumeAt, rate: Self.rateSteps[rateIndex], utterance: utterance)
            case .paused:
                sound = .speaking
                voice.resume()
            case .speaking:
                break
            }
        } else if sound == .speaking {
            sound = .paused
            // A synth that's spoken one more syllable has already been heard by the mic.
            voice.pause(immediately: micBusy)
        }
    }

    private func silence() {
        guard sound != .silent else { return }
        sound = .silent
        voice.stop()
    }

    private func publish() {
        state = makeState()
        onChange(state)
    }

    private func makeState() -> State {
        var s = State()
        s.queued = queue.map(\.source)
        s.isActive = current != nil || !queue.isEmpty
        s.canSkip = current != nil && !queue.isEmpty
        s.speedTitle = "⏩ \(Self.rateLabels[rateIndex])"
        s.pauseTitle = userPaused ? "▶ Resume" : "❚❚ Pause"
        if !s.isActive {
            s.status = stopped ? "■ Stopped" : (lastItem == nil ? "" : "Done")
        } else if userPaused {
            s.status = "⏸ Paused"
        } else if micBusy {
            s.status = sound == .paused ? "🎙 Mic in use — paused" : "🎙 Mic in use — waiting"
        } else {
            s.status = "🔊 Speaking…  \(Self.rateLabels[rateIndex])"
        }
        return s
    }
}

/// The app's voice: AVSpeechSynthesizer behind the `Voice` seam.
final class SpeechVoice: NSObject, Voice, AVSpeechSynthesizerDelegate {
    weak var listener: Playback?

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

// ---------------------------------------------------------------------------
// The HUD: renders Playback's state and wires the buttons, hotkeys and mic to it.
// ---------------------------------------------------------------------------

final class Controller: NSObject, NSWindowDelegate {
    let playback: Playback
    var queue: [SpeechItem] { playback.queue }

    /// Standalone reader exits; the agent just hides the panel and keeps listening.
    var onIdle: () -> Void = { NSApp.terminate(nil) }
    /// Where queue transitions go. The agent points this at its log file.
    var log: (String) -> Void = { _ in }

    var panel: HUDPanel!
    var statusLabel: NSTextField!
    var queueLabel: NSTextField!
    var sourceBadge: SourceBadge!
    var nextLabel: NSTextField!
    var pauseBtn: NSButton!
    var speedBtn: NSButton!
    var skipBtn: NSButton!
    var textView: NSTextView!
    var hideBtn: NSButton!
    var closeTimer: Timer?

    /// How long the panel sits there after the queue runs dry. Measured from your last
    /// interaction, not from when speech ended.
    var idleHideDelay: TimeInterval = 15
    /// Last click, scroll, or keypress aimed at the panel. An auto-hide that fires while
    /// you're mid-scroll is the whole "it vanished on me" complaint.
    private var lastInteraction = Date.distantPast
    private var interactionMonitor: Any?
    /// The user put the HUD away. Sticky for the life of the agent, so a chatty session
    /// can't keep shoving the panel back in front of them. Not persisted on purpose:
    /// a hidden-forever HUD across restarts just looks like a broken app.
    private(set) var isMinimized = false
    /// Footer text. The agent appends the hotkeys it actually managed to register.
    var hotkeyHint = "Pause / Resume anywhere:  ⌃⌥P"

    static let rateKey = "speakRateIndex"   // UserDefaults key for persisted speed

    // Mic hold: something else is recording, so we're silent until it stops.
    private var micWatch: AnyObject?
    private var micHold: MicHold!

    /// "Pause While Recording". Off releases any hold now; on while something's
    /// recording holds now. Persisted in the shared suite.
    var pauseWhileRecording: Bool {
        get { micHold.enabled }
        set {
            micHold.setEnabled(newValue)
            MicHold.store(newValue, in: prefs)
            log("pause while recording: \(newValue ? "on" : "off")")
        }
    }

    override init() {
        let voice = SpeechVoice()
        playback = Playback(voice: voice, rateIndex: Self.initialRateIndex())
        voice.listener = playback
        super.init()
        micHold = MicHold(enabled: MicHold.storedEnabled(in: prefs)) { [weak self] busy in
            self?.playback.micChanged(busy: busy)
        }
        playback.log = { [weak self] in self?.log($0) }
        playback.onChange = { [weak self] in self?.render($0) }
        playback.onStart = { [weak self] in self?.show($0) }
        playback.onWord = { [weak self] in self?.highlight($0) }
        playback.onRanDry = { [weak self] in
            guard let self = self else { return }
            self.clearHighlight()
            self.scheduleAutoClose(after: self.idleHideDelay)
        }
        playback.onStopped = { [weak self] in
            self?.closeTimer?.invalidate()
            self?.clearHighlight()
            self?.onIdle()
        }
    }

    /// The last speed the user picked, unless an explicit SPEAK_RATE env wins for
    /// this invocation.
    private static func initialRateIndex() -> Int {
        var index = 1
        if let saved = prefs.object(forKey: rateKey) as? Int,
           Playback.rateSteps.indices.contains(saved) {
            index = saved
        }
        if let r = ProcessInfo.processInfo.environment["SPEAK_RATE"], let f = Float(r), f > 0 {
            index = Playback.rateSteps.enumerated().min(by: { abs($0.1 - f) < abs($1.1 - f) })!.0
        }
        return index
    }

    // -- commands ----------------------------------------------------------

    /// Returns true only if the item started speaking straight away.
    @discardableResult
    func enqueue(_ item: SpeechItem) -> Bool { playback.enqueue(item) }

    /// Jump the queue. Used for hotkey reads.
    func playNow(_ item: SpeechItem) { playback.playNow(item) }

    @objc func skip() { playback.skip() }
    @objc func replay() { playback.replay() }
    @objc func togglePause() { playback.togglePause() }

    @objc func changeSpeed() {
        playback.cycleSpeed()
        prefs.set(playback.rateIndex, forKey: Self.rateKey)   // remember it
    }

    /// Stop everything and throw the queue away. Note this discards what's waiting —
    /// "Skip" is the one that moves on to the next item.
    @objc func stopAll() { playback.stop() }

    /// Start listening for other apps recording. Silently a no-op before macOS 14.
    func watchMic() {
        guard micWatch == nil, #available(macOS 14.0, *) else { return }
        micWatch = MicWatch { [weak self] busy in self?.micChanged(busy) }
    }

    /// The setting and the release debounce live in MicHold.
    private func micChanged(_ busy: Bool) { micHold.recordingChanged(busy) }

    // -- rendering ---------------------------------------------------------

    /// A new item is current: put its text up. Content is kept current even while
    /// hidden, so restoring shows the real state rather than whatever was on screen
    /// when it was put away.
    private func show(_ item: SpeechItem) {
        closeTimer?.invalidate()
        buildWindowIfNeeded()
        setTranscript(item.text)
        sourceBadge.text = item.source
        sourceBadge.accent = Accent.color(for: item.source)
        sourceBadge.setFrameSize(sourceBadge.intrinsicContentSize)
        if !isMinimized { panel.orderFrontRegardless() }
        onVisibilityChange()
    }

    /// The only place the playback labels and buttons are written.
    private func render(_ s: Playback.State) {
        guard panel != nil else { return }
        statusLabel.stringValue = s.status
        pauseBtn.title = s.pauseTitle
        speedBtn.title = s.speedTitle
        queueLabel.stringValue = s.queued.isEmpty ? "" : "▸ \(s.queued.count) queued"
        nextLabel.attributedStringValue = queuePreview(s.queued)
        skipBtn.isEnabled = s.canSkip
    }

    /// "next: Alpha, Beta", each name in its project's color.
    private func queuePreview(_ sources: [String]) -> NSAttributedString {
        guard !sources.isEmpty else { return NSAttributedString(string: "") }
        let dim: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let out = NSMutableAttributedString(string: "next: ", attributes: dim)
        for (i, source) in sources.prefix(3).enumerated() {
            if i > 0 { out.append(NSAttributedString(string: ", ", attributes: dim)) }
            out.append(NSAttributedString(string: source, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: Accent.color(for: source),
            ]))
        }
        if sources.count > 3 { out.append(NSAttributedString(string: "…", attributes: dim)) }
        return out
    }

    /// Transient hide: stopped, or the standalone reader running dry. Distinct from
    /// minimizing — the next thing to speak brings the panel back.
    /// Clicking the HUD takes focus so ⌘C can work; hand it back on the way out, or the
    /// next thing you type goes to an app with no windows left to receive it.
    private func yieldFocus() {
        panel?.returnFocus()
    }

    func hidePanel() {
        closeTimer?.invalidate()
        panel?.orderOut(nil)
        yieldFocus()
        onVisibilityChange()
    }

    /// Put the HUD away and keep it away. Speech carries on; only the panel goes.
    @objc func minimize() {
        guard !isMinimized else { return }
        isMinimized = true
        closeTimer?.invalidate()
        panel?.orderOut(nil)
        yieldFocus()
        log("hud hidden")
        onVisibilityChange()
    }

    /// Bring it back. No-op before anything has ever been spoken — there'd be nothing
    /// in the panel to look at. Brought back with nothing playing (after Stop, or once
    /// the queue ran dry), it auto-hides like any idle panel.
    func restore() {
        isMinimized = false
        guard panel != nil else { onVisibilityChange(); return }
        closeTimer?.invalidate()
        panel.orderFrontRegardless()
        log("hud shown")
        if !playback.state.isActive { scheduleAutoClose(after: idleHideDelay) }
        onVisibilityChange()
    }

    /// Stop also leaves the panel off-screen, so "is it up right now" is the honest
    /// question to toggle on — not whether the user pressed Hide.
    var isPanelVisible: Bool { panel?.isVisible == true }

    @objc func toggleMinimized() { isPanelVisible ? minimize() : restore() }

    /// Lets the menu bar mirror whether the panel is currently up.
    var onVisibilityChange: () -> Void = {}

    // Karaoke-style follow: highlight + scroll to the word currently being spoken.
    private func highlight(_ range: NSRange) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        if NSMaxRange(range) <= storage.length {
            storage.addAttribute(.backgroundColor, value: NSColor.findHighlightColor, range: range)
            scrollToSpokenWord(range, in: tv)
        }
    }

    /// Keep the spoken word in view with room to spare.
    ///
    /// `scrollRangeToVisible` alone isn't enough for two reasons: it scrolls the minimum
    /// distance, so the word ends up jammed against the bottom edge (often half-clipped,
    /// which reads as "it stopped following"), and glyphs are laid out lazily — on a long
    /// response the line may have no layout yet, so the rect comes back wrong and the
    /// view doesn't move at all.
    private func scrollToSpokenWord(_ range: NSRange, in tv: NSTextView) {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else {
            tv.scrollRangeToVisible(range)
            return
        }
        lm.ensureLayout(forCharacterRange: range)
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        rect.origin.x += tv.textContainerInset.width
        rect.origin.y += tv.textContainerInset.height
        // A couple of lines of context either side, so you can read ahead of the voice.
        tv.scrollToVisible(rect.insetBy(dx: 0, dy: -44))
    }

    // Detection is cheap, but the detector isn't — build it once, not per response.
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Show a response. Leading and paragraph spacing do most of the readability work —
    /// a wall of tightly-set 12pt is hard to find your place in when the highlight is
    /// moving. Attributes go on before `linkify()`, which would otherwise be wiped by
    /// the blanket `addAttributes` here.
    private func setTranscript(_ text: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        tv.string = text
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        // No paragraphSpacing: the text already carries a blank line between paragraphs,
        // and adding both doubles every gap and wastes the window.
        style.paragraphSpacing = 0
        storage.addAttributes([
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ], range: NSRange(location: 0, length: storage.length))
        linkify()
    }

    /// Mark URLs in the transcript as real links. Only `.link` is added, so the karaoke
    /// highlight (which only ever touches `.backgroundColor`) can't wipe them out.
    private func linkify() {
        guard let storage = textView?.textStorage, let detector = Self.linkDetector else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.link, range: full)
        detector.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match = match, let url = match.url else { return }
            storage.addAttribute(.link, value: url, range: match.range)
        }
    }

    /// Clicks, scrolls, and keystrokes aimed at the panel, so the auto-hide can tell
    /// "finished speaking a while ago" from "they're still reading it".
    private func watchInteraction() {
        interactionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            guard let self = self else { return event }
            if event.window === self.panel { self.lastInteraction = Date() }
            return event
        }
    }

    deinit {
        if let m = interactionMonitor { NSEvent.removeMonitor(m) }
    }

    private func clearHighlight() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
    }

    /// Hide once it's been quiet for `seconds` — counted from your last interaction, not
    /// from when speech stopped. Scrolling, selecting, or clicking a link keeps it up;
    /// so does anything still current or waiting (paused, or held by the mic).
    private func scheduleAutoClose(after seconds: TimeInterval) {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.playback.state.isActive { self.scheduleAutoClose(after: seconds); return }
            let quiet = Date().timeIntervalSince(self.lastInteraction)
            guard quiet >= seconds else {
                self.scheduleAutoClose(after: seconds - quiet)   // still being used
                return
            }
            self.onIdle()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        stopAll()
        return false   // stopAll already hid (or terminated) us
    }

    /// The title bar is transparent but still there, so the green button — or a
    /// double-click anywhere along the top — zooms the panel to fill the screen. The
    /// panel then keeps that frame for the life of the agent, and every later read
    /// reopens as a full-screen HUD. Resizing by the edges is fine; zooming never is.
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { false }

    // -- window ------------------------------------------------------------

    func buildWindowIfNeeded() {
        guard panel == nil else { return }
        let w: CGFloat = 500, h: CGFloat = 330
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.minSize = NSSize(width: w, height: 260)   // narrower than this clips the button row
        panel.standardWindowButton(.zoomButton)?.isHidden = true   // zoom is refused; don't advertise it
        panel.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // Who's talking — the loudest thing in the window, because with several
        // terminals queued it's the first thing you need to know. Indented past the
        // traffic lights, which float over this content view (.fullSizeContentView).
        let badge = SourceBadge(frame: NSRect(x: 80, y: h - 34, width: 140, height: SourceBadge.height))
        badge.autoresizingMask = [.minYMargin]
        content.addSubview(badge)
        sourceBadge = badge

        let queued = NSTextField(labelWithString: "")
        queued.frame = NSRect(x: w - 166, y: h - 31, width: 150, height: 18)
        queued.alignment = .right
        queued.font = .systemFont(ofSize: 11, weight: .medium)
        queued.textColor = .secondaryLabelColor
        queued.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(queued)
        queueLabel = queued

        // Playback state, demoted below the source.
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 18, y: h - 58, width: w - 36, height: 18)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.autoresizingMask = [.width, .minYMargin]
        content.addSubview(label)
        statusLabel = label

        // Full response text — scrollable, auto-follows speech (fills the middle)
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 96, width: w - 32, height: h - 162))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 12)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        // Clicking a detected link hands it to NSWorkspace, i.e. your default browser.
        tv.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        scroll.documentView = tv
        content.addSubview(scroll)
        textView = tv

        // What's waiting behind the current item
        let next = NSTextField(labelWithString: "")
        next.frame = NSRect(x: 16, y: 76, width: w - 32, height: 14)
        next.font = .systemFont(ofSize: 10)
        next.textColor = .tertiaryLabelColor
        next.lineBreakMode = .byTruncatingTail
        next.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(next)
        nextLabel = next

        // Hotkey hint (above buttons, pinned to bottom)
        let hint = NSTextField(labelWithString: hotkeyHint)
        hint.frame = NSRect(x: 16, y: 58, width: w - 32, height: 14)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(hint)

        // Buttons (pinned to bottom)
        func button(_ title: String, _ x: CGFloat, _ width: CGFloat, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.frame = NSRect(x: x, y: 16, width: width, height: 26)
            b.bezelStyle = .rounded
            b.autoresizingMask = [.maxYMargin]
            return b
        }
        content.addSubview(button("↻ Replay", 14, 78, #selector(replay)))
        // Titles and enabled state come from render(), the one writer.
        pauseBtn = button("", 96, 86, #selector(togglePause))
        content.addSubview(pauseBtn)
        speedBtn = button("", 186, 70, #selector(changeSpeed))
        content.addSubview(speedBtn)
        skipBtn = button("⏭ Skip", 260, 66, #selector(skip))
        content.addSubview(skipBtn)
        content.addSubview(button("■ Stop", 330, 66, #selector(stopAll)))
        // Hide, not Stop: the panel goes away, the speech keeps going, and the
        // menu-bar item brings it back.
        hideBtn = button("⌄ Hide", 400, 86, #selector(minimize))
        content.addSubview(hideBtn)

        panel.contentView = content

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.maxX - w - 20, y: vf.maxY - h - 20))
        }
        self.panel = panel
        render(playback.state)
        watchInteraction()
    }
}

// ---------------------------------------------------------------------------
// Global hotkey + background agent (read the selection from anywhere)
// ---------------------------------------------------------------------------

// Stored at ~/.config/speakhud/config.json so you can set your own combo.
// Set SPEAKHUD_CONFIG_DIR to point at a different dir (used by tests).
enum HotkeyConfig {
    static let defaultSpec = "ctrl+opt+s"
    static let dirEnv = "SPEAKHUD_CONFIG_DIR"
    static var dir: String {
        if let d = ProcessInfo.processInfo.environment[dirEnv], !d.isEmpty {
            return NSString(string: d).expandingTildeInPath
        }
        return NSString(string: "~/.config/speakhud").expandingTildeInPath
    }
    static var path: String { dir + "/config.json" }

    /// The combo to use, and why it isn't yours when the file is broken. A missing file
    /// is not a problem (you just haven't picked one); anything unusable in a file that
    /// exists is, because otherwise your edit is silently ignored.
    struct Loaded: Equatable {
        let spec: String
        let problem: String?
    }

    static func load() -> Loaded {
        let fallback = { (why: String) in Loaded(spec: defaultSpec, problem: why) }
        guard FileManager.default.fileExists(atPath: path) else { return Loaded(spec: defaultSpec, problem: nil) }
        guard let data = FileManager.default.contents(atPath: path) else { return fallback("can't be read") }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return fallback("isn't valid JSON") }
        guard let obj = json as? [String: Any] else { return fallback("isn't a JSON object") }
        guard let value = obj["hotkey"] else { return fallback("has no \"hotkey\" setting") }
        guard let hk = (value as? String)?.trimmingCharacters(in: .whitespaces), !hk.isEmpty else {
            return fallback("\"hotkey\" isn't a non-empty string")
        }
        guard parseHotkey(hk) != nil else {
            return fallback("hotkey \"\(hk)\" isn't a valid combo (need ≥1 modifier + a key)")
        }
        return Loaded(spec: hk, problem: nil)
    }

    @discardableResult
    static func save(_ spec: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let json = "{\n  \"hotkey\": \"\(spec)\"\n}\n"
        return (try? json.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    /// Write the default only if there's no file yet — never over one you're editing,
    /// broken or not.
    @discardableResult
    static func ensureFile() -> Bool {
        FileManager.default.fileExists(atPath: path) || save(defaultSpec)
    }

    /// "ctrl+opt+s" → "⌃⌥S", in the order macOS menus draw modifiers.
    static func label(_ spec: String) -> String {
        var mods = Set<String>(), key = ""
        for raw in spec.lowercased().split(separator: "+") {
            switch raw.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command", "⌘": mods.insert("⌘")
            case "ctrl", "control", "⌃": mods.insert("⌃")
            case "opt", "option", "alt", "⌥": mods.insert("⌥")
            case "shift", "⇧": mods.insert("⇧")
            case let k: key = k
            }
        }
        let isFKey = key.count > 1 && key.hasPrefix("f") && key.dropFirst().allSatisfy(\.isNumber)
        let shown = key.count == 1 || isFKey ? key.uppercased() : key.capitalized
        return ["⌃", "⌥", "⇧", "⌘"].filter(mods.contains).joined() + shown
    }
}

// `--set-hotkey`: save the combo, then restart the agent so it takes effect. Says what
// actually happened at each step instead of "hotkey set" regardless. The launchctl call
// is injected so the decision is testable without touching the live LaunchAgent.
enum SetHotkey {
    static let agentLabel = "com.chris.speakhud.agent"
    /// What `launchctl kickstart` said. launchctl exits 113 when the label isn't loaded.
    struct Kick: Equatable {
        let status: Int32
        let output: String
    }
    static let notLoadedStatus: Int32 = 113

    struct Outcome: Equatable {
        let message: String
        let exitCode: Int32
    }

    static func run(_ spec: String,
                    save: (String) -> Bool = { HotkeyConfig.save($0) },
                    kick: () throws -> Kick = kickAgent) -> Outcome {
        guard save(spec) else {
            return Outcome(message: "error: couldn't save \(spec) to \(HotkeyConfig.path) — nothing changed", exitCode: 1)
        }
        let result: Kick
        do { result = try kick() } catch {
            return Outcome(message: "error: saved \(spec), but couldn't run launchctl to restart the agent: \(error.localizedDescription)",
                           exitCode: 1)
        }
        let said = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch result.status {
        case 0:
            return Outcome(message: "hotkey set to \(spec) — agent restarted", exitCode: 0)
        case notLoadedStatus:
            return Outcome(message: "hotkey saved as \(spec); agent not running, takes effect when it starts", exitCode: 0)
        default:
            return Outcome(message: "error: saved \(spec), but restarting the agent failed (launchctl exit \(result.status))"
                                    + (said.isEmpty ? "" : ": \(said)"),
                           exitCode: 1)
        }
    }

    /// The real restart. Only `Main` calls this; tests inject their own.
    static func kickAgent() throws -> Kick {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(agentLabel)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Kick(status: p.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }
}

// Installs/removes the Claude Code "Stop" hook that reads each response aloud, so
// a downloaded copy can replicate the author's setup with one click. This is the one
// install path: the menu item, --setup-claude, and build.sh (which shells out to
// --setup-claude) all land here. An install is three pieces — read-summary.py, the
// reader binary the hook falls back to, and the settings.json entry — and status()
// checks all three, so a missing or out-of-date file shows up as `.stale` rather than
// hiding behind a present settings entry. Edits to settings.json are merges: other keys,
// groups and sibling hooks are preserved.
// Set SPEAKHUD_CLAUDE_DIR to point at a different dir (used by tests).
enum ClaudeHook {
    enum Status: String {
        case installed
        case stale                          // entry present, but a file is missing or out of date
        case notInstalled = "not installed"
    }

    static var defaultDir: String { NSString(string: "~/.claude").expandingTildeInPath }
    static var dir: String {
        if let d = ProcessInfo.processInfo.environment["SPEAKHUD_CLAUDE_DIR"], !d.isEmpty {
            return NSString(string: d).expandingTildeInPath
        }
        return defaultDir
    }
    static var settingsPath: String { dir + "/settings.json" }
    static var scriptPath: String { dir + "/read-summary.py" }
    static var binDir: String { dir + "/bin" }
    static var binPath: String { binDir + "/speak-hud" }

    /// The command registered in settings.json. For the real dir it stays the portable
    /// `~` form; with SPEAKHUD_CLAUDE_DIR set it names the overridden script, so the entry
    /// and the file it runs never disagree. (read-summary.py's own fallback still looks
    /// for ~/.claude/bin/speak-hud — the override exists for tests, which never run it.)
    static var hookCommand: String {
        if dir == defaultDir { return "python3 ~/.claude/read-summary.py" }
        return "python3 '" + scriptPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// read-summary.py shipped inside SpeakHUD.app. Nil when running outside the bundle
    /// (e.g. as ~/.claude/bin/speak-hud).
    static var bundledScript: URL? { Bundle.main.url(forResource: "read-summary", withExtension: "py") }

    /// The file this process is running from, absolute and with symlinks resolved.
    /// argv[0] isn't good enough: it's relative when invoked via PATH or `./`.
    static var runningExecutable: URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size) + 1)
        if _NSGetExecutablePath(&buf, &size) == 0, let real = realpath(buf, nil) {
            defer { free(real) }
            return URL(fileURLWithPath: String(cString: real))
        }
        return Bundle.main.executableURL?.resolvingSymlinksInPath()
    }

    // MARK: settings.json

    private enum Settings { case missing, invalid, ok([String: Any]) }

    private static func readSettings() -> Settings {
        guard let data = FileManager.default.contents(atPath: settingsPath) else { return .missing }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .invalid }
        return .ok(root)
    }

    private static func stopGroups(_ root: [String: Any]) -> [[String: Any]] {
        (root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
    }
    /// One hook entry (not a group) is ours if it runs read-summary.py.
    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains("read-summary.py") == true
    }
    private static func groupHasOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains(where: isOurs) == true
    }

    // MARK: files

    /// True when both paths name the same file on disk (same device + inode), whatever
    /// the spelling — /tmp vs /private/tmp, symlinks, hard links.
    static func sameFile(_ a: String, _ b: String) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(a, &sa) == 0, stat(b, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    private static func sameContents(_ a: String, _ b: String) -> Bool {
        if sameFile(a, b) { return true }
        let fm = FileManager.default
        guard let sa = (try? fm.attributesOfItem(atPath: a))?[.size] as? NSNumber,
              let sb = (try? fm.attributesOfItem(atPath: b))?[.size] as? NSNumber,
              sa == sb,
              let da = try? Data(contentsOf: URL(fileURLWithPath: a), options: .alwaysMapped),
              let db = try? Data(contentsOf: URL(fileURLWithPath: b), options: .alwaysMapped)
        else { return false }
        return da == db
    }

    /// Copy `src` over `dst` without ever leaving `dst` missing: copy to a temp name in the
    /// same dir, then rename(2) it into place. A no-op when they're already the same file
    /// (`~/.claude/bin/speak-hud --setup-claude`). A symlinked `dst` (say, into a checkout)
    /// is written through, not replaced by a plain file. Returns nil on success, else why not.
    private static func placeFile(from src: String, to link: String, mode: Int) -> String? {
        let fm = FileManager.default
        let dst = (link as NSString).resolvingSymlinksInPath
        if sameFile(src, dst) { return nil }
        guard fm.isReadableFile(atPath: src) else { return "can't read \(src)" }
        let tmp = (dst as NSString).deletingLastPathComponent
            + "/.\((dst as NSString).lastPathComponent).tmp-\(getpid())"
        try? fm.removeItem(atPath: tmp)
        do {
            try fm.copyItem(atPath: src, toPath: tmp)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp)
        } catch {
            try? fm.removeItem(atPath: tmp)
            return "copy \(src) failed: \(error.localizedDescription)"
        }
        guard rename(tmp, dst) == 0 else {
            let why = String(cString: strerror(errno))
            try? fm.removeItem(atPath: tmp)
            return "couldn't replace \(dst): \(why)"
        }
        return nil
    }

    // MARK: public surface

    /// Three-way status plus, when stale, what's wrong. `script`/`binary` are what an
    /// install would copy from; a nil source can't be compared, so only presence counts.
    static func check(script: URL? = bundledScript,
                      binary: URL? = runningExecutable) -> (status: Status, problems: [String]) {
        let root: [String: Any]
        switch readSettings() {
        case .missing: return (.notInstalled, [])
        case .invalid: return (.notInstalled, ["\(settingsPath) is not valid JSON"])
        case .ok(let r): root = r
        }
        guard stopGroups(root).contains(where: groupHasOurs) else { return (.notInstalled, []) }
        let fm = FileManager.default
        var problems: [String] = []
        if !fm.fileExists(atPath: scriptPath) {
            problems.append("script missing")
        } else if let s = script, !sameContents(s.path, scriptPath) {
            problems.append("script differs from bundled copy")
        }
        if !fm.isExecutableFile(atPath: binPath) {
            problems.append("binary missing")
        } else if let b = binary, !sameContents(b.path, binPath) {
            problems.append("binary differs from this build")
        }
        return (problems.isEmpty ? .installed : .stale, problems)
    }

    static func status(script: URL? = bundledScript, binary: URL? = runningExecutable) -> Status {
        check(script: script, binary: binary).status
    }

    /// Refresh the script and binary where copies already exist, without touching
    /// settings.json. For a hook registered somewhere we don't read (settings.local.json,
    /// a project's settings) or a settings.json we can't parse: a rebuild still shouldn't
    /// leave those copies running old code. Returns what it did, or "error: …".
    static func refreshFiles(script: URL? = bundledScript, binary: URL? = runningExecutable) -> String {
        let fm = FileManager.default
        var done: [String] = [], problems: [String] = []
        if let s = script, fm.fileExists(atPath: scriptPath) {
            if let e = placeFile(from: s.path, to: scriptPath, mode: 0o644) { problems.append("script: \(e)") }
            else { done.append("script") }
        }
        if let b = binary, fm.fileExists(atPath: binPath) {
            if let e = placeFile(from: b.path, to: binPath, mode: 0o755) { problems.append("binary: \(e)") }
            else { done.append("binary") }
        }
        if !problems.isEmpty { return "error: " + problems.joined(separator: "; ") }
        return done.isEmpty ? "nothing to refresh" : "refreshed " + done.joined(separator: ", ")
    }

    /// Install or repair all three pieces. Returns "installed", or "error: …" naming every
    /// step that failed. Idempotent: re-running refreshes the files and leaves an existing
    /// settings entry alone.
    @discardableResult
    static func install(script: URL? = bundledScript, binary: URL? = runningExecutable) -> String {
        let fm = FileManager.default
        // Settings first: if the file can't be parsed, touch nothing at all.
        var root: [String: Any] = [:]
        switch readSettings() {
        case .invalid: return "error: \(settingsPath) is not valid JSON — left it untouched"
        case .ok(let r): root = r
        case .missing: break
        }
        do { try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true) }
        catch { return "error: couldn't create \(binDir): \(error.localizedDescription)" }

        var problems: [String] = []
        if let s = script {
            if let e = placeFile(from: s.path, to: scriptPath, mode: 0o644) { problems.append("script: \(e)") }
        } else if !fm.fileExists(atPath: scriptPath) {
            problems.append("script: no bundled read-summary.py to install (run this from SpeakHUD.app)")
        }
        // Registering a hook that points at nothing is the silent failure we're avoiding.
        guard fm.fileExists(atPath: scriptPath) else {
            return "error: " + problems.joined(separator: "; ") + " — hook not registered"
        }
        if let b = binary {
            if let e = placeFile(from: b.path, to: binPath, mode: 0o755) { problems.append("binary: \(e)") }
        } else {
            problems.append("binary: couldn't locate the running executable")
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var stop = hooks["Stop"] as? [[String: Any]] ?? []
        if !stop.contains(where: groupHasOurs) {
            stop.append(["hooks": [["type": "command", "command": hookCommand, "async": true]]])
            hooks["Stop"] = stop
            root["hooks"] = hooks
            if !write(root) { problems.append("settings: couldn't write \(settingsPath)") }
        }
        return problems.isEmpty ? "installed" : "error: " + problems.joined(separator: "; ")
    }

    /// Remove only our entry. Sibling hooks in the same group stay; a group is dropped
    /// only once it's empty. The script and binary are left in place.
    @discardableResult
    static func remove() -> String {
        var root: [String: Any]
        switch readSettings() {
        case .missing: return "nothing to remove"
        case .invalid: return "error: \(settingsPath) is not valid JSON — left it untouched"
        case .ok(let r): root = r
        }
        guard var hooks = root["hooks"] as? [String: Any],
              let stop = hooks["Stop"] as? [[String: Any]],
              stop.contains(where: groupHasOurs)
        else { return "nothing to remove" }
        let kept: [[String: Any]] = stop.compactMap { group in
            guard var inner = group["hooks"] as? [[String: Any]], inner.contains(where: isOurs)
            else { return group }
            inner.removeAll(where: isOurs)
            if inner.isEmpty { return nil }
            var g = group
            g["hooks"] = inner
            return g
        }
        if kept.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = kept }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return write(root) ? "removed" : "error: couldn't write \(settingsPath)"
    }

    private static func write(_ root: [String: Any]) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: root,
                                                     options: [.prettyPrinted, .sortedKeys]),
              var text = String(data: data, encoding: .utf8) else { return false }
        // JSONSerialization escapes every "/" as "\/"; undo that for a clean config file.
        text = text.replacingOccurrences(of: "\\/", with: "/") + "\n"
        return (try? text.write(toFile: settingsPath, atomically: true, encoding: .utf8)) != nil
    }
}

// Human combo like "ctrl+opt+s" -> (Carbon keycode, modifier mask).
let keyCodeMap: [String: UInt32] = [
    "a":0x00,"s":0x01,"d":0x02,"f":0x03,"h":0x04,"g":0x05,"z":0x06,"x":0x07,"c":0x08,
    "v":0x09,"b":0x0B,"q":0x0C,"w":0x0D,"e":0x0E,"r":0x0F,"y":0x10,"t":0x11,"o":0x1F,
    "u":0x20,"i":0x22,"p":0x23,"l":0x25,"j":0x26,"k":0x28,"n":0x2D,"m":0x2E,
    "1":0x12,"2":0x13,"3":0x14,"4":0x15,"5":0x17,"6":0x16,"7":0x1A,"8":0x1C,"9":0x19,"0":0x1D,
    "space":0x31,"return":0x24,"tab":0x30,
    "f1":0x7A,"f2":0x78,"f3":0x63,"f4":0x76,"f5":0x60,"f6":0x61,"f7":0x62,"f8":0x64,
    "f9":0x65,"f10":0x6D,"f11":0x67,"f12":0x6F,
]

func parseHotkey(_ spec: String) -> (keyCode: UInt32, mods: UInt32)? {
    var mods: UInt32 = 0
    var key: String?
    for raw in spec.lowercased().split(separator: "+") {
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "cmd", "command", "⌘": mods |= UInt32(cmdKey)
        case "ctrl", "control", "⌃": mods |= UInt32(controlKey)
        case "opt", "option", "alt", "⌥": mods |= UInt32(optionKey)
        case "shift", "⇧": mods |= UInt32(shiftKey)
        case let other: key = other
        }
    }
    guard let k = key, let code = keyCodeMap[k], mods != 0 else { return nil }   // need ≥1 modifier
    return (code, mods)
}

// Background listener: owns the one HUD, the speech queue, and the global hotkey.
// Runs from a LaunchAgent; no window/Dock until something needs reading.
final class Agent {
    static weak var shared: Agent?
    let hud = Controller()
    var spoolSource: DispatchSourceFileSystemObject?
    var pollTimer: Timer?
    var napGuard: NSObjectProtocol?
    var heartbeatOK = true
    var usr1: DispatchSourceSignal?

    /// launchd routes stderr to ~/Library/Logs/speakhud-agent.log (see build.sh).
    func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write("[\(ts)] \(message)\n".data(using: .utf8)!)
    }

    func run() {
        Agent.shared = self
        hud.onIdle = { [weak self] in self?.hud.hidePanel() }
        hud.log = { [weak self] in self?.log($0) }
        hud.watchMic()
        hud.hotkeyHint = "Anywhere:  ⌃⌥P pause / resume    ⌃⌥H show / hide this window"
        log("agent started (pid \(getpid()))")
        // The one thing you can't tell from outside the process: whether macOS will
        // let us see the text you've highlighted.
        log(Selection.isTrusted
            ? "accessibility: granted — hotkey reads your selection"
            : "accessibility: NOT granted — hotkey falls back to the clipboard")
        registerReadHotKey()
        HotKeyCenter.shared.register(.togglePause,
                                     keyCode: UInt32(kVK_ANSI_P),
                                     mods: UInt32(controlKey | optionKey)) { [weak self] in
            self?.hud.togglePause()
        }
        let shown = HotKeyCenter.shared.register(.toggleHUD,
                                                 keyCode: UInt32(kVK_ANSI_H),
                                                 mods: UInt32(controlKey | optionKey)) { [weak self] in
            self?.hud.toggleMinimized()
        }
        if !shown {
            // Without the hotkey the menu bar is the only way back; say so in the panel.
            log("could not register ⌃⌥H — use the menu bar to show/hide the HUD")
            hud.hotkeyHint = "Pause / Resume anywhere:  ⌃⌥P    (show / hide: menu bar)"
        }
        watchSpool()
        // SIGUSR1 also triggers a read — lets the install step self-test without keys.
        signal(SIGUSR1, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        s.setEventHandler { Agent.shared?.readClipboard() }
        s.resume()
        usr1 = s
    }

    /// The read hotkey actually live right now. Editing config.json doesn't change it
    /// until the agent re-registers, so the menu reports this, not the file.
    private(set) var registeredSpec: String?

    func registerReadHotKey() {
        let loaded = HotkeyConfig.load()
        if let why = loaded.problem {
            // Left as is: it's yours to fix, and the menu shows the same warning.
            log("\(HotkeyConfig.path) \(why) — using \(loaded.spec)")
        }
        let spec = loaded.spec
        guard let hk = parseHotkey(spec) else {
            log("invalid hotkey \"\(spec)\" — not registered")
            return
        }
        let ok = HotKeyCenter.shared.register(.read, keyCode: hk.keyCode, mods: hk.mods) { [weak self] in
            self?.readSelection()
        }
        registeredSpec = ok ? spec : nil   // register() drops the old binding first
        log(ok ? "listening for \(spec)" : "could not register \(spec) — another app owns it")
    }

    // -- spool -------------------------------------------------------------

    private func watchSpool() {
        Spool.ensure()
        Spool.recover()   // whatever the last agent died holding gets another turn
        log("spool: watching \(Spool.dir)")   // if the hook writes elsewhere, this is where you'd see it
        let fd = open(Spool.dir, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .rename], queue: .main)
            src.setEventHandler { [weak self] in self?.drainSpool() }
            src.setCancelHandler { close(fd) }
            src.resume()
            spoolSource = src
        }
        // Safety net: the vnode source goes deaf if the directory is ever replaced.
        // Also the heartbeat: the hook queues only while it's fresh, so it beats from
        // this main-thread timer (a hung main thread goes stale) in .common modes (an
        // open menu mustn't stop it), with App Nap off (an accessory app with no window
        // gets napped, and its timers stretched past the hook's threshold).
        napGuard = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "spool heartbeat")
        let timer = Timer(timeInterval: Spool.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.heartbeat()
            self?.drainSpool()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        heartbeat()   // alive from the first drain, not 3s later
        drainSpool()
    }

    private func heartbeat() {
        let ok = Spool.beat()
        // Log transitions only: every 3s would drown the log.
        if ok != heartbeatOK {
            log(ok ? "spool: heartbeat restored"
                   : "spool: can't write \(Spool.heartbeatName) in \(Spool.dir) — hooks will speak turns directly")
        }
        heartbeatOK = ok
    }

    private func drainSpool() {
        let batch = Spool.drain()
        for drop in batch.dropped { log("spool: dropped \(drop.name) — \(drop.reason)") }
        for item in batch.items {
            if hud.enqueue(item) {
                log("speaking \(item.source)")
            } else if hud.playback.current?.file == item.file {
                log("holding \(item.source) — mic in use or paused")
            } else {
                log("queued \(item.source) — \(hud.queue.count) waiting")
            }
        }
    }

    // -- reads -------------------------------------------------------------

    /// Hotkey: read whatever is highlighted in the frontmost app.
    func readSelection() {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Selection"
        // No selection (or no Accessibility grant) falls back to the clipboard,
        // which is exactly what this hotkey did before it could see selections.
        play(Selection.current() ?? NSPasteboard.general.string(forType: .string) ?? "", source: app)
    }

    /// Menu item / double-clicking the app: there's no meaningful selection when
    /// SpeakHUD itself is frontmost, so read the clipboard.
    func readClipboard() {
        play(NSPasteboard.general.string(forType: .string) ?? "", source: "Clipboard")
    }

    private func play(_ raw: String, source: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { NSSound.beep(); return }
        hud.playNow(SpeechItem(text: text, source: source, key: UUID().uuidString, created: Date()))
    }
}

// Because the agent is a running instance of the app bundle, double-clicking
// SpeakHUD.app doesn't launch a new reader — macOS just "reopens" the agent.
// Treat that reopen as "read the clipboard", so double-click does what you'd expect.
final class AgentDelegate: NSObject, NSApplicationDelegate {
    let agent: Agent
    init(_ agent: Agent) { self.agent = agent }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        agent.readClipboard()
        return true
    }
}

// Menu-bar settings surface for the agent: read clipboard, toggle the Claude Code
// integration, and pick the global hotkey — all without a Dock icon or window.
final class MenuController: NSObject, NSMenuDelegate {
    let agent: Agent
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var claudeItem: NSMenuItem!
    var axItem: NSMenuItem!
    var hudItem: NSMenuItem!
    let hotkeyPresets = [("⌃⌥S", "ctrl+opt+s"), ("⌃⌥R", "ctrl+opt+r"),
                         ("⌃⌥Space", "ctrl+opt+space"), ("⌘⌥S", "cmd+opt+s")]
    var hotkeyItems: [NSMenuItem] = []
    var hotkeyWarning: NSMenuItem!
    var micItem: NSMenuItem!

    init(_ agent: Agent) {
        self.agent = agent
        super.init()
        build()
        // Hiding via the panel's own button has to move the menu item too. Only the
        // visibility bits: the hook check compares whole files, so it waits for the menu.
        agent.hud.onVisibilityChange = { [weak self] in self?.refreshVisibility() }
    }

    private func build() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false   // so a disabled Pause While Recording (pre-14) stays disabled
        // First item, because when the HUD is hidden this is what you came here for.
        hudItem = item("Show HUD", #selector(toggleHUD))
        hudItem.keyEquivalent = "h"
        hudItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(hudItem)
        menu.addItem(item("Read Clipboard Aloud", #selector(readClipboard)))
        menu.addItem(.separator())

        claudeItem = item("Read Claude Code Responses Aloud", #selector(toggleClaude))
        menu.addItem(claudeItem)

        micItem = item("Pause While Recording", #selector(toggleMicHold))
        if #available(macOS 14.0, *) {
            micItem.toolTip = "Hold speech while another app uses the microphone"
        } else {
            micItem.isEnabled = false
            micItem.toolTip = "Needs macOS 14 or later"
        }
        menu.addItem(micItem)

        let hk = NSMenu()
        hk.autoenablesItems = false   // keep the warning line disabled
        // Only shown while config.json is broken; the tooltip says how.
        hotkeyWarning = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hotkeyWarning.isEnabled = false
        hk.addItem(hotkeyWarning)
        for (label, spec) in hotkeyPresets {
            let it = item(label, #selector(pickHotkey(_:))); it.representedObject = spec
            hk.addItem(it); hotkeyItems.append(it)
        }
        hk.addItem(.separator())
        hk.addItem(item("Edit Config File…", #selector(openHotkeyConfig)))
        let hkParent = NSMenuItem(title: "Global Hotkey", action: nil, keyEquivalent: "")
        hkParent.submenu = hk
        menu.addItem(hkParent)

        // Only surfaced when we can't read selections yet — otherwise it's noise.
        axItem = item("Grant Accessibility Access…", #selector(grantAccessibility))
        menu.addItem(axItem)

        menu.addItem(.separator())
        menu.addItem(item("SpeakHUD on GitHub", #selector(openGitHub)))
        menu.addItem(item("Quit SpeakHUD", #selector(quit)))
        statusItem.menu = menu
        refresh()
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    private func refresh() {
        refreshVisibility()
        refreshHook()
        axItem.isHidden = Selection.isTrusted
        let loaded = HotkeyConfig.load()
        for it in hotkeyItems { it.state = (it.representedObject as? String == loaded.spec) ? .on : .off }
        hotkeyWarning.isHidden = loaded.problem == nil
        hotkeyWarning.title = "⚠ config.json invalid — "
            + (agent.registeredSpec.map { "using \(HotkeyConfig.label($0))" } ?? "no hotkey registered")
        hotkeyWarning.toolTip = loaded.problem.map { "\(HotkeyConfig.path) \($0)" }
        micItem.state = micItem.isEnabled && agent.hud.pauseWhileRecording ? .on : .off
    }

    private func refreshVisibility() {
        let hidden = !agent.hud.isPanelVisible
        hudItem.title = hidden ? "Show HUD" : "Hide HUD"
        // A hollow icon is the standing reminder that the panel is only hidden,
        // not gone — otherwise a hidden HUD is indistinguishable from a broken one.
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: hidden ? "speaker.wave.2" : "speaker.wave.2.fill",
                                accessibilityDescription: hidden ? "SpeakHUD (hidden)" : "SpeakHUD")
        }
    }

    private func refreshHook() {
        let hook = ClaudeHook.check()
        claudeItem.title = hook.status == .stale ? "Read Claude Code Responses Aloud — Repair"
                                                 : "Read Claude Code Responses Aloud"
        switch hook.status {
        case .installed:    claudeItem.state = .on
        case .stale:        claudeItem.state = .mixed    // "–": present but broken
        case .notInstalled: claudeItem.state = .off
        }
        claudeItem.toolTip = hook.problems.isEmpty ? nil
            : hook.status == .stale ? "Needs repair: " + hook.problems.joined(separator: "; ") + ". Click to reinstall."
            : hook.problems.joined(separator: "; ")
    }

    @objc private func toggleHUD() { agent.hud.toggleMinimized() }
    @objc private func readClipboard() { agent.readClipboard() }
    @objc private func toggleClaude() {
        // Installed -> remove. Stale -> reinstall (a repair, not an uninstall). Off -> install.
        let result = ClaudeHook.status() == .installed ? ClaudeHook.remove() : ClaudeHook.install()
        if result.hasPrefix("error") {
            let alert = NSAlert()
            alert.messageText = "Claude Code hook"
            alert.informativeText = result
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refresh()
    }
    @objc private func grantAccessibility() {
        if !Selection.requestTrust() {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        refresh()
    }
    @objc private func pickHotkey(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? String else { return }
        HotkeyConfig.save(spec)
        agent.registerReadHotKey()   // re-register live; no restart needed
        refresh()
    }
    @objc private func toggleMicHold() {
        agent.hud.pauseWhileRecording.toggle()
        refresh()
    }
    @objc private func openHotkeyConfig() {
        HotkeyConfig.ensureFile()   // create it if missing; never overwrite a broken one you're fixing
        NSWorkspace.shared.open(URL(fileURLWithPath: HotkeyConfig.path))
    }
    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/chris-jk/SpeakHUD")!)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

// ---------------------------------------------------------------------------
// Entry point: dispatch on mode. Compiled out for tests (tests/run.sh builds with
// -D TESTING), so a test main can link everything above without launching the app.
// @main rather than top-level code, because Swift rejects top-level statements in
// any file but main.swift, even inside an inactive #if.
// ---------------------------------------------------------------------------
#if !TESTING
@main
enum Main {
    static func main() {
        let argv = CommandLine.arguments

        if let i = argv.firstIndex(of: "--set-hotkey") {
            guard i + 1 < argv.count, parseHotkey(argv[i + 1]) != nil else {
                FileHandle.standardError.write(
                    "usage: speak-hud --set-hotkey \"ctrl+opt+s\"  (need ≥1 modifier + a key)\n".data(using: .utf8)!)
                exit(2)
            }
            let outcome = SetHotkey.run(argv[i + 1])
            if outcome.exitCode == 0 {
                print(outcome.message)
            } else {
                FileHandle.standardError.write((outcome.message + "\n").data(using: .utf8)!)
            }
            exit(outcome.exitCode)
        }

        if argv.contains("--setup-claude") || argv.contains("--remove-claude") {
            let r = argv.contains("--setup-claude") ? ClaudeHook.install() : ClaudeHook.remove()
            print(r); exit(r.hasPrefix("error") ? 1 : 0)
        }
        if argv.contains("--refresh-claude-files") {
            let r = ClaudeHook.refreshFiles()
            print(r); exit(r.hasPrefix("error") ? 1 : 0)
        }
        if argv.contains("--claude-status") {
            // "installed" | "stale: <why>" | "not installed" — build.sh matches on these.
            let c = ClaudeHook.check()
            print(c.problems.isEmpty ? c.status.rawValue
                                     : c.status.rawValue + ": " + c.problems.joined(separator: "; "))
            exit(0)
        }

        if argv.contains("--agent") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let agent = Agent()
            let agentDelegate = AgentDelegate(agent)
            app.delegate = agentDelegate          // handles double-click "reopen" -> read clipboard
            agent.run()
            let menuController = MenuController(agent)   // menu-bar settings surface
            _ = menuController
            app.run()
            exit(0)
        }

        // Default: a one-shot reader HUD. Used for `speak-hud "text"` and as the Claude
        // Code hook's fallback when the agent isn't running to serialize things for us.
        let text = resolveText(argv).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { exit(0) }

        var sourceName = "Claude Code"
        if let i = argv.firstIndex(of: "--source"), i + 1 < argv.count { sourceName = argv[i + 1] }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // no Dock icon, doesn't steal focus
        let controller = Controller()
        controller.onIdle = { NSApp.terminate(nil) }
        controller.watchMic()
        HotKeyCenter.shared.register(.togglePause,
                                     keyCode: UInt32(kVK_ANSI_P),
                                     mods: UInt32(controlKey | optionKey)) { [weak controller] in
            controller?.togglePause()
        }
        controller.enqueue(SpeechItem(text: text, source: sourceName, key: UUID().uuidString, created: Date()))
        app.run()
    }
}
#endif
