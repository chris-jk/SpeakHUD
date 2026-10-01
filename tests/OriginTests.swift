// Origin tests. Registered in tests/main.swift.
//
// An item's origin is how clicking the source pill finds the terminal that's talking.
// Its session id and tty are interpolated into an AppleScript, so what Origin accepts
// is the whole defence against a crafted spool file running script of its choosing.
import Cocoa

private let session = "41E78242-1097-4FF8-BEFF-75DDE1D8CC4A"

let originSuite = Suite("Origin") { t in
    // -- parsing -------------------------------------------------------------------
    let full = Origin(json: ["term": "iTerm.app", "session": session, "tty": "/dev/ttys002", "app_pid": 65629])
    t.expectEqual(full, Origin(term: "iTerm.app", session: session, tty: "/dev/ttys002", appPID: 65629),
                  "every field the hook writes is read")
    t.expectEqual(Origin(jsonString: #"{"session": "\#(session)"}"#)?.session, session, "--origin JSON parses")

    t.expect(Origin(json: nil) == nil, "no origin is nil")
    t.expect(Origin(json: "iTerm.app") == nil, "an origin that isn't an object is nil")
    t.expect(Origin(json: ["term": "vscode"]) == nil, "a term alone can't go anywhere, so it's nil")
    t.expect(Origin(jsonString: "{not json") == nil, "bad --origin JSON is nil")

    for bad in [#"x" then do shell script "touch /tmp/pwned"#,
                session.lowercased(),                // the hook upper-cases; anything else is foreign
                session + "\"", "", "w4t0p0:" + session] {
        t.expect(Origin(json: ["session": bad, "app_pid": 500])?.session == nil,
                 "a session id that isn't a bare upper-case UUID is dropped: \(bad)")
    }
    for bad in ["/dev/ttys002\" then beep", "ttys002", "/dev/tty", "/dev/console", "/dev/ttys"] {
        t.expect(Origin(json: ["tty": bad, "app_pid": 500])?.tty == nil, "a tty that isn't /dev/ttysN is dropped: \(bad)")
    }
    for bad: Any in [true, 0, 1, -5, 1.5, "500", Double(Int32.max) + 10] {
        t.expect(Origin(json: ["app_pid": bad, "tty": "/dev/ttys1"])?.appPID == nil, "app_pid \(bad) is dropped")
    }
    t.expectEqual(Origin(json: ["session": "nope", "tty": "/dev/ttys004"]), Origin(tty: "/dev/ttys004"),
                  "one bad field doesn't cost the good ones")

    // -- which script, for which terminal ------------------------------------------
    let byID = Reveal.script(for: Origin(term: "iTerm.app", session: session, tty: "/dev/ttys002"))
    t.expectEqual(byID?.bundleID, Reveal.iTerm, "iTerm2 is asked about iTerm2 panes")
    t.expect(byID?.source.contains("(id of s) is \"\(session)\"") == true, "…by session id when there is one")
    let byTTY = Reveal.script(for: Origin(term: "iTerm.app", tty: "/dev/ttys002"))
    t.expect(byTTY?.source.contains("(tty of s) is \"/dev/ttys002\"") == true, "…and by tty when there isn't")
    t.expectEqual(Reveal.script(for: Origin(session: session))?.bundleID, Reveal.iTerm,
                  "a session id with no term is still iTerm2's (only iTerm2 sets one)")
    let terminal = Reveal.script(for: Origin(term: "Apple_Terminal", tty: "/dev/ttys009"))
    t.expectEqual(terminal?.bundleID, Reveal.terminal, "Terminal.app is asked about its tabs")
    t.expect(terminal?.source.contains("(tty of t) is \"/dev/ttys009\"") == true, "…by tty")
    t.expect(Reveal.script(for: Origin(term: "vscode", tty: "/dev/ttys003", appPID: 900)) == nil,
             "any other terminal gets no script (its app is activated instead)")
    t.expect(Reveal.script(for: Origin(term: "Apple_Terminal", appPID: 900)) == nil,
             "Terminal.app with no tty can't name a tab")

    // The scripts must compile. That loads each app's dictionary but sends it nothing.
    for (name, script) in [("iTerm2", byID), ("Terminal", terminal)] {
        guard let script = script,
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: script.bundleID) != nil else { continue }
        var err: NSDictionary?
        let ok = NSAppleScript(source: script.source)?.compileAndReturnError(&err) ?? false
        t.expect(ok, "the \(name) script compiles (\(err?[NSAppleScript.errorMessage] ?? "no error"))")
    }

    // -- nothing to go to ----------------------------------------------------------
    t.expectEqual(Reveal.go(Origin(appPID: 999_999)), .gone, "an app that has quit is gone, not an error")
}
