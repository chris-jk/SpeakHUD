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

    // -- the terminal's frame color, for the pill -----------------------------------
    t.expectEqual(Origin(json: ["tty": "/dev/ttys1", "color": "#40B2B2"])?.color, "#40b2b2", "a frame color is read, lower-cased")
    for bad: Any in ["40b2b2", "#40b2b", "#40b2b2ff", "#gggggg", "teal", 4239026, true] {
        t.expect(Origin(json: ["tty": "/dev/ttys1", "color": bad])?.color == nil, "a color that isn't #rrggbb is dropped: \(bad)")
    }
    t.expect(Origin(json: ["color": "#40b2b2"]) == nil, "a color alone can't go anywhere, so it's nil")
    let teal = Accent.frame("#40b2b2")?.usingColorSpace(.sRGB)
    t.expect(teal != nil && abs(teal!.redComponent - 64 / 255) < 0.001 && abs(teal!.greenComponent - 178 / 255) < 0.001
             && abs(teal!.blueComponent - 178 / 255) < 0.001, "the pill's color is the frame's, channel for channel")
    t.expect(Accent.frame(nil) == nil && Accent.frame("#40b2") == nil && Accent.frame("#zzzzzz") == nil,
             "no frame color, no override: the pill keeps its own")

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
    // Activating after the window is picked stays on the current desktop whenever the
    // terminal has a window there; activate first and the pick switches desktops.
    for (name, script, pick) in [("iTerm2", byID, "select win"), ("Terminal", terminal, "set index of win to 1")] {
        let src = script?.source ?? ""
        let act = src.range(of: "activate"), sel = src.range(of: pick)
        t.expect(act != nil && sel != nil && act!.lowerBound < sel!.lowerBound,
                 "the \(name) script activates before it picks the window")
        // Picking the window moves it to the front, and the loop's `w` counts from the
        // front: used again after the pick it's the window that was there before, which
        // is the one that got the ring. Everything from the pick on goes by id.
        let hold = src.range(of: "set wid to id of w")
        t.expect(hold != nil && sel != nil && hold!.lowerBound < sel!.lowerBound
                 && src.contains("set win to a reference to (first window whose id is wid)"),
                 "the \(name) script takes the window's id before it picks it")
        let after = sel.map { String(src[$0.lowerBound...]) } ?? "w"
        t.expect(after.range(of: #"\b[wts]\b"#, options: .regularExpression) == nil,
                 "…and never goes back through the loop's window, tab or session after the pick (\(name))")
    }
    // Each script says where the window it picked is, so the HUD can point at it.
    for (name, script) in [("iTerm2", byID), ("Terminal", terminal)] {
        t.expect(script?.source.contains("set b to bounds of win") == true, "the \(name) script reports the window's bounds")
        t.expect(script?.source.components(separatedBy: "return \"ok\"").count == 2,
                 "…and still answers a bare ok when the window won't give them (\(name))")
    }
    t.expectEqual(Reveal.bounds(inReply: "ok 43 33 713 507"), NSRect(x: 43, y: 33, width: 670, height: 474),
                  "left top right bottom becomes a rect, still counted from the top")
    t.expectEqual(Reveal.bounds(inReply: "ok -1512 -200 -842 274"), NSRect(x: -1512, y: -200, width: 670, height: 474),
                  "a window on a screen left of or above the main one has negative bounds")
    for bad in ["ok", "missing", "ok 1 2 3", "ok 1 2 3 x", "ok 10 10 10 50", "ok 10 50 90 10", "no 1 2 3 4", ""] {
        t.expect(Reveal.bounds(inReply: bad) == nil, "no usable bounds in \"\(bad)\"")
    }
    t.expect(Reveal.bounds(inReply: nil) == nil, "no reply, no bounds")
    // AppleScript counts down from the top of the main screen, AppKit up from its bottom.
    t.expectEqual(Spotlight.flipped(NSRect(x: 43, y: 33, width: 670, height: 474), mainHeight: 982),
                  NSRect(x: 43, y: 475, width: 670, height: 474), "bounds are flipped into AppKit's coordinates")
    t.expectEqual(Spotlight.flipped(NSRect(x: 100, y: -500, width: 300, height: 200), mainHeight: 982),
                  NSRect(x: 100, y: 1282, width: 300, height: 200), "…including a window on a screen above the main one")

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
