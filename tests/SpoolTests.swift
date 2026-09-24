// Spool tests. Registered in tests/main.swift.
//
// The spool is a contract between two languages: hook/read-summary.py writes it and
// Spool.drain reads it. The first case runs the REAL Python enqueue() into a temp dir
// and the REAL Swift drain over the same dir, so a renamed field, a moved directory or
// a drifted override variable fails here instead of going silently unheard.
import Foundation

private let fm = FileManager.default

private func tempDir(_ label: String) -> String {
    let d = fm.temporaryDirectory.appendingPathComponent("speakhud-spool-\(label)-\(UUID().uuidString)").path
    try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private let hookPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("hook/read-summary.py").path

/// Runs the hook's own enqueue() for each item, with the queue override pointing at
/// `queue`. HOME is redirected too, so even an ignored override can't reach the real
/// spool; the assert makes that case fail loudly rather than write somewhere else.
private func pythonEnqueue(_ items: [[String: String]], into queue: String, home: String) -> (Int32, String) {
    let script = """
    import importlib.util, json, os, sys
    spec = importlib.util.spec_from_file_location("read_summary", sys.argv[1])
    hook = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hook)
    assert hook.QUEUE_DIR == os.environ["\(Spool.dirEnv)"], "hook ignores the override: " + hook.QUEUE_DIR
    for it in json.loads(sys.argv[2]):
        hook.enqueue(it["text"], it["source"], it["key"])
    """
    let json = String(data: try! JSONSerialization.data(withJSONObject: items), encoding: .utf8)!
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", "-c", script, hookPath, json]
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = home
    env[Spool.dirEnv] = queue
    p.environment = env
    let err = Pipe()
    p.standardError = err
    do { try p.run() } catch { return (-1, "\(error)") }
    let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return (p.terminationStatus, msg)
}

private func write(_ dir: String, _ name: String, _ body: Any, mtime: Date? = nil) {
    let data: Data
    if let raw = body as? String { data = raw.data(using: .utf8)! }
    else { data = try! JSONSerialization.data(withJSONObject: body) }
    let path = dir + "/" + name
    fm.createFile(atPath: path, contents: data)
    if let m = mtime { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: path) }
}

private func files(_ dir: String) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() }

