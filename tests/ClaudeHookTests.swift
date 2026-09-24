// ClaudeHook tests. Registered in tests/main.swift.
// Every test runs against a fresh temp dir via SPEAKHUD_CLAUDE_DIR — never the real
// ~/.claude — and passes the script/binary sources explicitly (there's no app bundle).
import Foundation

let claudeHookSuite = Suite("ClaudeHook") { t in
    let fm = FileManager.default

    // A fresh claude dir plus sources to install from: a script and a small executable.
    func sandbox(_ body: (_ dir: String, _ script: URL, _ binary: URL) -> Void) {
        let root = NSTemporaryDirectory() + "speakhud-hook-\(UUID().uuidString)"
        let dir = root + "/claude", src = root + "/src"
        try? fm.createDirectory(atPath: src, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: src + "/read-summary.py")
        try? "print('hello')\n".write(to: script, atomically: true, encoding: .utf8)
        let binary = URL(fileURLWithPath: src + "/speak-hud")
        try? fm.copyItem(atPath: "/bin/echo", toPath: binary.path)
        setenv("SPEAKHUD_CLAUDE_DIR", dir, 1)
        defer { unsetenv("SPEAKHUD_CLAUDE_DIR"); try? fm.removeItem(atPath: root) }
        body(dir, script, binary)
    }
    func settings() -> [String: Any] {
        guard let d = fm.contents(atPath: ClaudeHook.settingsPath),
              let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return r
    }
    func stopGroups() -> [[String: Any]] {
        (settings()["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
    }

    // Fresh install writes all three pieces.
    sandbox { dir, script, binary in
        t.expect(ClaudeHook.settingsPath.hasPrefix(dir), "override points settings at the temp dir")
        t.expectEqual(ClaudeHook.status(script: script, binary: binary), .notInstalled, "empty dir")
        t.expectEqual(ClaudeHook.install(script: script, binary: binary), "installed", "fresh install")
        t.expect(fm.contentsEqual(atPath: ClaudeHook.scriptPath, andPath: script.path), "script written")
        t.expect(fm.isExecutableFile(atPath: ClaudeHook.binPath), "binary written and executable")
        let cmd = ((stopGroups().first?["hooks"] as? [[String: Any]])?.first?["command"] as? String) ?? ""
        t.expect(cmd.contains(ClaudeHook.scriptPath), "command runs the overridden script, got \(cmd)")
        t.expectEqual(ClaudeHook.status(script: script, binary: binary), .installed, "after install")
        _ = ClaudeHook.install(script: script, binary: binary)
        t.expectEqual(stopGroups().count, 1, "reinstall doesn't add a second entry")
    }

    // Tampered script -> stale; reinstall repairs it.
    sandbox { _, script, binary in
        _ = ClaudeHook.install(script: script, binary: binary)
        try? "print('old')\n".write(toFile: ClaudeHook.scriptPath, atomically: true, encoding: .utf8)
        let c = ClaudeHook.check(script: script, binary: binary)
        t.expectEqual(c.status, .stale, "tampered script")
        t.expect(!c.problems.isEmpty, "stale says why")
        t.expectEqual(ClaudeHook.install(script: script, binary: binary), "installed", "repair")
        t.expectEqual(ClaudeHook.status(script: script, binary: binary), .installed, "after repair")
    }

    // Missing binary -> stale.
    sandbox { _, script, binary in
        _ = ClaudeHook.install(script: script, binary: binary)
        try? fm.removeItem(atPath: ClaudeHook.binPath)
        t.expectEqual(ClaudeHook.status(script: script, binary: binary), .stale, "missing binary")
    }

    // Running `~/.claude/bin/speak-hud --setup-claude`: source IS the destination. The old
    // remove-then-copy deleted the binary and then had nothing to copy.
    sandbox { _, script, binary in
        _ = ClaudeHook.install(script: script, binary: binary)
        let installed = URL(fileURLWithPath: ClaudeHook.binPath)
        let r = ClaudeHook.install(script: script, binary: installed)
        t.expectEqual(r, "installed", "self-install succeeds")
        t.expect(fm.isExecutableFile(atPath: ClaudeHook.binPath), "self-install keeps the binary")
        t.expect(fm.contentsEqual(atPath: ClaudeHook.binPath, andPath: binary.path), "binary intact")
    }

    // An unreadable binary source is reported, not swallowed, and the old binary survives.
    sandbox { dir, script, binary in
        _ = ClaudeHook.install(script: script, binary: binary)
        let r = ClaudeHook.install(script: script, binary: URL(fileURLWithPath: dir + "/nope"))
        t.expect(r.hasPrefix("error") && r.contains("binary"), "failed copy is reported, got \(r)")
        t.expect(fm.isExecutableFile(atPath: ClaudeHook.binPath), "failed copy leaves the old binary")
    }

    // No script source and none on disk: error, and the hook isn't registered.
    sandbox { _, _, binary in
        let r = ClaudeHook.install(script: nil, binary: binary)
        t.expect(r.hasPrefix("error"), "no script source is an error, got \(r)")
        t.expect(stopGroups().isEmpty, "no hook registered without a script")
    }

    // remove() keeps a sibling hook that shares our group.
    sandbox { _, script, binary in
        _ = ClaudeHook.install(script: script, binary: binary)
        var root = settings()
        var hooks = root["hooks"] as! [String: Any]
        var stop = hooks["Stop"] as! [[String: Any]]
        var inner = stop[0]["hooks"] as! [[String: Any]]
        inner.append(["type": "command", "command": "echo sibling"])
        stop[0]["hooks"] = inner
        stop.append(["hooks": [["type": "command", "command": "echo other-group"]]])
        hooks["Stop"] = stop; root["hooks"] = hooks
        let data = try! JSONSerialization.data(withJSONObject: root)
        fm.createFile(atPath: ClaudeHook.settingsPath, contents: data)

        t.expectEqual(ClaudeHook.remove(), "removed", "remove")
        let cmds = stopGroups().flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        t.expectEqual(cmds, ["echo sibling", "echo other-group"], "sibling hooks kept, ours gone")
        t.expectEqual(stopGroups().count, 2, "non-empty groups kept")
        t.expectEqual(ClaudeHook.status(script: script, binary: binary), .notInstalled, "after remove")
        t.expectEqual(ClaudeHook.remove(), "nothing to remove", "second remove is a no-op")
    }

    // remove() drops our group once it's empty, and the hooks key with it.
    sandbox { _, script, binary in
        try? fm.createDirectory(atPath: ClaudeHook.dir, withIntermediateDirectories: true)
        try? "{\"model\": \"opus\"}".write(toFile: ClaudeHook.settingsPath, atomically: true, encoding: .utf8)
        _ = ClaudeHook.install(script: script, binary: binary)
        t.expectEqual(settings()["model"] as? String, "opus", "install preserves other keys")
        _ = ClaudeHook.remove()
        t.expect(settings()["hooks"] == nil, "empty hooks dropped")
        t.expectEqual(settings()["model"] as? String, "opus", "remove preserves other keys")
    }

    // Invalid settings.json is left byte-for-byte alone, with an error.
    sandbox { _, script, binary in
        try? fm.createDirectory(atPath: ClaudeHook.dir, withIntermediateDirectories: true)
        let bad = "{ not json"
        try? bad.write(toFile: ClaudeHook.settingsPath, atomically: true, encoding: .utf8)
        let r = ClaudeHook.install(script: script, binary: binary)
        t.expect(r.hasPrefix("error"), "install on invalid JSON errors, got \(r)")
        t.expectEqual(try? String(contentsOfFile: ClaudeHook.settingsPath, encoding: .utf8), bad, "file untouched")
        t.expect(!fm.fileExists(atPath: ClaudeHook.scriptPath), "nothing else written either")
        t.expect(ClaudeHook.remove().hasPrefix("error"), "remove on invalid JSON errors")
        t.expectEqual(try? String(contentsOfFile: ClaudeHook.settingsPath, encoding: .utf8), bad, "still untouched")
    }

    // Not registered here, but copies exist: refresh them without registering.
    sandbox { _, script, binary in
        t.expectEqual(ClaudeHook.refreshFiles(script: script, binary: binary), "nothing to refresh", "no copies")
        try? fm.createDirectory(atPath: ClaudeHook.binDir, withIntermediateDirectories: true)
        try? "print('old')\n".write(toFile: ClaudeHook.scriptPath, atomically: true, encoding: .utf8)
        t.expectEqual(ClaudeHook.refreshFiles(script: script, binary: binary), "refreshed script", "only what exists")
        t.expect(fm.contentsEqual(atPath: ClaudeHook.scriptPath, andPath: script.path), "script refreshed")
        t.expect(!fm.fileExists(atPath: ClaudeHook.binPath), "binary not created")
        t.expect(!fm.fileExists(atPath: ClaudeHook.settingsPath), "nothing registered")
        try? "{ not json".write(toFile: ClaudeHook.settingsPath, atomically: true, encoding: .utf8)
        let c = ClaudeHook.check(script: script, binary: binary)
        t.expectEqual(c.status, .notInstalled, "unparseable settings")
        t.expect(c.problems.first?.contains("not valid JSON") == true, "and says why")
    }

    // A symlinked install target is written through, not replaced by a plain file.
    sandbox { dir, script, binary in
        _ = ClaudeHook.install(script: script, binary: binary)
        let real = dir + "/checkout-read-summary.py"
        try? "print('old')\n".write(toFile: real, atomically: true, encoding: .utf8)
        try? fm.removeItem(atPath: ClaudeHook.scriptPath)
        try? fm.createSymbolicLink(atPath: ClaudeHook.scriptPath, withDestinationPath: real)
        t.expectEqual(ClaudeHook.install(script: script, binary: binary), "installed", "install through link")
        let isLink = (try? fm.destinationOfSymbolicLink(atPath: ClaudeHook.scriptPath)) != nil
        t.expect(isLink, "still a symlink")
        t.expect(fm.contentsEqual(atPath: real, andPath: script.path), "its target was updated")
    }

    // Outside a test dir the command keeps its portable ~ form.
    unsetenv("SPEAKHUD_CLAUDE_DIR")
    t.expectEqual(ClaudeHook.hookCommand, "python3 ~/.claude/read-summary.py", "default command")
}
