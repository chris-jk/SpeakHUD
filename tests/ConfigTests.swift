// Settings tests: config.json loading, --set-hotkey's report, the mic-hold setting.
// Registered in tests/main.swift. config.json lives in a fresh temp dir via
// SPEAKHUD_CONFIG_DIR; prefs go to a throwaway suite; launchctl is never run.
import Foundation

/// Runs `body` with HotkeyConfig pointed at a fresh temp dir, then removes it.
private func withConfigDir(_ body: (String) -> Void) {
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "speakhud-config-\(UUID().uuidString)"
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let old = ProcessInfo.processInfo.environment[HotkeyConfig.dirEnv]
    setenv(HotkeyConfig.dirEnv, dir, 1)
    defer {
        if let old = old { setenv(HotkeyConfig.dirEnv, old, 1) } else { unsetenv(HotkeyConfig.dirEnv) }
        try? fm.removeItem(atPath: dir)
    }
    body(dir)
}

private func write(_ s: String) { try! s.write(toFile: HotkeyConfig.path, atomically: true, encoding: .utf8) }
private func contents() -> String? { try? String(contentsOfFile: HotkeyConfig.path, encoding: .utf8) }

/// A MicHold on a real Playback (fake voice), with the release debounce held by hand.
private final class MicRig {
    let rig = Rig()
    var pending: [() -> Void] = []
    var delivered: [Bool] = []
    private(set) var hold: MicHold!
    init(enabled: Bool = true) {
        hold = MicHold(enabled: enabled, deliver: { [unowned self] busy in
            self.delivered.append(busy)
            self.rig.playback.micChanged(busy: busy)
        }, debounce: { [unowned self] work in
            var live = true
            self.pending.append { if live { work() } }
            return { live = false }
        })
    }
    /// Let the release delay elapse.
    func elapse() { let p = pending; pending = []; p.forEach { $0() } }
}

private func turn(_ text: String) -> SpeechItem {
    SpeechItem(text: text, source: "A", key: "A", created: Date(), file: "/tmp/\(text).taken")
}

