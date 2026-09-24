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
        usleep(300_000)
        t.expect(!sb.ran("say"), "…and not spoken here too")
        sb.cleanup()
    }
}
