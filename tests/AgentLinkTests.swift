// Agent Terminal's sessions, reached over its socket. Registered in tests/main.swift.
import Foundation

/// A session as the socket shows it: a prompt box that takes pastes and Return.
private final class FakeSession {
    var box = ""
    var requests: [[String: Any]] = []
    var alive = true
    var screen: String {
        let rule = String(repeating: "─", count: 60)
        return "⏺ Earlier.\n\n\(rule)\n❯ \(box)\n\(rule)\n  status"
    }
    func call(_ r: [String: Any]) -> [String: Any]? {
        requests.append(r)
        guard alive else { return ["ok": false] }
        switch r["op"] as? String {
        case "screen": return ["ok": true, "text": screen]
        case "write":
            let text = r["text"] as? String ?? ""
            if text == "\r" { box = "" } else {
                box = text.replacingOccurrences(of: "\u{1B}[200~", with: "").replacingOccurrences(of: "\u{1B}[201~", with: "")
            }
            return ["ok": true]
        case "survey":
            return ["ok": true, "panes": [["session": id, "name": "✳ Topic", "screen": screen]]]
        default: return ["ok": true]
        }
    }
    let id = "A6E47E00-1111-2222-3333-444455556666"
}

let agentLinkSuite = Suite("AgentLink") { t in
    let session = FakeSession()
    let origin = Origin(term: AgentLink.term, session: session.id)
    var scripts = 0
    let terminal = Reply.Terminal(ask: { _ in scripts += 1; return Reply.Answer(reply: "missing") }, wait: { _ in }, link: { session.call($0).map { .answered($0) } ?? .closed })

    t.expect(Reply.canReach(origin), "an Agent Terminal session can be answered")
    t.expect(AgentLink.owns(session.id) && !AgentLink.owns("E3B0C442-1111-2222-3333-444455556666"), "ids are told apart by their first group")
    t.expect(Origin(json: ["term": AgentLink.term, "session": session.id]) != nil, "its id passes Origin's check")

    t.expectEqual(Reply.send("Yes please", to: origin, via: terminal), .sent, "an answer goes in over the socket")
    t.expectEqual(session.box, "", "and Return took it")
    let writes = session.requests.filter { $0["op"] as? String == "write" }.map { $0["text"] as? String ?? "" }
    t.expectEqual(writes, ["\u{1B}[200~Yes please\u{1B}[201~", "\r"], "pasted, then Return")
    t.expectEqual(scripts, 0, "no AppleScript went to iTerm2")

    t.expect(Reply.screen(of: origin, via: terminal)?.contains("Earlier") == true, "its screen reads")
    session.alive = false
    t.expectEqual(Reply.send("Yes", to: origin, via: terminal), .gone, "a closed session is gone")
    session.alive = true

    let found = Reply.surveyAll(via: terminal)
    t.expectEqual(found?.panes.map { $0.session } ?? [], [session.id], "survey lists its sessions")
    t.expect(found?.iTermSaid == false, "with iTerm2 not saying")

    var desk = PhoneDesk()
    desk.met(found?.panes ?? [], iTermSaid: false)
    t.expectEqual(desk.turns.first?.origin?.term, AgentLink.term, "a session on the phone is marked as ours")

    var iTermTurn = PhoneDesk()
    iTermTurn.met([Reply.Pane(session: "E3B0C442-1111-2222-3333-444455556666", name: "✳ Topic", screen: session.screen)])
    t.expectEqual(iTermTurn.turns.count, 1, "an iTerm2 pane is on the desk")
    iTermTurn.met([], iTermSaid: false)
    t.expectEqual(iTermTurn.turns.count, 1, "iTerm2 saying nothing doesn't close its turns")
    desk.met([], iTermSaid: false)
    t.expectEqual(desk.turns.count, 0, "a session that left the list has closed")

    var colored = PhoneDesk()
    colored.met([Reply.Pane(session: session.id, name: "✳ Topic", screen: session.screen, color: "#4d80e6")])
    t.expectEqual(colored.turns.first?.origin?.color, "#4d80e6", "a session's bar takes its project color")

    var opened: [String] = [], iTerm = 0
    OldSessions.agentTerminal = { folder, line in opened.append(folder + " | " + line); return .answered(["ok": true]) }
    let here = NSTemporaryDirectory()
    let started = NewTerminal.start(folder: here, message: "hello there", run: { _ in iTerm += 1; return Reply.Answer(reply: "ok") })
    t.expectEqual(started, .sent, "Start goes to Agent Terminal while it's open")
    t.expect(iTerm == 0 && opened.first?.contains("claude 'hello there'") == true, "with the same line, and no iTerm2 window")
    OldSessions.agentTerminal = { _, _ in .closed }
    _ = NewTerminal.start(folder: here, message: nil, run: { _ in iTerm += 1; return Reply.Answer(reply: "ok") })
    t.expectEqual(iTerm, 1, "with it closed, iTerm2 opens")
    OldSessions.agentTerminal = { _, _ in .noAnswer }
    let busy = NewTerminal.start(folder: here, message: nil, run: { _ in iTerm += 1; return Reply.Answer(reply: "ok") })
    t.expectEqual(busy, .failed("Agent Terminal didn't answer"), "open but busy: it says so")
    t.expectEqual(iTerm, 1, "and no iTerm2 window, or a late open would make two")
    OldSessions.agentTerminal = { _, _ in .closed }

    // -- busy is not closed ---------------------------------------------------
    let stalled = Reply.Terminal(ask: { _ in Reply.Answer(reply: "ok\tE3B0C442-1111-2222-3333-444455556666\tTopic\tx") }, wait: { _ in },
                                 link: { _ in .noAnswer })
    let quietSurvey = Reply.surveyAll(via: stalled)
    t.expect(quietSurvey?.agentSaid == false, "a survey it didn't answer says nothing about its sessions")
    var kept = PhoneDesk()
    kept.met([Reply.Pane(session: session.id, name: "✳ Topic", screen: session.screen)])
    kept.met(quietSurvey?.panes ?? [], iTermSaid: true, agentSaid: false)
    t.expect(kept.turns.contains { $0.origin?.session == session.id }, "so its windows stay on the phone")
    let shut = Reply.Terminal(ask: { _ in Reply.Answer(reply: "ok") }, wait: { _ in }, link: { _ in .closed })
    t.expect(Reply.surveyAll(via: shut)?.agentSaid == true, "closed does say: it has no sessions")
    t.expectEqual(Reply.close(origin, via: stalled), .failed("Agent Terminal didn't answer"), "Close doesn't claim a busy one closed")
    t.expectEqual(Reply.close(origin, via: shut), .sent, "a gone one is closed all the same")
    t.expectEqual(Reply.send("Yes", to: origin, via: stalled), .failed("Agent Terminal didn't answer"), "a send to a busy one isn't 'gone'")

    // -- the real socket ------------------------------------------------------
    let dir = NSTemporaryDirectory() + "al-" + UUID().uuidString.prefix(8)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    if case .closed = AgentLink.call(["op": "survey"], at: dir + "/none.sock") {} else { t.expect(false, "no socket file: closed") }
    let sock = dir + "/s.sock", listener = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let room = MemoryLayout.size(ofValue: addr.sun_path)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: sock.utf8.prefix(room - 1)) }
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    listen(listener, 4)
    if case .noAnswer = AgentLink.call(["op": "survey"], at: sock) {} else { t.expect(false, "there but silent: no answer") }
    close(listener)
    if case .closed = AgentLink.call(["op": "survey"], at: sock) {} else { t.expect(false, "a socket left behind by a dead app: closed") }

    let unpaired = Phone(config: PhoneConfig(token: "not-this-one"), defaults: UserDefaults(suiteName: "agent-link-tests")!)
    unpaired.asset = { FileManager.default.contents(atPath: "phone/" + $0) }
    t.expectEqual(unpaired.respond(to: HTTP.Request(path: "/icon.png")).status, 200, "the logo needs no pairing")
    t.expectEqual(unpaired.respond(to: HTTP.Request(path: "/app.js")).status == 200, false, "the page's other files do")

    for text in ["Nothing.", "nothing", "  Nothing!\n", "**Nothing.**"] {
        t.expect(Spool.saysNothing(text), "\(text) is not read")
    }
    for text in ["Nothing changed.", "Nothing else to do here", "Done."] {
        t.expect(!Spool.saysNothing(text), "\(text) is read")
    }
}