let configSuite = Suite("Config") { t in
    // -- config.json -------------------------------------------------------

    withConfigDir { dir in
        t.expectEqual(HotkeyConfig.path, dir + "/config.json", "SPEAKHUD_CONFIG_DIR moves config.json")

        t.expectEqual(HotkeyConfig.load(), .init(spec: "ctrl+opt+s", problem: nil),
                      "no file: default, and that's not a problem")

        write("{\"hotkey\": \"cmd+opt+r\"}")
        t.expectEqual(HotkeyConfig.load(), .init(spec: "cmd+opt+r", problem: nil), "a good file is used")

        let broken: [(String, String)] = [
            ("{\"hotkey\": \"ctrl+opt+s\"", "bad JSON"),
            ("[\"ctrl+opt+s\"]", "not an object"),
            ("{\"hotKey\": \"ctrl+opt+r\"}", "missing key"),
            ("{\"hotkey\": \"  \"}", "empty combo"),
            ("{\"hotkey\": 5}", "combo not a string"),
            ("{\"hotkey\": \"r\"}", "no modifier"),
            ("{\"hotkey\": \"ctrl+opt+banana\"}", "unknown key"),
        ]
        for (json, what) in broken {
            write(json)
            let l = HotkeyConfig.load()
            t.expectEqual(l.spec, "ctrl+opt+s", "\(what): falls back to the default")
            t.expect(l.problem != nil, "\(what): carries a reason")
        }
        write("{\"hotkey\": \"ctrl+opt+banana\"}")
        t.expect(HotkeyConfig.load().problem?.contains("banana") == true, "the reason names the bad combo")
        write("{nope")
        t.expect(HotkeyConfig.load().problem?.contains("JSON") == true, "the reason says it isn't JSON")

        // "Edit Config File…" must not replace the file you're in the middle of fixing.
        write("{nope")
        HotkeyConfig.ensureFile()
        t.expectEqual(contents(), "{nope", "ensureFile leaves a broken file alone")
        try? FileManager.default.removeItem(atPath: HotkeyConfig.path)
        t.expect(HotkeyConfig.ensureFile(), "ensureFile creates a missing file")
        t.expectEqual(HotkeyConfig.load(), .init(spec: "ctrl+opt+s", problem: nil), "…holding the default")
    }

    t.expectEqual(HotkeyConfig.label("ctrl+opt+s"), "⌃⌥S", "label: default")
    t.expectEqual(HotkeyConfig.label("cmd+opt+s"), "⌥⌘S", "label: macOS modifier order")
    t.expectEqual(HotkeyConfig.label("shift+ctrl+space"), "⌃⇧Space", "label: named key")
    t.expectEqual(HotkeyConfig.label("ctrl+f12"), "⌃F12", "label: function key")

    // -- --set-hotkey --------------------------------------------------------

    do {
        var kicked = 0
        let kick = { (k: SetHotkey.Kick) in { () throws -> SetHotkey.Kick in kicked += 1; return k } }

        let failedSave = SetHotkey.run("ctrl+opt+r", save: { _ in false }, kick: kick(.init(status: 0, output: "")))
        t.expectEqual(failedSave.exitCode, 1, "save failed: exits non-zero")
        t.expect(failedSave.message.hasPrefix("error"), "save failed: says so")
        t.expectEqual(kicked, 0, "save failed: doesn't restart the agent")

        let ok = SetHotkey.run("ctrl+opt+r", save: { _ in true }, kick: kick(.init(status: 0, output: "")))
        t.expectEqual(ok.exitCode, 0, "restarted: exit 0")
        t.expect(ok.message.contains("restarted"), "restarted: says the agent restarted")

        let absent = SetHotkey.run("ctrl+opt+r", save: { _ in true }, kick: kick(.init(
            status: 113, output: "Could not find service \"com.chris.speakhud.agent\" in domain for user gui: 501\n")))
        t.expectEqual(absent.exitCode, 0, "agent not loaded: not an error")
        t.expect(absent.message.contains("saved") && absent.message.contains("not running"),
                 "agent not loaded: saved, takes effect when it starts — got \(absent.message)")
        t.expect(!absent.message.contains("restarted"), "agent not loaded: doesn't claim a restart")

        let failed = SetHotkey.run("ctrl+opt+r", save: { _ in true }, kick: kick(.init(status: 5, output: "Operation not permitted\n")))
        t.expectEqual(failed.exitCode, 1, "restart failed: exits non-zero")
        t.expect(failed.message.hasPrefix("error") && failed.message.contains("Operation not permitted")
                 && failed.message.contains("saved"),
                 "restart failed: gives launchctl's reason and that the combo was saved — got \(failed.message)")

        struct Boom: Error {}
        let unrunnable = SetHotkey.run("ctrl+opt+r", save: { _ in true }, kick: { throw Boom() })
        t.expectEqual(unrunnable.exitCode, 1, "launchctl couldn't run: exits non-zero")
    }

    withConfigDir { _ in   // the default save really writes (to the temp dir)
        let r = SetHotkey.run("cmd+opt+s", kick: { .init(status: 0, output: "") })
        t.expectEqual(r.exitCode, 0, "default save: succeeds")
        t.expectEqual(HotkeyConfig.load(), .init(spec: "cmd+opt+s", problem: nil), "default save: written to config.json")
    }

    // -- Pause While Recording ----------------------------------------------

    do {  // persisted in the shared suite, on by default
        let name = "speakhud-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        t.expect(MicHold.storedEnabled(in: d), "on by default")
        MicHold.store(false, in: d)
        t.expect(!MicHold.storedEnabled(in: d), "off is remembered")
        MicHold.store(true, in: d)
        t.expect(MicHold.storedEnabled(in: d), "on again")
    }

    do {  // on: recording holds at once; release waits a beat
        let m = MicRig(), p = m.rig.playback!
        p.enqueue(turn("a")); _ = m.rig.voice.take()
        m.hold.recordingChanged(true)
        t.expectEqual(m.rig.voice.take(), [.pause(immediately: true)], "on: recording pauses speech")
        m.hold.recordingChanged(false)
        t.expectEqual(m.rig.voice.take(), [], "on: release waits for the debounce")
        m.elapse()
        t.expectEqual(m.rig.voice.take(), [.resume], "on: resumes after the debounce")
    }

    do {  // turning it off mid-hold releases now, not after the debounce
        let m = MicRig(), p = m.rig.playback!
        p.enqueue(turn("a")); _ = m.rig.voice.take()
        m.hold.recordingChanged(true); _ = m.rig.voice.take()
        m.hold.setEnabled(false)
        t.expectEqual(m.rig.voice.take(), [.resume], "off while recording: speech resumes immediately")
        t.expectEqual(p.state.status.contains("Mic"), false, "off: status no longer says mic")
        m.hold.recordingChanged(false); m.elapse()
        m.hold.recordingChanged(true)
        t.expectEqual(m.rig.voice.take(), [], "off: recording no longer pauses")
        t.expectEqual(m.delivered, [true, false], "off: Playback hears nothing more")
    }

    do {  // off during the release debounce: releases now, and the stale timer is harmless
        let m = MicRig(), p = m.rig.playback!
        p.enqueue(turn("a")); _ = m.rig.voice.take()
        m.hold.recordingChanged(true)
        m.hold.recordingChanged(false); _ = m.rig.voice.take()
        m.hold.setEnabled(false)
        t.expectEqual(m.rig.voice.take(), [.resume], "off mid-debounce: resumes now")
        m.elapse()
        t.expectEqual(m.delivered, [true, false], "off mid-debounce: the cancelled release doesn't fire again")
    }

    do {  // turning it on while something's recording holds at once
        let m = MicRig(enabled: false), p = m.rig.playback!
        p.enqueue(turn("a")); _ = m.rig.voice.take()
        m.hold.recordingChanged(true)
        t.expectEqual(m.rig.voice.take(), [], "off: keeps talking through a recording")
        m.hold.setEnabled(true)
        t.expectEqual(m.rig.voice.take(), [.pause(immediately: true)], "on while recording: holds now")
        m.hold.recordingChanged(false); m.elapse()
        t.expectEqual(m.rig.voice.take(), [.resume], "…and lets go when the recording ends")
    }

    do {  // turning it on with nothing recording does nothing
        let m = MicRig(enabled: false)
        m.hold.setEnabled(true)
        t.expectEqual(m.delivered, [], "on, mic idle: no hold")
    }

    do {  // a recorder reopening the mic inside the debounce keeps the hold, no flicker
        let m = MicRig(), p = m.rig.playback!
        p.enqueue(turn("a")); _ = m.rig.voice.take()
        m.hold.recordingChanged(true)
        m.hold.recordingChanged(false)
        m.hold.recordingChanged(true)
        m.elapse()
        t.expectEqual(m.delivered, [true], "reopen within the debounce: still one hold, no release")
    }
}
