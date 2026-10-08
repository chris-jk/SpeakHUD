// Phone tests. Registered in tests/main.swift.
//
// The real Phone on requests built by hand (what PhoneServer would hand it), with a
// stand-in for iTerm2 and for the push server; then one real round trip through
// PhoneServer on this Mac's loopback. Nothing here reaches a terminal or a network.
import Cocoa

private let fm = FileManager.default
private let pane = Origin(term: "iTerm.app", session: "0A1B2C3D-0000-4000-8000-00000000000A", color: "#2f6f4f")
private let token = String(repeating: "ab12", count: 16)

private func turn(_ key: String, _ text: String, name: String = "Grow guide replies", origin: Origin? = pane,
                  answerable: Bool = true) -> SpeechItem {
    SpeechItem(text: text, source: name, key: key, created: Date(), origin: origin, answerable: answerable)
}

private func get(_ path: String, query: [String: String] = [:], paired: Bool = true) -> HTTP.Request {
    HTTP.Request(method: "GET", path: path, query: query,
                 headers: paired ? ["cookie": "other=1; \(Phone.cookie)=\(token)"] : [:])
}

private func post(_ path: String, _ body: [String: Any], header: Bool = true,
                  type: String = "application/json") -> HTTP.Request {
    var headers = ["cookie": "\(Phone.cookie)=\(token)", "content-type": type]
    if header { headers["x-speakhud"] = "1" }
    return HTTP.Request(method: "POST", path: path, headers: headers,
                        body: try! JSONSerialization.data(withJSONObject: body))
}

private func json(_ r: HTTP.Response) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
}

private func turns(_ state: [String: Any]) -> [[String: Any]] { state["turns"] as? [[String: Any]] ?? [] }

/// A Phone on throwaway settings, with what it sent to iTerm2 and to the push server.
private final class Bench {
    let suite = "speakhud-phone-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let phone: Phone
    var delivered: [(text: String, session: String?)] = []
    var pressed: [String] = []
    var pushes: [URLRequest] = []
    var logs: [String] = []
    var awayChanges: [Bool] = []
    var outcome = Reply.Outcome.sent
    var screen: String? = "some output\n────────────────\n❯ \n────────────────\n  status"

    init(url: String? = "https://my-mac.example.ts.net", ntfy: String? = "https://push.example.com/terminals") {
        defaults = UserDefaults(suiteName: suite)!
        var config = PhoneConfig(token: token)
        config.url = url
        config.ntfy = ntfy
        config.ntfyToken = ntfy == nil ? nil : "tk_secret"
        phone = Phone(config: config, defaults: defaults)
        phone.deliver = { [unowned self] text, origin in self.delivered.append((text, origin.session)); return self.outcome }
        phone.press = { [unowned self] key, _ in self.pressed.append(key); return self.outcome }
        phone.look = { [unowned self] _ in self.screen }
        phone.transport = { [unowned self] request, done in self.pushes.append(request); done(nil) }
        phone.asset = { fm.contents(atPath: "phone/" + $0) }
        phone.log = { [unowned self] in self.logs.append($0) }
        phone.onAwayChange = { [unowned self] in self.awayChanges.append($0) }
    }
    deinit { defaults.removePersistentDomain(forName: suite) }
}