let spoolSuite = Suite("Spool") { t in
    // -- contract: real Python producer, real Swift consumer ----------------------
    do {
        let root = tempDir("contract"), queue = root + "/queue", home = root + "/home"
        try? fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        let sent: [[String: String]] = [
            ["text": "First turn.\n\nSecond paragraph — ünïcödé ✓", "source": "grow_guide_app", "key": "session-a"],
            ["text": "From another terminal", "source": "SpeakHUD", "key": "session-b"],
            ["text": "Session A again", "source": "grow_guide_app", "key": "session-a"],
        ]
        let before = Date()
        let (status, err) = pythonEnqueue(sent, into: queue, home: home)
        let after = Date()
        t.expectEqual(status, 0, "python enqueue() ran cleanly (\(err.trimmingCharacters(in: .whitespacesAndNewlines)))")
        t.expect(!fm.fileExists(atPath: home + "/.local"), "nothing was written under HOME")
        t.expectEqual(files(queue).filter { $0.hasSuffix(".tmp") }, [], "the hook leaves no .tmp behind")
        // Age the files, so a hook that stopped writing `created` can't pass on the
        // mtime fallback: that item would now be too old and dropped.
        for name in files(queue) {
            try? fm.setAttributes([.modificationDate: before.addingTimeInterval(-2 * Spool.maxAge)],
                                  ofItemAtPath: queue + "/" + name)
        }

        let batch = Spool.drain(in: queue, now: after)
        t.expectEqual(batch.dropped, [], "nothing the hook writes is dropped")
        t.expectEqual(batch.items.map(\.text), sent.map { $0["text"]! }, "text round-trips, in arrival order")
        t.expectEqual(batch.items.map(\.source), sent.map { $0["source"]! }, "source round-trips")
        t.expectEqual(batch.items.map(\.key), sent.map { $0["key"]! }, "key round-trips (same session keeps one key)")
        t.expect(batch.items.allSatisfy { $0.created >= before.addingTimeInterval(-1) && $0.created <= after.addingTimeInterval(1) },
                 "created is the hook's write time, not a fallback")
        t.expect(batch.items.allSatisfy { ($0.file ?? "").hasSuffix(".taken") && fm.fileExists(atPath: $0.file!) },
                 "each item is claimed as a .taken file that stays on disk")

        let again = Spool.drain(in: queue, now: after)
        t.expect(again.items.isEmpty && again.dropped.isEmpty, "a second drain finds nothing: the first claimed it all")

        Spool.recover(in: queue)
        let recovered = Spool.drain(in: queue, now: after)
        t.expectEqual(recovered.items.map(\.text), sent.map { $0["text"]! }, "recover() hands back every .taken item, in order")

        for item in recovered.items { Spool.done(item.file) }
        t.expectEqual(files(queue), [], "done() removes the items")
        try? fm.removeItem(atPath: root)
    }

    // -- the override variable, Swift side (the Python side is asserted above) ----
    do {
        let old = ProcessInfo.processInfo.environment[Spool.dirEnv]
        setenv(Spool.dirEnv, "/tmp/elsewhere/queue", 1)
        t.expectEqual(Spool.dir, "/tmp/elsewhere/queue", "Spool.dir honours \(Spool.dirEnv)")
        setenv(Spool.dirEnv, "", 1)
        t.expect(Spool.dir.hasSuffix("/.local/state/speakhud/queue"), "an empty override means the default")
        unsetenv(Spool.dirEnv)
        t.expectEqual(Spool.dir, NSString(string: "~/.local/state/speakhud/queue").expandingTildeInPath,
                      "the default is ~/.local/state/speakhud/queue")
        if let old = old { setenv(Spool.dirEnv, old, 1) }
    }

    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fresh = now.timeIntervalSince1970 - 5

    // -- every drop has a reason --------------------------------------------------
    do {
        let q = tempDir("drops")
        let cases: [(String, Any, Spool.DropReason)] = [
            ("01.json", "{not json", .malformed),
            ("02.json", "[1, 2]", .malformed),
            ("03.json", ["source": "x", "created": fresh], .emptyText),
            ("04.json", ["text": " \n\t ", "created": fresh], .emptyText),
            ("05.json", ["text": 5, "created": fresh], .emptyText),
            ("06.json", ["text": "hi", "created": "yesterday"], .invalidCreated),
            ("07.json", ["text": "hi", "created": true], .invalidCreated),
            ("08.json", ["text": "hi", "created": fresh - 1000], .tooOld),
        ]
        for (name, body, _) in cases { write(q, name, body) }
        let batch = Spool.drain(in: q, now: now)
        t.expectEqual(batch.items.count, 0, "no bad item is spoken")
        for (name, _, reason) in cases {
            t.expectEqual(batch.dropped.first { $0.name == name }?.reason, reason, "\(name) dropped as \(reason)")
        }
        t.expectEqual(files(q), [], "dropped items are deleted, not left to wedge the queue")
        try? fm.removeItem(atPath: q)
    }

    // -- the clock: maxAge on both sides of the edge ------------------------------
    do {
        let q = tempDir("clock")
        let t0 = now.timeIntervalSince1970
        write(q, "1.json", ["text": "just in time", "created": t0 - Spool.maxAge + 1])
        write(q, "2.json", ["text": "exactly maxAge", "created": t0 - Spool.maxAge])
        write(q, "3.json", ["text": "clock skew", "created": t0 + 30])
        let batch = Spool.drain(in: q, now: now)
        t.expectEqual(batch.items.map(\.text), ["just in time", "clock skew"], "under maxAge is kept, a future stamp too")
        t.expectEqual(batch.dropped, [Spool.Drop(name: "2.json", reason: .tooOld)], "maxAge itself is too old")
        try? fm.removeItem(atPath: q)
    }

    // -- missing created: the file's mtime is the write time ----------------------
    do {
        let q = tempDir("mtime")
        let written = now.addingTimeInterval(-30)
        write(q, "1.json", ["text": "no stamp, recent"], mtime: written)
        write(q, "2.json", ["text": "no stamp, stale"], mtime: now.addingTimeInterval(-Spool.maxAge - 1))
        let batch = Spool.drain(in: q, now: now)
        t.expectEqual(batch.items.map(\.text), ["no stamp, recent"], "a missing created falls back to mtime, not 1970")
        t.expect(abs((batch.items.first?.created ?? .distantPast).timeIntervalSince(written)) < 0.01,
                 "the fallback created is the file's mtime")
        t.expectEqual(batch.dropped, [Spool.Drop(name: "2.json", reason: .tooOld)], "an old mtime still ages out, with a reason")
        try? fm.removeItem(atPath: q)
    }

    // -- key and source defaults (key drives coalescing) ---------------------------
    do {
        let q = tempDir("keys")
        write(q, "1-a.json", ["text": "one", "key": "s1", "created": fresh])
        write(q, "2-b.json", ["text": "two", "key": "s1", "created": fresh])
        write(q, "3-c.json", ["text": "three", "created": fresh])
        write(q, "4-d.json", ["text": "four", "key": "", "source": "", "created": fresh])
        let items = Spool.drain(in: q, now: now).items
        t.expectEqual(items.map(\.key), ["s1", "s1", "3-c", "4-d"],
                      "a given key is kept verbatim; a missing or empty one becomes the unique file stem")
        t.expectEqual(items.map(\.source), ["Claude Code", "Claude Code", "Claude Code", "Claude Code"],
                      "a missing or empty source is \"Claude Code\"")
        try? fm.removeItem(atPath: q)
    }

    // -- abandoned .tmp files -----------------------------------------------------
    do {
        let q = tempDir("tmp")
        write(q, "old.tmp", "{\"text\": \"half", mtime: now.addingTimeInterval(-Spool.maxAge - 1))
        write(q, "young.tmp", "{\"text\": \"mid-write", mtime: now.addingTimeInterval(-2))
        let batch = Spool.drain(in: q, now: now)
        t.expectEqual(batch.dropped, [Spool.Drop(name: "old.tmp", reason: .staleTmp)], "a .tmp older than maxAge is swept, with a reason")
        t.expectEqual(files(q), ["young.tmp"], "a young .tmp (hook mid-write) is left alone and never drained")
        try? fm.removeItem(atPath: q)
    }
}
