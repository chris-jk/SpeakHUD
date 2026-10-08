// Hook tests. Registered in tests/main.swift.
//
// These run the REAL hook/read-summary.py in a sandbox: HOME and the queue are temp
// dirs, and PATH holds only a stub `say` that records its argv and stdin. Nothing
// here can reach the real ~/.claude, the real spool, or a speaker.
import Foundation

private let fm = FileManager.default

private let hookFile = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("hook/read-summary.py").path

/// python3 resolved from the runner's PATH, because the hook's PATH is only the stubs.
private let python: String = {
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin").split(separator: ":") {
        let p = "\(dir)/python3"
        if fm.isExecutableFile(atPath: p) { return p }
    }
    return "/usr/bin/python3"
}()

/// One sandbox: temp HOME, temp queue, a stub dir that is the whole PATH, a record dir.
private struct Sandbox {
    let root: String
    var home: String { root + "/home" }
    var queue: String { root + "/queue" }
    var bin: String { root + "/bin" }
    var rec: String { root + "/rec" }
    var hud: String { home + "/.claude/bin/speak-hud" }

    /// Seconds the hook keeps looking for a fresh heartbeat; 0 so a dead agent is quick.
    var grace = "0"

    init(_ label: String, say: Bool = true) {
        root = fm.temporaryDirectory.appendingPathComponent("speakhud-hook-\(label)-\(UUID().uuidString)").path
        for d in [home, queue, bin, rec] { try? fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        if say { stub(bin + "/say", name: "say") }
        // Real pgrep, so a process-list liveness check would be judged on its merits
        // (it fails the decoy tests below) rather than on a missing binary.
        try? fm.createSymbolicLink(atPath: bin + "/pgrep", withDestinationPath: "/usr/bin/pgrep")
    }

    /// A script that records argv (one per line) and stdin, then marks itself done.
    func stub(_ path: String, name: String) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let body = """
        #!/bin/sh
        for a in "$@"; do printf '%s\\n' "$a"; done > "\(rec)/\(name).args"
        /bin/cat > "\(rec)/\(name).stdin"
        : > "\(rec)/\(name).done"
        """
        executable(path, body)
    }

    func executable(_ path: String, _ body: String, mode: Int = 0o755) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data(body.utf8), attributes: [.posixPermissions: mode])
    }

    /// Runs `code` with the hook loaded as `hook`; argv[2...] are `args`.
    func run(_ code: String, args: [String] = [], stdin: String? = nil) -> (status: Int32, err: String) {
        let script = """
        import importlib.util, sys
        spec = importlib.util.spec_from_file_location("read_summary", sys.argv[1])
        hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hook)
        """ + "\n" + code
        return exec([python, "-c", script, hookFile] + args, stdin: stdin)
    }

    func exec(_ argv: [String], stdin: String? = nil) -> (status: Int32, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.environment = ["HOME": home, "PATH": bin, Spool.dirEnv: queue,
                         "SPEAKHUD_HEARTBEAT_GRACE": grace]
        let input = Pipe(), err = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        do { try p.run() } catch { return (-1, "\(error)") }
        if let s = stdin {
            input.fileHandleForWriting.write(Data(s.utf8))
            try? input.fileHandleForWriting.close()
        }
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (p.terminationStatus, msg)
    }

    /// The stub ran and finished reading stdin (it's a detached child of the hook).
    func waitFor(_ name: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fm.fileExists(atPath: "\(rec)/\(name).done") { return true }
            usleep(20_000)
        }
        return false
    }
    func ran(_ name: String) -> Bool { fm.fileExists(atPath: "\(rec)/\(name).args") }
    func args(_ name: String) -> [String] {
        ((try? String(contentsOfFile: "\(rec)/\(name).args", encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }
    func input(_ name: String) -> String? { try? String(contentsOfFile: "\(rec)/\(name).stdin", encoding: .utf8) }
    var queued: [String] { ((try? fm.contentsOfDirectory(atPath: queue)) ?? []).filter { $0.hasSuffix(".json") }.sorted() }
    func cleanup() { try? fm.removeItem(atPath: root) }
}

/// A process whose command line contains "speak-hud --agent" but is not the agent —
/// exactly what fooled the old `pgrep -f` check.
private func decoy() -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "sleep 30; : speak-hud --agent"]
    p.standardOutput = FileHandle.nullDevice
    try? p.run()
    return p
}

