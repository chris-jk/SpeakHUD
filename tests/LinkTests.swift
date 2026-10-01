// Link tests. Registered in tests/main.swift.
//
// Paths and commands in a turn become clickable in three steps: the REAL hook marks
// them (it has Claude's PATH and cwd), the spool carries them, and the HUD decides
// what a click does. A command is only ever typed, never run, so what LoadCommand
// lets into its AppleScript is the whole defence against a turn that runs something.
import Cocoa

private let fm = FileManager.default

private let hookPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("hook/read-summary.py").path

private func tempDir(_ label: String) -> String {
    let d = fm.temporaryDirectory.appendingPathComponent("speakhud-links-\(label)-\(UUID().uuidString)").path
    try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
    return (d as NSString).resolvingSymlinksInPath
}

/// Runs `code` with the hook loaded as `hook` and returns what it printed. PATH is only
/// `bin` and HOME is `home`, so which words count as commands is up to the test.
private func python(_ code: String, args: [String] = [], home: String, bin: String, queue: String? = nil) -> String {
    let script = """
    import importlib.util, json, sys
    spec = importlib.util.spec_from_file_location("read_summary", sys.argv[1])
    hook = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hook)
    """ + "\n" + code
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", "-c", script, hookPath] + args
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = home
    env["PATH"] = bin + ":/usr/bin:/bin"   // env must find python3; the test's stubs come first
    if let q = queue { env[Spool.dirEnv] = q }
    p.environment = env
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    if p.terminationStatus != 0 { print("python failed: \(msg)") }
    return String(data: data, encoding: .utf8) ?? ""
}

