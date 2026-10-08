// ClaudeHook tests. Registered in tests/main.swift.
// Every test runs against a fresh temp dir via SPEAKHUD_CLAUDE_DIR — never the real
// ~/.claude — and passes the script/binary sources explicitly (there's no app bundle).
import Foundation

let claudeHookSuite = Suite("ClaudeHook") { t in
    let fm = FileManager.default

    // A fresh claude dir plus sources to install from: the two scripts and a small executable.
    func sandbox(_ body: (_ dir: String, _ script: URL, _ question: URL, _ binary: URL) -> Void) {
        let root = NSTemporaryDirectory() + "speakhud-hook-\(UUID().uuidString)"
        let dir = root + "/claude", src = root + "/src"
        try? fm.createDirectory(atPath: src, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: src + "/read-summary.py")
        try? "print('hello')\n".write(to: script, atomically: true, encoding: .utf8)
        let question = URL(fileURLWithPath: src + "/read-question.py")
        try? "print('which?')\n".write(to: question, atomically: true, encoding: .utf8)
        let binary = URL(fileURLWithPath: src + "/speak-hud")
        try? fm.copyItem(atPath: "/bin/echo", toPath: binary.path)
        setenv("SPEAKHUD_CLAUDE_DIR", dir, 1)
        defer { unsetenv("SPEAKHUD_CLAUDE_DIR"); try? fm.removeItem(atPath: root) }
        body(dir, script, question, binary)
    }
    func settings() -> [String: Any] {
        guard let d = fm.contents(atPath: ClaudeHook.settingsPath),
              let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return r
    }
    func groups(_ event: String) -> [[String: Any]] {
        (settings()["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }
    func stopGroups() -> [[String: Any]] { groups("Stop") }
    /// How many entries run each of our scripts: [Stop, PreToolUse, PostToolUse].
    func ourEntries() -> [Int] {
        [("Stop", "read-summary.py"), ("PreToolUse", "read-question.py"), ("PostToolUse", "read-question.py")].map { event, name in
            groups(event).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .filter { ($0["command"] as? String)?.contains(name) == true }.count
        }
    }
    func put(_ root: [String: Any]) {
        try? fm.createDirectory(atPath: ClaudeHook.dir, withIntermediateDirectories: true)
        fm.createFile(atPath: ClaudeHook.settingsPath, contents: try! JSONSerialization.data(withJSONObject: root))
    }
    func same(_ a: [String: Any], _ b: [String: Any]) -> Bool { NSDictionary(dictionary: a).isEqual(to: b) }

    // The shape of the `hooks` key on the author's Mac on 2026-10-08, the day the app took
    // over the question hook (other tools' commands swapped for echoes): the Stop entry the
    // app wrote, sharing its group with someone else's hook; the question hook's two entries
    // added by hand, each alone in an AskUserQuestion group after other tools' groups; and
    // events the app has nothing to do with. `stop: false` and `questions: false` are the
    // same file without the Stop entry and without the question hook's two.
    func handInstalled(summary: String = "", question: String = "",
                       stop: Bool = true, questions: Bool = true) -> [String: Any] {
        func hook(_ command: String, _ more: [String: Any] = [:]) -> [String: Any] {
            more.merging(["type": "command", "command": command]) { a, _ in a }
        }
        let shared: [Any] = (stop ? [hook("python3 \(summary)", ["async": true])] : [])
            + [hook("echo stop-sibling", ["async": true, "timeout": 30, "statusMessage": "Saving"])]
        let pre: [Any] = [
            ["matcher": "Bash", "hooks": [hook("echo pre-bash", ["statusMessage": "Checking"])]],
            ["matcher": "Bash", "hooks": [hook("echo pre-bash-2", ["if": "Bash(git *)", "timeout": 5])]],
            ["matcher": "Skill", "hooks": [hook("echo pre-skill", ["timeout": 5])]],
        ] + (questions ? [["matcher": "AskUserQuestion",
                           "hooks": [hook("python3 \(question)", ["async": true, "timeout": 600])]]] : [])
        let post: [Any] = [
            ["matcher": "Edit|Write", "hooks": [hook("echo post-edit", ["async": true, "timeout": 10])]],
        ] + (questions ? [["matcher": "AskUserQuestion",
                           "hooks": [hook("python3 \(question) --answered", ["timeout": 5])]]] : [])
        return ["model": "opus", "hooks": [
            "Stop": [["hooks": shared], ["hooks": [hook("echo stop-other", ["async": true, "timeout": 10])]]],
            "PreToolUse": pre,
            "PostToolUse": post,
            "SessionStart": [["hooks": [hook("echo start", ["async": true])]],
                             ["matcher": "startup|resume|clear", "hooks": [hook("echo start-2")]]],
            "SessionEnd": [["hooks": [hook("echo end", ["async": true, "timeout": 10])]]],
            "UserPromptSubmit": [["hooks": [hook("echo prompt", ["timeout": 5])]]],
        ]]
    }
    // The two ways the commands are spelt: as that Mac has them, and pointed into the sandbox.
    func spellings(_ dir: String) -> [(summary: String, question: String)] {
        [("~/.claude/read-summary.py", "~/.claude/hooks/read-question.py"),
         ("\(dir)/read-summary.py", "\(dir)/hooks/read-question.py")]
    }

    // Fresh install writes every piece: both scripts, the binary, and the three entries.
    sandbox { dir, script, question, binary in
        t.expect(ClaudeHook.settingsPath.hasPrefix(dir), "override points settings at the temp dir")
        t.expectEqual(ClaudeHook.status(script: script, question: question, binary: binary), .notInstalled, "empty dir")
        t.expectEqual(ClaudeHook.install(script: script, question: question, binary: binary), "installed", "fresh install")
        t.expect(fm.contentsEqual(atPath: ClaudeHook.scriptPath, andPath: script.path), "script written")
        t.expectEqual(ClaudeHook.questionPath, dir + "/hooks/read-question.py", "the question script goes in hooks/")
        t.expect(fm.contentsEqual(atPath: ClaudeHook.questionPath, andPath: question.path), "question script written")
        t.expect(fm.isExecutableFile(atPath: ClaudeHook.binPath), "binary written and executable")
        let cmd = ((stopGroups().first?["hooks"] as? [[String: Any]])?.first?["command"] as? String) ?? ""
        t.expect(cmd.contains(ClaudeHook.scriptPath), "command runs the overridden script, got \(cmd)")
        let q = ClaudeHook.questionCommand
        t.expect(q.contains(ClaudeHook.questionPath), "the question command runs the overridden script, got \(q)")
        // Exactly these three, and nothing else, go into settings.json.
        let wanted: [String: Any] = ["hooks": [
            "Stop": [["hooks": [["type": "command", "command": ClaudeHook.hookCommand, "async": true]]]],
            "PreToolUse": [["matcher": "AskUserQuestion", "hooks": [
                ["type": "command", "command": q, "async": true, "timeout": 600]]]],
            "PostToolUse": [["matcher": "AskUserQuestion", "hooks": [
                ["type": "command", "command": q + " --answered", "timeout": 5]]]],
        ]]
        t.expect(same(settings(), wanted), "the three entries as written, got \(settings())")
        t.expectEqual(ClaudeHook.status(script: script, question: question, binary: binary), .installed, "after install")
        _ = ClaudeHook.install(script: script, question: question, binary: binary)
        t.expect(same(settings(), wanted), "reinstall doesn't add a second entry anywhere, got \(settings())")
    }

    // Installing over the entries put in by hand recognises all three as ours: none is
    // added twice, settings.json isn't rewritten at all, and the hand-copied script is
    // replaced by this build's.
    sandbox { dir, script, question, binary in
        for s in spellings(dir) {
            put(handInstalled(summary: s.summary, question: s.question))
            try? fm.createDirectory(atPath: ClaudeHook.hooksDir, withIntermediateDirectories: true)
            try? "print('copied by hand')\n".write(toFile: ClaudeHook.questionPath, atomically: true, encoding: .utf8)
            let before = fm.contents(atPath: ClaudeHook.settingsPath)
            t.expectEqual(ClaudeHook.install(script: script, question: question, binary: binary), "installed",
                          "install over a hand install (\(s.question))")
            t.expectEqual(ourEntries(), [1, 1, 1], "each of ours still there once (\(s.question))")
            t.expect(fm.contents(atPath: ClaudeHook.settingsPath) == before,
                     "settings.json left byte for byte (\(s.question))")
            t.expect(fm.contentsEqual(atPath: ClaudeHook.questionPath, andPath: question.path),
                     "the question script is this build's now (\(s.question))")
        }
    }

    // An install from before the app knew the question hook holds the Stop entry only. The
    // next install adds the other two, after whatever else is on those events.
    sandbox { _, script, question, binary in
        put(handInstalled(summary: "~/.claude/read-summary.py", questions: false))
        t.expectEqual(ClaudeHook.install(script: script, question: question, binary: binary), "installed", "upgrade")
        t.expect(same(settings(), handInstalled(summary: "~/.claude/read-summary.py",
                                                question: "'\(ClaudeHook.questionPath)'")),
                 "Stop entry kept, the question hook's two added, nothing else changed, got \(settings())")
        t.expect(fm.contentsEqual(atPath: ClaudeHook.questionPath, andPath: question.path), "and its script")
    }

    // Tampered script -> stale; reinstall repairs it.
    sandbox { _, script, question, binary in
        _ = ClaudeHook.install(script: script, question: question, binary: binary)
        try? "print('old')\n".write(toFile: ClaudeHook.scriptPath, atomically: true, encoding: .utf8)
        let c = ClaudeHook.check(script: script, question: question, binary: binary)
        t.expectEqual(c.status, .stale, "tampered script")
        t.expect(!c.problems.isEmpty, "stale says why")
        t.expectEqual(ClaudeHook.install(script: script, question: question, binary: binary), "installed", "repair")
        t.expectEqual(ClaudeHook.status(script: script, question: question, binary: binary), .installed, "after repair")
    }

    // The same for the question script: a different or missing copy is stale, and says which.
    sandbox { _, script, question, binary in
        _ = ClaudeHook.install(script: script, question: question, binary: binary)
        try? "print('old')\n".write(toFile: ClaudeHook.questionPath, atomically: true, encoding: .utf8)
        var c = ClaudeHook.check(script: script, question: question, binary: binary)
        t.expectEqual(c.status, .stale, "tampered question script")
        t.expectEqual(c.problems, ["question script differs from bundled copy"], "and only that is wrong")
        t.expectEqual(ClaudeHook.status(script: script, question: nil, binary: binary), .installed,
                      "with nothing to compare it to, being there is enough")
        try? fm.removeItem(atPath: ClaudeHook.questionPath)
        c = ClaudeHook.check(script: script, question: nil, binary: binary)
        t.expectEqual(c.status, .stale, "missing question script")
        t.expectEqual(c.problems, ["question script missing"], "and only that is wrong")
        t.expectEqual(ClaudeHook.install(script: script, question: question, binary: binary), "installed", "repair")
        t.expectEqual(ClaudeHook.status(script: script, question: question, binary: binary), .installed, "after repair")
    }

    // Some of our entries but not all is stale too, naming the ones to add; none is not
    // installed, whatever else is on those events; and the hand install is installed.
    sandbox { dir, script, question, binary in
        func check(_ root: [String: Any]) -> (status: ClaudeHook.Status, problems: [String]) {
            put(root)
            return ClaudeHook.check(script: script, question: question, binary: binary)
        }
        _ = ClaudeHook.install(script: script, question: question, binary: binary)   // the files
        let mine = spellings(dir)[1]
        // From before the question hook was ours: a rebuild asks the status, and "stale" is
        // what makes it run the install that adds the other two.
        var c = check(handInstalled(summary: mine.summary, questions: false))
        t.expectEqual(c.status, .stale, "Stop entry only")
        t.expectEqual(c.problems, ["PreToolUse hook not registered", "PostToolUse hook not registered"], "…says which")
        t.expectEqual(ClaudeHook.install(script: script, question: question, binary: binary), "installed", "upgrade")
        t.expectEqual(ClaudeHook.status(script: script, question: question, binary: binary), .installed, "after upgrade")
        // What unticking the menu item used to leave behind.
        c = check(handInstalled(question: mine.question, stop: false))
        t.expectEqual(c.status, .stale, "question entries only")
        t.expectEqual(c.problems, ["Stop hook not registered"], "…says which")
        c = check(handInstalled(stop: false, questions: false))
        t.expectEqual(c.status, .notInstalled, "other tools' hooks on our events aren't ours")
        t.expect(c.problems.isEmpty, "…and nothing is wrong with that")
        for s in spellings(dir) {
            c = check(handInstalled(summary: s.summary, question: s.question))
            t.expectEqual(c.status, .installed, "the hand install is ours (\(s.question)), problems \(c.problems)")
        }
    }

    // Missing binary -> stale.
    sandbox { _, script, question, binary in
        _ = ClaudeHook.install(script: script, question: question, binary: binary)
        try? fm.removeItem(atPath: ClaudeHook.binPath)
        t.expectEqual(ClaudeHook.status(script: script, question: question, binary: binary), .stale, "missing binary")
    }

    // Running `~/.claude/bin/speak-hud --setup-claude`: source IS the destination. The old
    // remove-then-copy deleted the binary and then had nothing to copy.
    sandbox { _, script, question, binary in
        _ = ClaudeHook.install(script: script, question: question, binary: binary)
        let installed = URL(fileURLWithPath: ClaudeHook.binPath)
        let r = ClaudeHook.install(script: script, question: question, binary: installed)
        t.expectEqual(r, "installed", "self-install succeeds")
        t.expect(fm.isExecutableFile(atPath: ClaudeHook.binPath), "self-install keeps the binary")
        t.expect(fm.contentsEqual(atPath: ClaudeHook.binPath, andPath: binary.path), "binary intact")
    }

    // An unreadable binary source is reported, not swallowed, and the old binary survives.
    sandbox { dir, script, question, binary in
        _ = ClaudeHook.install(script: script, question: question, binary: binary)
        let r = ClaudeHook.install(script: script, question: question, binary: URL(fileURLWithPath: dir + "/nope"))
        t.expect(r.hasPrefix("error") && r.contains("binary"), "failed copy is reported, got \(r)")
        t.expect(fm.isExecutableFile(atPath: ClaudeHook.binPath), "failed copy leaves the old binary")
    }

    // No script source and none on disk: error, and the hook isn't registered.
    sandbox { _, _, question, binary in
        let r = ClaudeHook.install(script: nil, question: question, binary: binary)
        t.expect(r.hasPrefix("error"), "no script source is an error, got \(r)")
        t.expect(settings().isEmpty, "no hook registered without a script, got \(settings())")
    }

    // The same for the question script, and then neither hook goes in: its entries would
    // run nothing. A copy already there is enough (running outside the app bundle, as
    // ~/.claude/bin/speak-hud, there is nothing to copy from) and is left as it is.
    sandbox { _, script, _, binary in
        let r = ClaudeHook.install(script: script, question: nil, binary: binary)
        t.expect(r.hasPrefix("error") && r.contains("read-question.py"), "no question script is an error, got \(r)")
        t.expect(settings().isEmpty, "neither hook registered without it, got \(settings())")
        try? fm.createDirectory(atPath: ClaudeHook.hooksDir, withIntermediateDirectories: true)
        try? "print('already here')\n".write(toFile: ClaudeHook.questionPath, atomically: true, encoding: .utf8)
        t.expectEqual(ClaudeHook.install(script: script, question: nil, binary: binary), "installed", "a copy on disk will do")
        t.expectEqual(ourEntries(), [1, 1, 1], "and all three entries go in")
        t.expectEqual(try? String(contentsOfFile: ClaudeHook.questionPath, encoding: .utf8), "print('already here')\n",
                      "the copy is left alone")
    }

    // A `hooks` key, or one of our events under it, in a shape we don't know: an error, and
    // the file is left byte for byte alone rather than overwritten with our entries.
    sandbox { _, script, question, binary in
        try? fm.createDirectory(atPath: ClaudeHook.dir, withIntermediateDirectories: true)
        for odd in ["{\"hooks\": [1, 2]}", "{\"hooks\": {\"PreToolUse\": {\"matcher\": \"Bash\"}}}"] {
            try? odd.write(toFile: ClaudeHook.settingsPath, atomically: true, encoding: .utf8)
            let r = ClaudeHook.install(script: script, question: question, binary: binary)
            t.expect(r.hasPrefix("error"), "install over \(odd) errors, got \(r)")
            t.expectEqual(try? String(contentsOfFile: ClaudeHook.settingsPath, encoding: .utf8), odd, "file untouched")
            t.expect(!fm.fileExists(atPath: ClaudeHook.questionPath), "nothing else written either")
        }
    }

    // Groups and entries we can't read are carried through an install and a remove.
    sandbox { _, script, question, binary in
        let odd: [String: Any] = ["hooks": [
            "PreToolUse": ["a string", ["matcher": "Bash", "hooks": "not a list"]],
            "Stop": [["hooks": [42, ["type": "prompt", "prompt": "done?"]]]],
        ]]
        put(odd)
        t.expectEqual(ClaudeHook.install(script: script, question: question, binary: binary), "installed", "install beside odd groups")
        t.expectEqual((settings()["hooks"] as? [String: Any])?.count, 3, "our three events are there")
        t.expectEqual(ClaudeHook.remove(), "removed", "remove beside odd groups")
        t.expect(same(settings(), odd), "the odd groups are as they were, got \(settings())")
    }

    // remove() keeps a sibling hook that shares our group.
    sandbox { _, script, question, binary in
        _ = ClaudeHook.install(script: script, question: question, binary: binary)
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
        t.expectEqual(ClaudeHook.status(script: script, question: question, binary: binary), .notInstalled, "after remove")
        t.expectEqual(ClaudeHook.remove(), "nothing to remove", "second remove is a no-op")
    }

    // remove() takes out the question hook's two entries with the Stop entry, so unticking
    // the menu item stops questions being read too, and leaves everyone else's hooks, on
    // every event, exactly as they were.
    sandbox { dir, _, _, _ in
        for s in spellings(dir) {
            put(handInstalled(summary: s.summary, question: s.question))
            t.expectEqual(ClaudeHook.remove(), "removed", "remove over a hand install (\(s.question))")
            t.expect(same(settings(), handInstalled(stop: false, questions: false)),
                     "our three entries gone, nothing else changed (\(s.question)), got \(settings())")
            t.expectEqual(ClaudeHook.remove(), "nothing to remove", "second remove is a no-op")
        }
    }

    // Someone else's hook sharing the question hook's group stays, matcher and all.
    sandbox { _, _, _, _ in
        let theirs: [String: Any] = ["type": "command", "command": "echo question-sibling"]
        func group(_ ourCommand: String?) -> [String: Any] {
            let ours: [Any] = ourCommand.map { [["type": "command", "command": $0, "timeout": 5]] } ?? []
            return ["matcher": "AskUserQuestion", "hooks": ours + [theirs]]
        }
        put(["hooks": ["PreToolUse": [group("python3 ~/.claude/hooks/read-question.py")],
                       "PostToolUse": [group("python3 ~/.claude/hooks/read-question.py --answered")]]])
        t.expectEqual(ClaudeHook.remove(), "removed", "question entries alone are ours to remove")
        t.expect(same(settings(), ["hooks": ["PreToolUse": [group(nil)], "PostToolUse": [group(nil)]]]),
                 "the sibling keeps its group and matcher, got \(settings())")
    }

    // remove() drops our group once it's empty, and the hooks key with it.
    sandbox { _, script, question, binary in
        try? fm.createDirectory(atPath: ClaudeHook.dir, withIntermediateDirectories: true)
        try? "{\"model\": \"opus\"}".write(toFile: ClaudeHook.settingsPath, atomically: true, encoding: .utf8)
        _ = ClaudeHook.install(script: script, question: question, binary: binary)
        t.expectEqual(settings()["model"] as? String, "opus", "install preserves other keys")
        _ = ClaudeHook.remove()
        t.expect(settings()["hooks"] == nil, "empty hooks dropped")
        t.expectEqual(settings()["model"] as? String, "opus", "remove preserves other keys")
    }

    // Invalid settings.json is left byte-for-byte alone, with an error.
    sandbox { _, script, question, binary in
        try? fm.createDirectory(atPath: ClaudeHook.dir, withIntermediateDirectories: true)
        let bad = "{ not json"
        try? bad.write(toFile: ClaudeHook.settingsPath, atomically: true, encoding: .utf8)
        let r = ClaudeHook.install(script: script, question: question, binary: binary)
        t.expect(r.hasPrefix("error"), "install on invalid JSON errors, got \(r)")
        t.expectEqual(try? String(contentsOfFile: ClaudeHook.settingsPath, encoding: .utf8), bad, "file untouched")
        t.expect(!fm.fileExists(atPath: ClaudeHook.scriptPath), "nothing else written either")
        t.expect(ClaudeHook.remove().hasPrefix("error"), "remove on invalid JSON errors")
        t.expectEqual(try? String(contentsOfFile: ClaudeHook.settingsPath, encoding: .utf8), bad, "still untouched")
    }

    // Not registered here, but copies exist: refresh them without registering.
    sandbox { _, script, question, binary in
        t.expectEqual(ClaudeHook.refreshFiles(script: script, question: question, binary: binary), "nothing to refresh", "no copies")
        try? fm.createDirectory(atPath: ClaudeHook.binDir, withIntermediateDirectories: true)
        try? "print('old')\n".write(toFile: ClaudeHook.scriptPath, atomically: true, encoding: .utf8)
        t.expectEqual(ClaudeHook.refreshFiles(script: script, question: question, binary: binary), "refreshed script", "only what exists")
        t.expect(fm.contentsEqual(atPath: ClaudeHook.scriptPath, andPath: script.path), "script refreshed")
        t.expect(!fm.fileExists(atPath: ClaudeHook.questionPath), "question script not created")
        t.expect(!fm.fileExists(atPath: ClaudeHook.binPath), "binary not created")
        t.expect(!fm.fileExists(atPath: ClaudeHook.settingsPath), "nothing registered")
        // A copy of the question script is refreshed the same way: an old one would go on
        // importing the new read-summary.py beside the new agent.
        try? fm.createDirectory(atPath: ClaudeHook.hooksDir, withIntermediateDirectories: true)
        try? "print('old')\n".write(toFile: ClaudeHook.questionPath, atomically: true, encoding: .utf8)
        t.expectEqual(ClaudeHook.refreshFiles(script: script, question: question, binary: binary),
                      "refreshed script, question script", "the question script too")
        t.expect(fm.contentsEqual(atPath: ClaudeHook.questionPath, andPath: question.path), "question script refreshed")
        t.expect(!fm.fileExists(atPath: ClaudeHook.settingsPath), "still nothing registered")
        try? "{ not json".write(toFile: ClaudeHook.settingsPath, atomically: true, encoding: .utf8)
        let c = ClaudeHook.check(script: script, question: question, binary: binary)
        t.expectEqual(c.status, .notInstalled, "unparseable settings")
        t.expect(c.problems.first?.contains("not valid JSON") == true, "and says why")
    }

    // A symlinked install target is written through, not replaced by a plain file.
    sandbox { dir, script, question, binary in
        _ = ClaudeHook.install(script: script, question: question, binary: binary)
        let real = dir + "/checkout-read-summary.py"
        try? "print('old')\n".write(toFile: real, atomically: true, encoding: .utf8)
        try? fm.removeItem(atPath: ClaudeHook.scriptPath)
        try? fm.createSymbolicLink(atPath: ClaudeHook.scriptPath, withDestinationPath: real)
        t.expectEqual(ClaudeHook.install(script: script, question: question, binary: binary), "installed", "install through link")
        let isLink = (try? fm.destinationOfSymbolicLink(atPath: ClaudeHook.scriptPath)) != nil
        t.expect(isLink, "still a symlink")
        t.expect(fm.contentsEqual(atPath: real, andPath: script.path), "its target was updated")
    }

    // build.sh puts every hook script in the app's Resources, which is where an install
    // copies them from. build.sh can't be run from a test, so this reads it.
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let build = (try? String(contentsOf: repo.appendingPathComponent("build.sh"), encoding: .utf8)) ?? ""
    let scripts = ((try? fm.contentsOfDirectory(atPath: repo.appendingPathComponent("hook").path)) ?? [])
        .filter { $0.hasSuffix(".py") }.sorted()
    t.expectEqual(scripts, ["read-question.py", "read-summary.py"], "the hook scripts there are")
    for s in scripts {
        t.expect(build.contains("\ncp hook/\(s) \"$STAGE/Contents/Resources/\(s)\""), "build.sh bundles \(s)")
    }

    // Outside a test dir the command keeps its portable ~ form.
    unsetenv("SPEAKHUD_CLAUDE_DIR")
    t.expectEqual(ClaudeHook.hookCommand, "python3 ~/.claude/read-summary.py", "default command")
    t.expectEqual(ClaudeHook.questionCommand, "python3 ~/.claude/hooks/read-question.py",
                  "and the question hook's, spelt as the hand install spelt it")
}
