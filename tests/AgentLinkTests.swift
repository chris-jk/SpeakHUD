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
    let terminal = Reply.Terminal(ask: { _ in scripts += 1; return Reply.Answer(reply: "missing") }, wait: { _ in }, link: session.call)

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

    for text in ["Nothing.", "nothing", "  Nothing!\n", "**Nothing.**"] {
        t.expect(Spool.saysNothing(text), "\(text) is not read")
    }
    for text in ["Nothing changed.", "Nothing else to do here", "Done."] {
        t.expect(!Spool.saysNothing(text), "\(text) is read")
    }
}