let linkSuite = Suite("Links") { t in
    // -- the hook: what counts as a path or a command ------------------------------
    do {
        let root = tempDir("hook")
        let home = root + "/home", proj = root + "/proj", bin = root + "/bin"
        for d in [home + "/notes", proj + "/tests", bin] { try? fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        fm.createFile(atPath: proj + "/README.md", contents: Data())
        fm.createFile(atPath: proj + "/notes_v2.md", contents: Data())
        fm.createFile(atPath: proj + "/tests/run.sh", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        fm.createFile(atPath: home + "/notes/a.md", contents: Data())
        fm.createFile(atPath: bin + "/frob", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])

        let md = """
        Done — **all** pass. Run `./tests/run.sh` or `frob --all`, see `README.md:12`, \
        `tests/new.md`, `notes_v2.md`, `Playback`, `! frob login`, `it's frob`, `nope --x`.

        - 🎉 Saved to ~/notes/a.md. Not ~/notes/gone.md or https://example.com/a/b or and/or.
        - `cd ..` and `FOO=1 frob` and `tests/run.sh`
        """
        let out = python("""
            text, spans = hook.unmark(hook.marked(sys.argv[2]))
            print(json.dumps({"text": text, "links": hook.links(text, spans, sys.argv[3])}))
            """, args: [md, proj], home: home, bin: bin)
        let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] ?? [:]
        let text = obj["text"] as? String ?? ""
        let links = TextLink.parse(obj["links"], in: text)
        var got: [String: TextLink.Action] = [:]
        for l in links { got[(text as NSString).substring(with: l.range)] = l.action }

        t.expect(text.hasPrefix("Done — all pass. Run ./tests/run.sh"), "emphasis and backticks are still stripped: \(text)")
        t.expect(text.contains("notes_v2.md"), "…but not the underscores inside inline code")
        t.expectEqual(links.count, (obj["links"] as? [Any])?.count ?? -1, "every link the hook sends parses")

        t.expectEqual(got["./tests/run.sh"], .load("./tests/run.sh"), "`./x` on an executable is a command")
        t.expectEqual(got["tests/run.sh"], .open(proj + "/tests/run.sh"), "…and `x` alone is the file")
        t.expectEqual(got["frob --all"], .load("frob --all"), "a word on PATH with arguments is a command")
        t.expectEqual(got["FOO=1 frob"], .load("FOO=1 frob"), "…after env assignments")
        t.expectEqual(got["cd .."], .load("cd .."), "…and so is a shell builtin")
        t.expectEqual(got["! frob login"], .load("frob login"), "`! cmd` loads the command without the bang")
        t.expectEqual(got["README.md:12"], .open(proj + "/README.md"), "a file:line opens the file")
        t.expectEqual(got["tests/new.md"], .open(proj + "/tests/new.md"), "a path whose folder exists is linked (opens the folder)")
        t.expectEqual(got["notes_v2.md"], .open(proj + "/notes_v2.md"), "a relative path resolves against the turn's cwd")
        t.expectEqual(got["~/notes/a.md"], .open(home + "/notes/a.md"), "a bare ~/ path in the prose, without its full stop")
        t.expect(got["Playback"] == nil, "a code word that isn't a file or command stays plain")
        t.expect(got["it's frob"] == nil, "unbalanced quotes aren't a command line")
        t.expect(got["nope --x"] == nil, "a first word that isn't on PATH isn't a command")
        t.expect(!got.keys.contains { $0.contains("gone.md") }, "a bare path that doesn't exist stays plain")
        t.expect(!got.keys.contains { $0.contains("example.com") || $0 == "/or" }, "URLs and and/or aren't paths")
        try? fm.removeItem(atPath: root)
    }

    // -- the spool carries them: real enqueue() → real drain -------------------------
    do {
        let root = tempDir("spool")
        let queue = root + "/q"
        let links: [[String: Any]] = [["at": 4, "len": 10, "run": "git status"], ["at": 18, "len": 3, "path": "/tmp"]]
        let json = String(data: try! JSONSerialization.data(withJSONObject: links), encoding: .utf8)!
        _ = python("hook.enqueue('Run git status in tmp.', 'proj', 'k', None, json.loads(sys.argv[2]), '/x/proj')",
                   args: [json], home: root, bin: root, queue: queue)
        let item = Spool.drain(in: queue).items.first
        t.expectEqual(item?.links, [TextLink(range: NSRange(location: 4, length: 10), action: .load("git status")),
                                    TextLink(range: NSRange(location: 18, length: 3), action: .open("/tmp"))],
                      "links survive enqueue → drain")
        t.expectEqual(item?.cwd, "/x/proj", "…and so does cwd")
        _ = python("hook.enqueue('Hi.', 'proj', 'k')", home: root, bin: root, queue: queue)
        let bare = Spool.drain(in: queue).items.first
        t.expect(bare?.links == [] && bare?.cwd == nil, "a turn with no links has none")
        try? fm.removeItem(atPath: root)
    }

    // -- parsing is the HUD's own guard ----------------------------------------------
    let text = "Run git status now."   // 19 UTF-16 units
    func one(_ o: [String: Any]) -> [TextLink] { TextLink.parse([o], in: text) }
    t.expectEqual(one(["at": 4, "len": 10, "run": "git status"]).count, 1, "a well-formed link parses")
    t.expect(one(["at": 15, "len": 10, "run": "x"]).isEmpty, "a range past the end is dropped")
    t.expect(one(["at": 4, "len": 0, "run": "x"]).isEmpty, "an empty range is dropped")
    t.expect(one(["at": -1, "len": 3, "run": "x"]).isEmpty, "a negative offset is dropped")
    t.expect(one(["at": true, "len": 3, "run": "x"]).isEmpty, "a boolean offset is dropped")
    t.expect(one(["at": 1.5, "len": 3, "run": "x"]).isEmpty, "a fractional offset is dropped")
    t.expect(one(["at": 4, "len": 3, "path": "relative/x"]).isEmpty, "a relative path is dropped")
    t.expect(one(["at": 4, "len": 3]).isEmpty, "a link with no action is dropped")
    t.expect(one(["at": 4, "len": 3, "run": "ls\nrm -rf ~"]).isEmpty, "a command with a newline is dropped")
    t.expect(one(["at": 4, "len": 3, "path": "/tmp\n"]).isEmpty, "a path with a newline is dropped")
    t.expectEqual(TextLink.parse([["at": 0, "len": 8, "run": "a"], ["at": 4, "len": 3, "run": "b"],
                                  ["at": 8, "len": 2, "path": "/tmp"]], in: text).count, 2,
                  "a link overlapping an earlier one is dropped, its neighbour isn't")
    t.expect(TextLink.parse("nope", in: text).isEmpty, "links that aren't an array are none")
    t.expect(TextLink.absolutePath("x/y") == nil && TextLink.absolutePath(5) == nil, "cwd must be an absolute path")

    // -- what a typed command can contain ------------------------------------------
    for bad in ["", "   ", "ls\n", "ls\rrm", "echo \u{1b}[31m", "a\u{9b}b", "tab\there", String(repeating: "x", count: 1001)] {
        t.expect(!LoadCommand.isLoadable(bad), "not loadable: \(bad.debugDescription.prefix(30))")
    }
    for nasty in [#"echo "hi""#, #"a\"b"#, #"\\"#, #"x" & (do shell script "touch /tmp/pwned") & ""#, "café ☕️ 'q'"] {
        // The literal must read back as exactly the command: nothing in it can end the
        // string and become script. Executing `return <literal>` targets no app.
        var err: NSDictionary?
        let back = NSAppleScript(source: "return " + LoadCommand.literal(nasty))?.executeAndReturnError(&err).stringValue
        t.expectEqual(back, nasty, "an AppleScript literal round-trips: \(nasty)")
    }
    let src = LoadCommand.script("git status", cwd: "/Users/x/it's here") ?? ""
    t.expect(src.contains(#"write text "git status" newline no"#), "the command is typed without Return")
    // The shell's '\'' arrives with its backslash doubled, as the AppleScript literal needs.
    t.expect(src.contains(#"write text "cd '/Users/x/it'\\''s here' && clear""#), "cwd is shell-quoted for the cd")
    t.expect(!(LoadCommand.script("git status", cwd: nil) ?? "").contains("cd "), "no cwd, no cd")
    t.expect(LoadCommand.script("ls\nrm", cwd: nil) == nil, "a multi-line command gets no script")

    // -- what clicking a path does -------------------------------------------------
    do {
        let root = tempDir("open")
        try? fm.createDirectory(atPath: root + "/dir/sub", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/dir/note.md", contents: Data())
        let editor: (URL) -> String? = { _ in "com.apple.TextEdit" }
        t.expectEqual(OpenPath.plan(root + "/dir", defaultApp: editor), .reveal(root + "/dir"),
                      "a folder is shown in the folder above it")
        t.expectEqual(OpenPath.plan(root + "/dir/note.md", defaultApp: editor), .open(root + "/dir/note.md"),
                      "a file opens in its default app")
        for runner in [Reveal.terminal, Reveal.iTerm, "org.python.PythonLauncher"] {
            t.expectEqual(OpenPath.plan(root + "/dir/note.md", defaultApp: { _ in runner }), .reveal(root + "/dir/note.md"),
                          "a file whose default app would run it is shown in Finder: \(runner)")
        }
        t.expectEqual(OpenPath.plan(root + "/dir/note.md", defaultApp: { _ in nil }), .reveal(root + "/dir/note.md"),
                      "a file with no default app is shown in Finder")
        t.expectEqual(OpenPath.plan(root + "/dir/gone.md", defaultApp: editor), .open(root + "/dir"),
                      "a missing file opens the folder it was in")
        t.expectEqual(OpenPath.plan(root + "/dir/sub/a/b/c.md", defaultApp: editor), .open(root + "/dir/sub"),
                      "…or the nearest one above it that's still there")
        try? fm.removeItem(atPath: root)
    }
}