let hookSuite = Suite("Hook") { t in
    let speak = "import sys\nhook.speak_directly(sys.argv[2], sys.argv[3])"
    func clean(_ s: (status: Int32, err: String), _ what: String, file: StaticString = #file, line: UInt = #line) {
        t.expect(s.status == 0 && !s.err.contains("Traceback"),
                 "\(what): the hook doesn't raise (status \(s.status), \(s.err.suffix(300)))", file: file, line: line)
    }

    // -- say: the text is data, never an option ------------------------------------
    do {
        let sb = Sandbox("say-flag")
        let text = "-v Zarvox --rate 900 -o /tmp/pwned.aiff hello"
        clean(sb.run(speak, args: [text, "proj"]), "no HUD binary")
        t.expect(sb.waitFor("say"), "with no HUD binary, say is used")
        t.expectEqual(sb.args("say"), ["-f", "-"], "say gets no text in argv, only \"read stdin\"")
        t.expectEqual(sb.input("say"), text, "say reads the text, dashes and all, from stdin")
        sb.cleanup()
    }

    // -- a HUD binary that works is used, and say is not ---------------------------
    do {
        let sb = Sandbox("hud-ok")
        sb.stub(sb.hud, name: "hud")
        clean(sb.run(speak, args: ["Hello from the HUD.", "grow_guide_app"]), "working HUD")
        t.expect(sb.waitFor("hud"), "the HUD binary is run")
        t.expectEqual(sb.args("hud"), ["--source", "grow_guide_app"], "HUD gets --source <project>")
        t.expectEqual(sb.input("hud"), "Hello from the HUD.", "HUD reads the text from stdin")
        usleep(300_000)
        t.expect(!sb.ran("say"), "say is not also run when the HUD took it")
        sb.cleanup()
    }

    // -- the direct path passes the origin to the HUD -------------------------------
    do {
        let sb = Sandbox("hud-origin")
        sb.stub(sb.hud, name: "hud")
        let code = "hook.speak_directly('Hi.', 'proj', {'term': 'iTerm.app', 'tty': '/dev/ttys004'})"
        clean(sb.run(code), "HUD with origin")
        t.expect(sb.waitFor("hud"), "the HUD binary is run")
        let args = sb.args("hud")
        t.expectEqual(Array(args.prefix(3)), ["--source", "proj", "--origin"], "HUD gets --origin after --source")
        t.expectEqual(args.count == 4 ? Origin(jsonString: args[3]) : nil,
                      Origin(term: "iTerm.app", tty: "/dev/ttys004"), "…as JSON the HUD parses")
        sb.cleanup()
    }

    // -- a HUD binary that can't launch falls back to say --------------------------
    do {
        let sb = Sandbox("hud-noexec")
        sb.executable(sb.hud, "#!/bin/sh\nexit 0\n", mode: 0o644)   // present, not executable
        clean(sb.run(speak, args: ["Still heard.", "proj"]), "non-executable HUD")
        t.expect(sb.waitFor("say"), "a non-executable HUD falls back to say")
        t.expectEqual(sb.input("say"), "Still heard.", "…with the full text")
        sb.cleanup()
    }

    // -- a HUD that exits without reading (broken pipe) falls back to say ----------
    do {
        let sb = Sandbox("hud-pipe")
        sb.executable(sb.hud, "#!/bin/sh\nexit 1\n")
        // Bigger than any pipe buffer, so the write is guaranteed to hit EPIPE. Built in
        // Python: it's too big for an argv.
        let big = String(repeating: "All work and no play. ", count: 50_000)
        clean(sb.run("hook.speak_directly('All work and no play. ' * 50000, 'proj')"), "HUD exits without reading")
        t.expect(sb.waitFor("say"), "a broken pipe to the HUD falls back to say")
        t.expectEqual(sb.input("say")?.count, big.count, "…with the full text")
        sb.cleanup()
    }

    // -- a HUD that dies at launch on a SHORT turn (no broken pipe) falls back to say --
    do {
        let sb = Sandbox("hud-dies")
        sb.executable(sb.hud, "#!/bin/sh\nsleep 0.1\nexit 1\n")
        clean(sb.run(speak, args: ["Short turn.", "proj"]), "HUD dies at launch")
        t.expect(sb.waitFor("say"), "a HUD that exits non-zero at launch falls back to say")
        t.expectEqual(sb.input("say"), "Short turn.", "…with the full text")
        sb.cleanup()
    }

    // -- a heartbeat that goes fresh during the grace period counts (wake from sleep) --
    do {
        var sb = Sandbox("grace")
        sb.grace = "3"
        let beat = sb.queue + "/" + Spool.heartbeatName
        fm.createFile(atPath: beat, contents: nil)
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: beat)
        let code = """
        import sys, threading, os
        threading.Timer(0.6, lambda: os.utime(os.path.join(hook.QUEUE_DIR, hook.HEARTBEAT))).start()
        print('ALIVE' if hook.agent_running() else 'DEAD', file=sys.stderr)
        """
        t.expectEqual(sb.run(code).err.trimmingCharacters(in: .whitespacesAndNewlines), "ALIVE",
                      "a stale beat that the agent refreshes within the grace period is alive")
        sb.cleanup()
    }

    // -- nothing can speak: log it, don't raise ------------------------------------
    do {
        let sb = Sandbox("mute", say: false)
        let r = sb.run(speak, args: ["Nobody home.", "proj"])
        clean(r, "no HUD and no say")
        t.expect(r.err.contains("speakhud:"), "the failure is reported on stderr")
        sb.cleanup()
    }

    // -- heartbeat: Swift writes it, Python reads it --------------------------------
    do {
        let sb = Sandbox("beat")
        let d = decoy()
        defer { d.terminate(); d.waitUntilExit() }
        let alive = "print('ALIVE' if hook.agent_running() else 'DEAD', file=sys.stderr)"
        func state() -> String { sb.run("import sys\n" + alive).err.trimmingCharacters(in: .whitespacesAndNewlines) }
        let beat = sb.queue + "/" + Spool.heartbeatName

        t.expectEqual(state(), "DEAD",
                      "no heartbeat means no agent, even with \"speak-hud --agent\" in another command line")
        t.expect(Spool.beat(in: sb.queue), "beat() succeeds")
        t.expectEqual(state(), "ALIVE", "a fresh heartbeat means the agent is alive")

        let stale = sb.run("import sys\nprint(hook.HEARTBEAT_STALE, file=sys.stderr)").err
        let threshold = Double(stale.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        t.expect(threshold >= 3 * Spool.heartbeatInterval,
                 "the hook's threshold (\(threshold)s) tolerates two missed beats of \(Spool.heartbeatInterval)s")
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-(threshold - 2))], ofItemAtPath: beat)
        t.expectEqual(state(), "ALIVE", "a heartbeat just under the threshold is still alive")
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-(threshold + 1))], ofItemAtPath: beat)
        t.expectEqual(state(), "DEAD", "a stale heartbeat (hung or dead agent) is not alive")
        t.expect(Spool.beat(in: sb.queue), "beat() on an existing file succeeds")
        t.expectEqual(state(), "ALIVE", "the next beat revives it")

        try? fm.removeItem(atPath: sb.queue)
        t.expect(Spool.beat(in: sb.queue), "beat() recreates a removed spool dir")
        t.expectEqual(state(), "ALIVE", "…so the hook sees the agent again")

        // The spool must never treat the heartbeat as an item or as litter.
        let batch = Spool.drain(in: sb.queue, now: Date().addingTimeInterval(2 * Spool.maxAge))
        Spool.recover(in: sb.queue)
        t.expect(batch.items.isEmpty && batch.dropped.isEmpty, "drain ignores the heartbeat")
        t.expect(fm.fileExists(atPath: beat), "drain and recover leave the heartbeat alone")
        sb.cleanup()
    }

    // -- origin: where the turn came from ------------------------------------------
    do {
        let sb = Sandbox("origin")
        // A table shaped like real `ps -axo pid=,ppid=,tty=,comm=` output: a Claude in
        // VS Code's terminal, under a nested helper .app. Spaces in comm are kept.
        let ps = """
          1     0 ??       /sbin/launchd
        500     1 ??       /Applications/Visual Studio Code.app/Contents/MacOS/Electron
        510   500 ??       /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper
        520   510 ttys007  -zsh
        530   520 ttys007  claude
        540   530 ??       /bin/sh
        550   540 ??       python3
        """
        let code = """
        import sys, json
        print(json.dumps([hook.ancestry(sys.argv[2], 550), hook.ancestry(sys.argv[2], 9),
                          hook.ancestry("garbage\\n1 2", 550)]), file=sys.stderr)
        """
        let out = sb.run(code, args: [ps]).err.trimmingCharacters(in: .whitespacesAndNewlines)
        t.expectEqual(out, #"[["/dev/ttys007", 500], [null, null], [null, null]]"#,
                      "ancestry finds the first tty and the outermost .app; unknown pids and junk give nothing")

        let env = "import os, sys, json\n"
        let iterm = sb.run(env + """
        os.environ.update(TERM_PROGRAM="iTerm.app", ITERM_SESSION_ID="w4t0p0:41e78242-1097-4ff8-beff-75dd1d8cc4aa")
        print(json.dumps(hook.origin()), file=sys.stderr)
        """).err
        let o = Origin(jsonString: iterm)
        t.expectEqual(o?.term, "iTerm.app", "origin() records TERM_PROGRAM")
        t.expectEqual(o?.session, "41E78242-1097-4FF8-BEFF-75DD1D8CC4AA", "…and the iTerm2 session UUID, upper-cased")
        let bare = sb.run(env + """
        os.environ.pop("TERM_PROGRAM", None); os.environ["ITERM_SESSION_ID"] = "not-a-session"
        o = hook.origin(); print(json.dumps([o.get("term"), o.get("session")]), file=sys.stderr)
        """).err.trimmingCharacters(in: .whitespacesAndNewlines)
        t.expectEqual(bare, "[null, null]", "no TERM_PROGRAM and a junk session id leave both out")

        // The pill's color is asked of the hook that paints the terminal's window frame.
        t.expect(o != nil && o?.color == nil, "no terminal hook installed: no color")
        func color(_ terminalHook: String) -> String {
            let dir = sb.home + "/.claude/hooks"
            try? fm.removeItem(atPath: dir + "/__pycache__")   // same-second rewrites would reuse it
            sb.executable(dir + "/terminal-project.py", terminalHook, mode: 0o644)
            return sb.run(env + "print(json.dumps(hook.origin().get('color')), file=sys.stderr)")
                .err.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        t.expectEqual(color("def session_frame_color(): return '#40B2B2'"), "\"#40b2b2\"",
                      "origin() carries the terminal's frame color, lower-cased")
        t.expectEqual(color("def session_frame_color(): return None"), "null", "a session it hasn't colored has none")
        t.expectEqual(color("def session_frame_color(): return 'teal\" then beep'"), "null", "anything but #rrggbb is left out")
        t.expectEqual(color("def frame_color(app): return (0, 0, 0)"), "null", "a terminal hook from before it could say: none")
        t.expectEqual(color("import sys; sys.exit(3)"), "null", "a terminal hook that exits doesn't take the turn with it")

        // Real producer, real consumer: the origin survives the spool.
        clean(sb.run("hook.enqueue('Hi.', 'proj', 'k', {'term': 'Apple_Terminal', 'tty': '/dev/ttys009', 'app_pid': 321, 'color': '#40b2b2'})"),
              "enqueue with origin")
        let batch = Spool.drain(in: sb.queue)
        t.expectEqual(batch.items.first?.origin,
                      Origin(term: "Apple_Terminal", tty: "/dev/ttys009", appPID: 321, color: "#40b2b2"),
                      "the origin the hook writes is the origin the agent reads")
        clean(sb.run("hook.enqueue('Hi.', 'proj', 'k')"), "enqueue without origin")
        let plain = Spool.drain(in: sb.queue)
        t.expect(plain.items.count == 1 && plain.items[0].origin == nil, "no origin: the item is still read, with none")
        sb.cleanup()
    }

    // -- the whole hook: queue when the agent is alive, speak when it isn't --------
    do {
        let sb = Sandbox("main")
        let d = decoy()
        defer { d.terminate(); d.waitUntilExit() }
        let transcript = sb.root + "/t.jsonl"
        let lines: [[String: Any]] = [
            ["type": "user", "message": ["content": "hi"]],
            ["type": "assistant", "message": ["content": [["type": "text", "text": "Done — **all** tests pass."]]]],
        ]
        let body = lines.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            .joined(separator: "\n") + "\n"
        fm.createFile(atPath: transcript, contents: Data(body.utf8))
        let input = "{\"transcript_path\": \"\(transcript)\", \"session_id\": \"s1\", \"cwd\": \"/x/proj\"}"

        clean(sb.exec([python, hookFile], stdin: input), "hook, no heartbeat")
        t.expect(sb.waitFor("say"), "no heartbeat: the hook speaks the turn itself")
        t.expectEqual(sb.input("say"), "Done — all tests pass.", "…the cleaned turn")
        t.expectEqual(sb.queued, [], "…and queues nothing for an agent that isn't there")

        try? fm.removeItem(atPath: sb.rec + "/say.done")
        try? fm.removeItem(atPath: sb.rec + "/say.args")
        Spool.beat(in: sb.queue)
        clean(sb.exec([python, hookFile], stdin: input), "hook, fresh heartbeat")
        t.expectEqual(sb.queued.count, 1, "fresh heartbeat: the turn is queued for the agent")
        // A turn that has ended is one you can answer out loud: real hook, real drain.
        t.expectEqual(Spool.drain(in: sb.queue).items.map(\.answerable), [true],
                      "a finished turn is queued as answerable")
        usleep(300_000)
        t.expect(!sb.ran("say"), "…and not spoken here too")
        sb.cleanup()
    }

    // -- the pill is named after the session, as its window is ----------------------
    do {
        let sb = Sandbox("name")
        let transcript = sb.root + "/t.jsonl"
        let turn: [[String: Any]] = [
            ["type": "user", "message": ["content": "what does an ai-title entry look like?"]],
            ["type": "assistant", "message": ["content": [["type": "text", "text": "Done."]]]],
        ]
        /// The name the hook queues a turn under, for a transcript with these entries too.
        func name(_ extra: [[String: Any]], _ what: String) -> String? {
            let body = (turn + extra).map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
                .joined(separator: "\n") + "\n"
            fm.createFile(atPath: transcript, contents: Data(body.utf8))
            Spool.beat(in: sb.queue)
            clean(sb.exec([python, hookFile], stdin: "{\"transcript_path\": \"\(transcript)\", \"session_id\": \"s1\", \"cwd\": \"/x/proj\"}"), what)
            guard let file = sb.queued.last, let data = fm.contents(atPath: sb.queue + "/" + file),
                  let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return item["source"] as? String
        }
        t.expectEqual(name([], "no title"), "proj",
                      "a session with no title yet goes by its folder (a turn that only mentions titles isn't one)")
        t.expectEqual(name([["type": "ai-title", "aiTitle": "First guess", "sessionId": "s1"],
                            ["type": "ai-title", "aiTitle": "Pill  navigation\n", "sessionId": "s1"]], "titled"),
                      "Pill navigation", "a titled session goes by its newest title, on one line")
        t.expectEqual(name([["type": "custom-title", "customTitle": "My name for it", "sessionId": "s1"],
                            ["type": "ai-title", "aiTitle": "Claude's name for it", "sessionId": "s1"]], "renamed"),
                      "My name for it", "a name the user gave it beats Claude's, whichever came last")
        t.expectEqual(name([["type": "ai-title", "aiTitle": "  ", "sessionId": "s1"]], "blank title"), "proj",
                      "a blank title is no title")
        sb.cleanup()
    }

    // -- what the turn made goes with it, for the phone to show ----------------------
    do {
        let sb = Sandbox("media")
        let work = sb.root + "/work", clips = work + "/My Clips"
        try? fm.createDirectory(atPath: clips, withIntermediateDirectories: true)
        let began = Date().addingTimeInterval(-60)
        /// A file stamped `age` seconds after the turn began (before it, when negative).
        func make(_ path: String, age: TimeInterval) {
            fm.createFile(atPath: path, contents: Data("x".utf8))
            let at = began.addingTimeInterval(age)
            try? fm.setAttributes([.creationDate: at, .modificationDate: at], ofItemAtPath: path)
        }
        make(work + "/shot.png", age: 5)                // named bare in a command, found in its folder
        make(clips + "/out one.mp4", age: 10)           // a path with spaces, quoted in a command
        make(clips + "/voice over.m4a", age: 15)        // a path with spaces, said in a tool's output
        make(work + "/escaped name.jpg", age: 20)       // spaces escaped the shell's way
        make(work + "/old.png", age: -3600)             // there before the turn: only named, not made
        make(work + "/before.gif", age: -3600)          // there before the turn, and named in its words
        make(work + "/notes.txt", age: 5)               // not a kind the phone shows
        make(work + "/earlier.png", age: -30)           // made by the turn before this one
        let stamp = ISO8601DateFormatter()
        func entry(_ type: String, _ content: Any, at: TimeInterval, meta: Bool = false) -> [String: Any] {
            var e: [String: Any] = ["type": type, "message": ["content": content], "cwd": work,
                                    "timestamp": stamp.string(from: began.addingTimeInterval(at))]
            if meta { e["isMeta"] = true }
            return e
        }
        func tool(_ command: String) -> [[String: Any]] { [["type": "tool_use", "name": "Bash", "input": ["command": command]]] }
        func result(_ text: Any) -> [[String: Any]] { [["type": "tool_result", "tool_use_id": "t", "content": text]] }
        let lines: [[String: Any]] = [
            entry("user", "make the earlier one", at: -40),
            entry("assistant", tool("render \(work)/earlier.png"), at: -35),
            entry("user", result("ok"), at: -31),
            entry("assistant", [["type": "text", "text": "Made."]], at: -30),
            entry("user", "now the clip, the voice and a screenshot", at: 0),
            entry("assistant", tool("screencapture shot.png && cat notes.txt && ls old.png \(work)/earlier.png"), at: 4),
            entry("user", result("shot.png\nold.png"), at: 6),
            entry("user", "a note Claude Code added by itself", at: 7, meta: true),
            entry("assistant", tool("ffmpeg -i in.mov \"\(clips)/out one.mp4\" && convert a.png \(work)/escaped\\ name.jpg"), at: 9),
            entry("user", result([["type": "text", "text": "wrote 1 file\nSaved to \(clips)/voice over.m4a (12 s). See https://example.com/a.png"]]), at: 16),
            entry("assistant", [["type": "text", "text": "The clip is ready. The old loop is `\(work)/before.gif`."]], at: 21),
        ]
        let transcript = sb.root + "/t.jsonl"
        let body = lines.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n") + "\n"
        fm.createFile(atPath: transcript, contents: Data(body.utf8))
        Spool.beat(in: sb.queue)
        clean(sb.exec([python, hookFile], stdin: "{\"transcript_path\": \"\(transcript)\", \"session_id\": \"s1\", \"cwd\": \"\(work)\"}"),
              "a turn that made files")
        let item = sb.queued.last.flatMap { fm.contents(atPath: sb.queue + "/" + $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let media = (item?["media"] as? [String] ?? []).map { $0.replacingOccurrences(of: work + "/", with: "") }
        t.expectEqual(media, ["shot.png", "My Clips/out one.mp4", "My Clips/voice over.m4a", "escaped name.jpg", "before.gif"],
                      "what the turn's tool calls made, oldest first, then what its words name: not what was only listed, what the turn before made, or a text file")
        t.expectEqual(Spool.drain(in: sb.queue).items.first?.media.count ?? 0, 5, "and the agent reads the same list off the spool")

        // The list is cut to the newest, and what the turn's words name is kept first.
        let many = (0..<20).map { i -> String in
            let path = work + "/frame\(String(format: "%02d", i)).png"
            make(path, age: 30 + Double(i))
            return path
        }
        let cut = sb.run("""
        import json
        named = [sys.argv[3] + "/before.gif", sys.argv[3] + "/missing.png", sys.argv[3] + "/notes.txt"]
        print(json.dumps(hook.turn_media(sys.argv[2], named, sys.argv[3])), file=sys.stderr)
        """, args: [transcript + ".many", work])
        var more = lines
        more.insert(entry("assistant", tool("render " + many.joined(separator: " ")), at: 18), at: lines.count - 1)
        let longer = more.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n") + "\n"
        fm.createFile(atPath: transcript + ".many", contents: Data(longer.utf8))
        let kept = sb.run("""
        import json
        named = [sys.argv[3] + "/before.gif", sys.argv[3] + "/missing.png", sys.argv[3] + "/notes.txt"]
        print(json.dumps(hook.turn_media(sys.argv[2], named, sys.argv[3])), file=sys.stderr)
        """, args: [transcript + ".many", work])
        let list = (try? JSONSerialization.jsonObject(with: Data(kept.err.utf8)) as? [String]) ?? []
        t.expect(cut.status == 0 && (try? JSONSerialization.jsonObject(with: Data(cut.err.utf8)) as? [String]) == [work + "/before.gif"],
                 "a transcript that isn't there: only what the words name, if it's there and a kind the phone shows")
        t.expect(list.count == 12 && list.last == work + "/before.gif" && list.first == work + "/frame09.png" && list[10] == work + "/frame19.png",
                 "more than the phone takes: the newest are kept, and the one the turn named (got \(list.map { ($0 as NSString).lastPathComponent }))")
        sb.cleanup()
    }
}