let phoneSuite = Suite("Phone") { t in
    // -- phone.json ---------------------------------------------------------
    let dir = fm.temporaryDirectory.appendingPathComponent("speakhud-phone-\(UUID().uuidString)").path
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    let path = dir + "/phone.json"

    let made = PhoneConfig.newToken()
    t.expect(made.count == 64 && made != PhoneConfig.newToken(), "a new token is 64 characters and not the last one")
    t.expect(PhoneConfig.load(path) == nil, "no phone.json: the page is off")
    fm.createFile(atPath: path, contents: Data(#"{"token": "short"}"#.utf8))
    t.expect(PhoneConfig.load(path) == nil, "a token too short to be one: the page stays off rather than open")

    var written = PhoneConfig(token: made)
    written.url = PhoneConfig.web("https://my-mac.example.ts.net/")
    written.ntfy = PhoneConfig.web("https://push.example.com/terminals")
    written.ntfyToken = "tk_secret"
    t.expect(written.save(to: path), "phone.json is written")
    t.expectEqual((try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? Int ?? 0, 0o600,
                  "for you alone: it holds the token")
    t.expect(PhoneConfig.load(path) == written, "and reads back the same")
    t.expectEqual(written.url ?? "", "https://my-mac.example.ts.net", "an address loses its trailing slash")
    t.expectEqual(written.pairLink ?? "", "https://my-mac.example.ts.net/pair?k=\(made)", "the pairing link carries the token")
    t.expect(PhoneConfig.web("ftp://x") == nil && PhoneConfig.web("my-mac") == nil && PhoneConfig.web(7) == nil,
             "anything that isn't an http(s) address is left out")

    // -- setup --------------------------------------------------------------
    let setupPath = dir + "/setup.json"
    let first = PhonePair.setup(["--setup-phone", "--url", "https://my-mac.example.ts.net"], env: [:], path: setupPath)
    t.expectEqual(first.exitCode, 0, "setup writes a config from nothing")
    let firstToken = PhoneConfig.load(setupPath)?.token ?? ""
    t.expect(firstToken.count == 64 && !first.message.contains(firstToken), "with a new token it doesn't print")
    let second = PhonePair.setup(["--setup-phone", "--ntfy", "https://push.example.com/terminals"],
                                 env: ["SPEAKHUD_NTFY_TOKEN": "tk_env"], path: setupPath)
    let again = PhoneConfig.load(setupPath)
    t.expect(second.exitCode == 0 && again?.token == firstToken && again?.url == "https://my-mac.example.ts.net",
             "a second run keeps the token and what wasn't given again: a paired phone stays paired")
    t.expect(again?.ntfy == "https://push.example.com/terminals" && again?.ntfyToken == "tk_env" && !second.message.contains("tk_env"),
             "the push token can come from the environment, and isn't printed")
    let renewed = PhonePair.setup(["--setup-phone", "--new-token"], env: [:], path: setupPath)
    let rekeyed = PhoneConfig.load(setupPath)
    t.expect(renewed.exitCode == 0 && rekeyed?.token.count == 64 && rekeyed?.token != firstToken && rekeyed?.url == again?.url
             && !renewed.message.contains(rekeyed?.token ?? "?"), "--new-token replaces the key and nothing else: a lost phone's stops working")
    let link = "https://my-mac.example.ts.net/pair?k=\(token)"
    let read = PhonePair.qr(link, side: 240).flatMap { $0.tiffRepresentation }.flatMap { CIImage(data: $0) }.map { picture in
        (CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])?
            .features(in: picture) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
    t.expectEqual(read ?? ["no picture"], [link], "the pairing code, read back the way a camera would, is the link")
    t.expectEqual(PhonePair.setup(["--setup-phone", "--url", "my-mac"], env: [:], path: setupPath).exitCode, 2, "a url with no scheme is refused")
    t.expectEqual(PhonePair.setup(["--setup-phone", "--ntfy", "https://push.example.com"], env: [:], path: setupPath).exitCode, 2,
                  "a push server with no topic is refused")
    t.expectEqual(PhonePair.setup(["--setup-phone", "--port", "80"], env: [:], path: setupPath).exitCode, 2, "a privileged port is refused")

    // -- the desk -----------------------------------------------------------
    var desk = PhoneDesk()
    let t0 = Date(timeIntervalSince1970: 1_791_000_000)
    t.expect(desk.took(turn("a", "first"), now: t0), "a finished turn is a turn's first word")
    desk.took(turn("b", "other", name: "Review desk"), now: t0.addingTimeInterval(1))
    desk.took(turn("a", "second"), now: t0.addingTimeInterval(2))
    t.expectEqual(desk.turns.map { $0.key + ":" + $0.text }, ["a:second", "b:other"], "one turn per terminal, the newest first")

    t.expect(desk.took(turn("b:question", "Which one?", name: "Review desk"), now: t0.addingTimeInterval(10)),
             "a question's first piece is a first word")
    t.expect(!desk.took(turn("b:question", "- 1. This.\n- 2. That.", name: "Review desk"), now: t0.addingTimeInterval(14)),
             "its options, a pause later, are not")
    t.expectEqual(desk.turn("b")?.question ?? "", "Which one?\n\n- 1. This.\n- 2. That.", "the pieces are one box, on its terminal's turn")
    t.expectEqual(desk.turn("b")?.text ?? "", "other", "which keeps the turn it had")
    t.expectEqual(desk.turns.first?.key ?? "", "b", "and comes to the top")
    t.expect(desk.took(turn("b:question", "And this?", name: "Review desk"), now: t0.addingTimeInterval(14 + PhoneDesk.questionGap)),
             "a question long after the last piece is the next question")
    t.expectEqual(desk.turn("b")?.question ?? "", "And this?", "and replaces it")

    desk.answered("b", with: "hello", .notAtPrompt)
    t.expect(desk.turn("b")?.note == Reply.Outcome.notAtPrompt.description && desk.turn("b")?.sent == nil && desk.turn("b")?.question != nil,
             "a send that didn't go leaves why, and the question up")
    desk.questionClosed("b")
    desk.answered("b", with: "hello", .sent)
    t.expect(desk.turn("b")?.sent == "hello" && desk.turn("b")?.note == nil, "one that went is remembered, the note gone")
    desk.took(turn("b", "done", name: "Review desk"), now: t0.addingTimeInterval(200))
    t.expect(desk.turn("b")?.sent == nil && desk.turn("b")?.question == nil, "until its terminal's next turn")
    for i in 0..<(PhoneDesk.keep + 5) { desk.took(turn("k\(i)", "x"), now: t0.addingTimeInterval(300 + Double(i))) }
    t.expectEqual(desk.turns.count, PhoneDesk.keep, "the list stops at \(PhoneDesk.keep)")

    // -- reading a request --------------------------------------------------
    func parsed(_ s: String) -> HTTP.Parsed { HTTP.parse(Data(s.utf8)) }
    if case .request(let r) = parsed("GET /pair?k=ab%2012&x HTTP/1.1\r\nHost: m\r\nCookie: a=1; speakhud=zz\r\n\r\n") {
        t.expect(r.method == "GET" && r.path == "/pair" && r.query == ["k": "ab 12", "x": ""], "method, path and decoded query")
        t.expect(r.headers["host"] == "m" && r.cookies == ["a": "1", "speakhud": "zz"], "headers by lowercased name, cookies split")
    } else { t.expect(false, "a whole GET parses") }
    t.expect(parsed("GET / HTTP/1.1\r\nHost: m\r\n") == .incomplete, "a head still arriving: keep reading")
    let withBody = "POST /api/reply HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"key\":\"a\"}"
    t.expect(parsed(withBody) == .incomplete, "a body shorter than it says: keep reading")
    if case .request(let r) = parsed(withBody + "  ") {
        t.expect(r.body.count == 13 && r.json?["key"] as? String == "a", "then exactly the length it said, as JSON")
    } else { t.expect(false, "a whole POST parses") }
    t.expect(parsed("nonsense\r\n\r\n") == .bad, "no request line: refused")
    t.expect(parsed("GET http://evil/ HTTP/1.1\r\n\r\n") == .bad, "a target that isn't a path: refused")
    t.expect(parsed("POST / HTTP/1.1\r\nContent-Length: \(HTTP.maxBody + 1)\r\n\r\n") == .bad, "a body past the limit: refused before it's read")
    t.expect(parsed("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == .bad, "a negative length: refused")
    t.expect(parsed("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == .bad, "chunks: refused")
    t.expect(HTTP.parse(Data(repeating: 0x41, count: HTTP.maxHead + 1)) == .bad, "a head that never ends: refused")
    let wire = String(decoding: HTTP.Response.json(["a": 1], status: 409).wire(), as: UTF8.self)
    t.expect(wire.hasPrefix("HTTP/1.1 409 Conflict\r\n") && wire.contains("Content-Length: 7\r\n") && wire.hasSuffix("\r\n\r\n{\"a\":1}"),
             "a response says its status and length, then the body")
    t.expect(wire.contains("Content-Security-Policy: default-src 'none'") && wire.contains("Cache-Control: no-store")
             && wire.contains("X-Frame-Options: DENY"), "and that nothing may frame it, keep it, or load from elsewhere")

    // -- pairing ------------------------------------------------------------
    let b = Bench()
    b.phone.took(turn("a", "Fourteen replies sent."))
    t.expectEqual(b.phone.respond(to: get("/", paired: false)).status, 401, "no cookie: no page")
    let closed = b.phone.respond(to: get("/api/state", paired: false))
    t.expect(closed.status == 401 && !String(decoding: closed.body, as: UTF8.self).contains("Fourteen"), "and no turns")
    t.expectEqual(b.phone.respond(to: get("/pair", query: ["k": "wrong"], paired: false)).status, 403, "a wrong key doesn't pair")
    t.expectEqual(b.phone.respond(to: get("/pair", paired: false)).status, 403, "nor does no key")
    let pair = b.phone.respond(to: get("/pair", query: ["k": token], paired: false))
    let cookie = pair.headers.first { $0.0 == "Set-Cookie" }?.1 ?? ""
    t.expect(pair.status == 303 && pair.headers.contains { $0.0 == "Location" && $0.1 == "/" }, "the right key sends the phone to the page")
    t.expect(cookie.hasPrefix("\(Phone.cookie)=\(token);") && cookie.contains("HttpOnly") && cookie.contains("SameSite=Lax") && cookie.contains("Secure"),
             "holding the token where no script and no other site's request can use it")
    let plain = Bench(url: nil).phone.respond(to: get("/pair", query: ["k": token], paired: false))
    t.expect(plain.headers.first { $0.0 == "Set-Cookie" }?.1.contains("Secure") == false, "over plain http the cookie isn't marked Secure, or it would never come back")
    t.expect(Phone.same("abc", "abc") && !Phone.same("abc", "abd") && !Phone.same("ab", "abc") && !Phone.same("abcd", "abc") && !Phone.same("", "abc"),
             "tokens match only when every character does")

    // -- the page's files ---------------------------------------------------
    for (route, file) in Phone.assets {
        let r = b.phone.respond(to: get(route))
        t.expect(r.status == 200 && r.type == file.1 && !r.body.isEmpty, "\(route) serves \(file.0)")
    }
    let page = String(decoding: fm.contents(atPath: "phone/index.html") ?? Data(), as: UTF8.self)
    t.expect(page.contains(#"<meta charset="utf-8">"#) && page.contains("name=\"viewport\""), "the page says its own charset and viewport")
    t.expect(!page.contains("<style") && !page.contains("style=") && !page.contains("onclick=")
             && page.components(separatedBy: "<script").count == 2 && page.contains(#"<script src="/app.js">"#),
             "and has no inline style or script: the page's own policy would block them")
    let css = String(decoding: fm.contents(atPath: "phone/app.css") ?? Data(), as: UTF8.self)
    let js = String(decoding: fm.contents(atPath: "phone/app.js") ?? Data(), as: UTF8.self)
    t.expect(css.contains("[hidden] { display: none !important; }"), "hidden wins over every display rule")
    t.expect(!js.contains("innerHTML") && !js.contains("insertAdjacentHTML") && !js.contains("document.write"),
             "turn text never goes in as markup")
    b.phone.asset = { _ in nil }
    t.expectEqual(b.phone.respond(to: get("/")).status, 404, "files missing from the app: said, not a blank page")

    // -- what the page is told ---------------------------------------------
    b.phone.took(turn("b", "Three reviews are waiting.", name: "Review desk", origin: Origin(term: "Apple_Terminal", tty: "/dev/ttys004")))
    b.phone.took(turn("c", "clipboard text", answerable: false))
    let state = json(b.phone.respond(to: get("/api/state")))
    t.expectEqual(turns(state).map { $0["key"] as? String ?? "" }, ["b", "a"], "newest first; a read that isn't a Claude turn isn't listed")
    t.expect(turns(state)[1]["name"] as? String == "Grow guide replies" && turns(state)[1]["color"] as? String == "#2f6f4f"
             && turns(state)[1]["canReply"] as? Bool == true, "each with its name, its terminal's colour, and whether it can be answered")
    t.expect(turns(state)[0]["canReply"] as? Bool == false && turns(state)[0]["color"] is NSNull, "a pane that isn't iTerm2's can't")
    t.expect(state["away"] as? Bool == false, "away is off until switched on")

    // -- answering ----------------------------------------------------------
    let forged = b.phone.respond(to: post("/api/reply", ["key": "a", "text": "hi"], header: false))
    let formPost = b.phone.respond(to: post("/api/reply", ["key": "a", "text": "hi"], type: "text/plain"))
    t.expect(forged.status == 404 && formPost.status == 404 && b.delivered.isEmpty,
             "a post without the page's header, or not as JSON, types nothing: another site's form can send neither")
    let sent = json(b.phone.respond(to: post("/api/reply", ["key": "a", "text": "yes, post all three"])))
    t.expect(b.delivered.count == 1 && b.delivered[0].text == "yes, post all three" && b.delivered[0].session == pane.session,
             "an answer goes to that turn's own pane")
    t.expect(sent["sent"] as? Bool == true && turns(sent["state"] as? [String: Any] ?? [:]).last?["sent"] as? String == "yes, post all three",
             "and the page is told it went")
    t.expect(b.logs.contains("phone reply to Grow guide replies (19 chars): sent") && !b.logs.contains { $0.contains("post all three") },
             "the log has who and how long, never the words")
    b.outcome = .notAtPrompt
    let refused = json(b.phone.respond(to: post("/api/reply", ["key": "a", "text": "again"])))
    t.expect(refused["sent"] as? Bool == false && refused["outcome"] as? String == Reply.Outcome.notAtPrompt.description,
             "one that didn't go says why")
    b.outcome = .sent
    t.expectEqual(b.phone.respond(to: post("/api/reply", ["key": "gone", "text": "hi"])).status, 404, "a terminal off the list: not found")
    t.expectEqual(b.phone.respond(to: post("/api/reply", ["key": "b", "text": "hi"])).status, 409, "a pane that can't be reached: said")
    t.expectEqual(b.phone.respond(to: post("/api/reply", ["key": "a", "text": "  \n "])).status, 400, "nothing to send: refused")
    t.expectEqual(b.delivered.count, 2, "and none of those typed anything")

    // -- a question box -----------------------------------------------------
    b.phone.took(turn("a:question", "Which route?"))
    b.phone.took(turn("a:question", "- 1. Try Claude's first.\n- 2. Build our own."))
    b.screen = "Which route?\n❯ 1. Try Claude's first\n  2. Build our own\nEnter to select · Esc to cancel"
    let asking = json(b.phone.respond(to: get("/api/screen", query: ["key": "a"])))
    t.expect((asking["screen"] as? String)?.contains("Build our own") == true
             && turns(asking["state"] as? [String: Any] ?? [:]).first?["question"] as? String == "Which route?\n\n- 1. Try Claude's first.\n- 2. Build our own.",
             "its screen can be read, and the question stays up while the box does")
    t.expectEqual(b.phone.respond(to: post("/api/key", ["key": "a", "press": "rm -rf"])).status, 400, "only the named keys can be pressed")
    let keyed = json(b.phone.respond(to: post("/api/key", ["key": "a", "press": "2"])))
    t.expect(keyed["sent"] as? Bool == true && b.pressed == ["2"] && b.logs.contains("phone key 2 to Grow guide replies: sent"), "a key goes to its pane")
    b.screen = "working…\n────────────────\n❯ \n────────────────\n  status"
    let after = json(b.phone.respond(to: get("/api/screen", query: ["key": "a"])))
    t.expect(turns(after["state"] as? [String: Any] ?? [:]).first?["question"] is NSNull, "back at Claude's prompt, the question is over")
    b.screen = nil
    t.expectEqual(b.phone.respond(to: get("/api/screen", query: ["key": "a"])).status, 409, "a screen that can't be read: said")

    // -- the keys and the screen, as iTerm2 is asked ------------------------
    t.expect(Reply.keyScript(pane.session!, Reply.keys["down"]!).contains("(character id 27) & (character id 91) & (character id 66)"),
             "Down is the bytes the key sends")
    var asked: [String] = []
    t.expect(Reply.press("enter", in: pane, ask: { asked.append($0); return Reply.Answer(reply: "ok") }) == .sent
             && asked.count == 1 && asked[0].contains("(character id 13)") && asked[0].contains("newline no"),
             "a key is written to the pane, with no Return of its own")
    t.expect(Reply.press("f13", in: pane, ask: { _ in Reply.Answer(reply: "ok") }) == .failed("no such key"), "an unknown key is never written")
    t.expect(Reply.press("enter", in: pane, ask: { _ in Reply.Answer(reply: "missing") }) == .gone
             && Reply.press("enter", in: pane, ask: { _ in Reply.Answer(errorCode: -1743) }) == .denied, "a closed pane and a refused permission say so")
    t.expectEqual(Reply.screen(of: pane, lines: 2, ask: { _ in Reply.Answer(reply: "ok\none\ntwo\nthree\n\n   \n") }) ?? "", "two\nthree",
                  "the screen is its last lines, without the blank foot")
    t.expect(Reply.screen(of: pane, ask: { _ in Reply.Answer(reply: "missing") }) == nil, "and nil once the pane is gone")

    // -- away and its pushes ------------------------------------------------
    t.expect(b.pushes.isEmpty, "at the Mac, nothing is pushed")
    let on = json(b.phone.respond(to: post("/api/away", ["on": true])))
    _ = b.phone.respond(to: post("/api/away", ["on": true]))
    t.expect(on["away"] as? Bool == true && b.phone.away && b.awayChanges == [true], "the page can switch Away on, once")
    t.expectEqual(b.phone.respond(to: post("/api/away", ["on": "yes"])).status, 400, "on must be true or false")
    b.phone.took(turn("a", "Done. " + String(repeating: "word ", count: 100)))
    t.expectEqual(b.pushes.count, 1, "away, a finished turn is pushed")
    if let push = b.pushes.first, let body = try? JSONSerialization.jsonObject(with: push.httpBody ?? Data()) as? [String: Any] {
        t.expect(push.url?.absoluteString == "https://push.example.com/" && push.httpMethod == "POST"
                 && push.value(forHTTPHeaderField: "Authorization") == "Bearer tk_secret", "to the push server, with its token")
        t.expect(body["topic"] as? String == "terminals" && body["title"] as? String == "Grow guide replies", "on its topic, titled with the terminal")
        t.expect((body["message"] as? String)?.count == Phone.pushLength && (body["message"] as? String)?.hasSuffix("…") == true
                 && (body["message"] as? String)?.contains("\n") == false, "its words on one line, cut to length")
        t.expectEqual(body["click"] as? String ?? "", "https://my-mac.example.ts.net/#a", "and a tap opens that terminal's window on the page")
    } else { t.expect(false, "the push is JSON") }
    b.phone.took(turn("a:question", "Which route?"))
    b.phone.took(turn("a:question", "- 1. One.\n- 2. Two."))
    t.expect(b.pushes.count == 2 && String(decoding: b.pushes[1].httpBody ?? Data(), as: UTF8.self).contains("is asking"),
             "a question pushes once, as a question; its options don't push again")
    b.phone.took(turn("d", "clipboard", answerable: false))
    t.expectEqual(b.pushes.count, 2, "what isn't a Claude turn is never pushed")
    b.phone.setAway(false)
    b.phone.took(turn("a", "back"))
    t.expect(b.pushes.count == 2 && b.awayChanges == [true, false], "back at the Mac, pushes stop")
    let quiet = Bench(ntfy: nil)
    quiet.phone.setAway(true)
    quiet.phone.took(turn("a", "hello"))
    t.expect(quiet.pushes.isEmpty && quiet.logs.contains { $0.contains("no ntfy topic") }, "no push server set up: said in the log, nothing sent")
    t.expect(!(b.logs + quiet.logs).contains { $0.contains(token) || $0.contains("tk_secret") }, "no token is ever logged")

    // -- through the real server, on this Mac's loopback --------------------
    guard let server = try? PhoneServer(port: 0, handle: { b.phone.respond(to: $0) }) else {
        t.expect(false, "the server can listen on a free loopback port")
        return
    }
    server.start()
    defer { server.stop() }
    func spin(_ seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    spin(3) { server.port != nil }
    guard let port = server.port else {
        t.expect(false, "the server is ready within 3 s")
        return
    }
    func fetch(_ path: String, cookie: String?) -> (status: Int, body: String)? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 5
        if let cookie = cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        var got: (Int, String)?
        var finished = false
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { got = (http.statusCode, String(decoding: data ?? Data(), as: UTF8.self)) }
            finished = true
        }.resume()
        spin(6) { finished }
        return got.map { (status: $0.0, body: $0.1) }
    }
    t.expectEqual(fetch("/api/state", cookie: nil)?.status ?? 0, 401, "over a real connection, an unpaired phone is turned away")
    let live = fetch("/api/state", cookie: "\(Phone.cookie)=\(token)")
    t.expect(live?.status == 200 && live?.body.contains("\"key\":\"a\"") == true, "and a paired one gets its terminals")
    t.expect(fetch("/", cookie: "\(Phone.cookie)=\(token)")?.status == 404, "the page route answers too (its files were taken away above)")
}
