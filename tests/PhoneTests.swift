// Phone tests. Registered in tests/main.swift.
//
// The real Phone on requests built by hand (what PhoneServer would hand it), with a
// stand-in for iTerm2 and for the push server; then one real round trip through
// PhoneServer on this Mac's loopback. Nothing here reaches a terminal or a network.
import Cocoa
import ImageIO

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

/// The box of choices `screen` is showing, if it is showing one.
private func boxOn(_ screen: String) -> TerminalBox? { Reply.showing(screen).box }

/// What the page sends back with a tap: the box it has drawn for `key`, as app.js builds
/// it from the state the Mac gave it (what it asks, its strip, each choice's label).
private func drew(_ state: [String: Any], _ key: String) -> [String: Any] {
    guard let box = turns(state).first(where: { $0["key"] as? String == key })?["box"] as? [String: Any] else { return [:] }
    return ["ask": box["ask"] ?? NSNull(), "tabs": box["tabs"] ?? NSNull(),
            "rows": (box["rows"] as? [[String: Any]] ?? []).map { $0["label"] as? String ?? "" }]
}

/// A real Claude Code screen, captured from a scratch session (tests/fixtures/screens).
private func screenshot(_ name: String) -> String {
    String(decoding: fm.contents(atPath: "tests/fixtures/screens/\(name).txt") ?? Data(), as: UTF8.self)
}

/// iTerm2, as Phone reaches it through Reply: each script it's asked is taken for what it
/// does (the survey, a look at a pane's screen, a paste, Return, a key, typed words, a
/// close), noted, and answered the way iTerm2 would. One screen stands for whichever
/// pane is asked about. A paste lands the way Claude Code's prompt takes one (seen in
/// 2.1.294): the words show in the box until Return, with a marker at the front in place
/// of each picture's path.
private final class FakeITerm {
    static let promptScreen = "some output\n────────────────\n❯ \n────────────────\n  status"

    var screen: String? = FakeITerm.promptScreen { didSet { held = nil } }   // nil: the pane has gone
    var open: [Reply.Pane]? = nil     // what a survey says is open and showing; nil: iTerm2 isn't saying
    var takesPaste = true             // false: a paste never shows in the prompt box
    var pictureFiles: [String] = []   // the paths Claude Code would find to be pictures
    private(set) var pasted: [(text: String, session: String?)] = []
    private(set) var pressed: [String] = []
    private(set) var typed: [String] = []
    private(set) var closed: [String?] = []
    private var held: String?         // what the prompt box holds since a paste, until Return

    func ask(_ source: String) -> Reply.Answer {
        if source == Reply.surveyScript {
            guard let open = open else { return Reply.Answer(reply: "missing") }
            return Reply.Answer(reply: "ok" + open.map { "\u{1E}\($0.session)\u{1F}\($0.name)\u{1F}\($0.screen)" }.joined())
        }
        let session = source.components(separatedBy: "(id of s) is \"").dropFirst().first?.components(separatedBy: "\"").first
        guard let screen = screen else { return Reply.Answer(reply: "missing") }
        if source.contains("contents of s") {
            let shown = held.map { "some output\n────────────────\n❯ \($0)\n────────────────\n  status" } ?? screen
            return Reply.Answer(reply: "ok\n" + shown)
        }
        if source.contains("tell s to close") {
            closed.append(session)
        } else if source.contains("\"[200~\"") {
            // The pasted line: what sits between the paste brackets, un-escaped.
            let text = unquoted(source.components(separatedBy: "\"[200~\" & \"").last?
                .components(separatedBy: "\" & (character id 27) & \"[201~\"").first ?? "")
            pasted.append((text, session))
            if takesPaste {
                var words = text, markers: [String] = []
                for path in pictureFiles where words.contains(path) {
                    words = words.replacingOccurrences(of: " " + path, with: "").replacingOccurrences(of: path, with: "")
                    markers.append("[Image #\(markers.count + 1)]")
                }
                held = markers.joined(separator: " ") + words
            }
        } else if source == Reply.returnScript(session ?? "") {
            held = nil   // the Return that follows a paste: the message goes
        } else if source.contains("tell s to write text ((character id") {
            let codes = Self.ids(in: source)
            let name = Reply.keys.first { $0.value == codes }?.key ?? "?"
            pressed.append(name)
            if name == "enter" { held = nil }
        } else if let line = source.components(separatedBy: "tell s to write text \"").dropFirst().first?.components(separatedBy: "\" newline no").first {
            typed.append(unquoted(line))
        }
        return Reply.Answer(reply: "ok")
    }

    private func unquoted(_ literal: String) -> String {
        literal.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// The character ids a script writes, in order.
    private static func ids(in source: String) -> [Int] {
        source.components(separatedBy: "(character id ").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
    }
}

/// A Phone on throwaway settings, over a fake iTerm2 and a stand-in for the push server:
/// what the page asks runs the real reading and writing of terminals (Reply), and what
/// reached iTerm2 is kept here.
private final class Bench {
    let suite = "speakhud-phone-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let phone: Phone
    let term = FakeITerm()
    var delivered: [(text: String, session: String?)] { term.pasted }   // each paste that reached a pane
    var pressed: [String] { term.pressed }                              // each key, by name
    var typed: [String] { term.typed }
    var shutPanes: [String?] { term.closed }
    var screen: String? { get { term.screen } set { term.screen = newValue } }
    var open: [Reply.Pane]? { get { term.open } set { term.open = newValue } }
    var pushes: [URLRequest] = []
    var logs: [String] = []
    var awayChanges: [Bool] = []
    var outcome = Reply.Outcome.sent   // how resuming an old session goes
    var old: [OldSessions.Session] = []
    var running: Set<String> = []
    var reopened: [String] = []
    var saves = 0
    var heardSizes: [Int] = []       // each recording the page sent to be turned into words
    var hearAnswer: Result<String, Dictation.Failure>? = .success("Yes, go ahead.")   // nil: still hearing it
    var hearDone: ((Result<String, Dictation.Failure>) -> Void)?
    var livePieces: [String] = []    // each piece of a word-for-word dictation: "id rate bytes last"
    var liveAnswer: Result<String, Dictation.Failure> = .success("Yes, go")

    init(url: String? = "https://my-mac.example.ts.net", ntfy: String? = "https://push.example.com/terminals") {
        defaults = UserDefaults(suiteName: suite)!
        var config = PhoneConfig(token: token)
        config.url = url
        config.ntfy = ntfy
        config.ntfyToken = ntfy == nil ? nil : "tk_secret"
        phone = Phone(config: config, defaults: defaults)
        phone.terminal = Reply.Terminal(ask: term.ask, wait: { _ in })
        phone.oldSessions = { [unowned self] in self.old }
        phone.runningIDs = { [unowned self] in self.running }
        phone.reopen = { [unowned self] session in self.reopened.append(session.id + " in " + session.cwd); return self.outcome }
        phone.save = { [unowned self] _ in self.saves += 1 }
        phone.hear = { [unowned self] data, done in
            self.heardSizes.append(data.count)
            if let answer = self.hearAnswer { done(answer) } else { self.hearDone = done }
        }
        phone.hearLive = { [unowned self] id, rate, sound, last, done in
            self.livePieces.append("\(id) \(rate) \(sound.count) \(last ? "last" : "more")")
            done(self.liveAnswer)
        }
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

    // -- a box, read off the terminal's own screen ----------------------------
    let atPrompt = "done\n────────────────\n❯ \n────────────────\n  status"
    t.expect(boxOn(screenshot("prompt")) == nil && boxOn(atPrompt) == nil, "Claude's prompt is not a box")
    if let box = boxOn(screenshot("ask-single")) {
        t.expect(box.ask == "Which colour for the bar?" && box.tabs == "☐ Colour", "a question: what it asks, under its heading")
        t.expectEqual(box.rows.map { $0.label }, ["Forest", "Navy", "Type something.", "Chat about this"], "its choices, the one under the rule too")
        t.expect(box.rows[0].detail == "Like Grow Guide" && box.rows[0].number == 1 && box.rows[0].cursor && !box.rows[1].cursor && box.rows[2].types,
                 "each with its description, its number, where the cursor is, and which one takes words")
        t.expect(box.keys(toPick: 1) ?? [] == ["2"] && box.keys(toPick: 9) == nil, "a numbered choice is picked by its digit")
        t.expect(box.hints?.contains("Esc to cancel") == true, "and what the box says its keys are")
    } else { t.expect(false, "a one-question box is read") }
    if let box = boxOn(screenshot("ask-first")) {
        t.expect(box.ask == "Which route do you want?" && box.tabs == "☐ Route ☐ Extras ✔ Submit" && box.rows.count == 4,
                 "the first of several questions, with the strip that says where you are")
    } else { t.expect(false, "a several-question box is read") }
    if let box = boxOn(screenshot("ask-multi-checked")) {
        t.expectEqual(box.rows.map { $0.checked.map { $0 ? "x" : "o" } ?? "-" }, ["x", "o", "x", "o", "-", "-"], "pick-any-that-apply: which are ticked")
        t.expect(box.rows[0].label == "Speech" && box.rows[0].detail == "Phone reads aloud" && box.rows[4].label == "Submit" && box.rows[4].number == nil,
                 "labels without their tick boxes, and Submit as a row of its own")
        t.expect(box.keys(toPick: 4) ?? [] == ["down", "down", "down", "down", "enter"] && box.keys(toPick: 2) ?? [] == ["3"],
                 "a row with no number is reached by arrows from the cursor, then Enter")
    } else { t.expect(false, "a pick-any box is read") }
    if let box = boxOn(screenshot("ask-submit")) {
        t.expect(box.ask.hasPrefix("Review your answers") && box.ask.contains("→ Speech, Screen") && box.rows.map { $0.label } == ["Submit answers", "Cancel"],
                 "the last step shows the answers and asks to submit them")
    } else { t.expect(false, "the submit step is read") }
    if let box = boxOn(screenshot("permission")) {
        t.expect(box.ask.contains("touch made-by-test.txt") && box.ask.hasSuffix("Do you want to proceed?"), "a permission box: the command and the question")
        t.expect(box.rows.count == 4 && box.rows[0].label == "Yes" && box.rows[3].label == "No"
                 && box.rows[1].label == "Yes, and always allow access to" && box.rows[1].detail?.contains("/Users/you/project") == true,
                 "its four choices, a wrapped one kept whole")
    } else { t.expect(false, "a permission box is read") }
    if let box = boxOn(screenshot("trust")) {
        t.expect(box.rows.map { $0.label } == ["No, exit", "Yes, I trust this folder"] && box.rows.allSatisfy { $0.number == nil } && box.rows[0].cursor,
                 "a box with no numbers at all")
        t.expect(box.keys(toPick: 1) ?? [] == ["down", "enter"] && box.keys(toPick: 0) ?? [] == ["enter"], "is answered by arrows and Enter")
    } else { t.expect(false, "the trust box is read") }
    t.expect(boxOn("❯ what I typed earlier\n  and its second line\n\n⏺ Claude's answer, at length.\n  More of it.\n\n✻ Working… (esc to interrupt)") == nil,
             "a ❯ in the conversation is not a cursor: nothing is invented from a turn in progress")

    // A box is read only where Claude says it has one up. "It isn't the prompt" is not
    // that: a message being written and a shell were both read as lists of choices.
    let longRule = String(repeating: "─", count: 60)
    let draft = ["done", longRule, "❯ 1. fix the header", longRule, "  speakhud (main*) | Opus 5.5 ctx:51% used"].joined(separator: "\n")
    let shellPrompt = "  build ok\n  2 warnings\n❯ rm -rf build"
    t.expect(boxOn(draft) == nil, "a message being written that starts \"1. \" is not a box, and its status line is not a choice")
    t.expect(boxOn(shellPrompt) == nil, "a shell whose prompt is ❯, under indented output, is not a box")
    t.expect(boxOn("  1. first\n  2. second\n❯ git status") == nil, "nor is one under a numbered list it printed")
    t.expect(boxOn(["done", longRule, "❯ 1. Yes", "  2. No", longRule, "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent"].joined(separator: "\n")) == nil,
             "numbered lines between the prompt's rules, with nothing that says keys answer them, are not a box either")
    t.expect(boxOn("  one\n❯ two\n  three\nmain · 3 files changed") == nil, "a line with a dot in the middle of it is not a box saying how to answer")
    t.expect(boxOn(screenshot("permission") + "\nchris@mac project % ") == nil, "nor is a box left on the screen of a pane that has dropped to its shell")

    // Not every box names its keys under its choices. Claude Code 2.1.294's plan approval
    // has there only how to open the plan in an editor, or nothing at all, and a
    // permission box may say "(esc)" in its last choice and no more (these three are
    // built from its own code, not captured). What marks them is how Claude draws every
    // dialog: a rule across the pane, what it asks, then its choices numbered from 1.
    let wide = String(repeating: "─", count: 110), dashes = String(repeating: "╌", count: 110)
    let plan = ["⏺ I have a plan for the migration.", "", wide, " Ready to code?", "", " Here is Claude's plan:", dashes,
                " Move the old tables, then drop them.", dashes, "",
                " Claude has written up a plan and is ready to execute. Would you like to proceed?", "",
                " ❯ 1. Yes, and auto-accept edits", "   2. Yes, and manually approve edits", "   3. No, keep planning"].joined(separator: "\n")
    let planInEditor = " ctrl+g to edit in Vim · ~/.claude/plans/happy-otter.md"
    let escInRow = ["⏺ Bash(rm -rf build)", "  ⎿  Waiting…", "", wide, " Bash command", "", "   rm -rf build", "   Remove the build folder", "",
                    " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in /Users/you/project",
                    "   3. No, and tell Claude what to do differently (esc)"].joined(separator: "\n")
    if let box = boxOn(plan) {
        t.expect(box.ask.hasSuffix("Would you like to proceed?") && box.hints == nil && box.rows[0].cursor
                 && box.rows.map { $0.label } == ["Yes, and auto-accept edits", "Yes, and manually approve edits", "No, keep planning"],
                 "a plan waiting for its yes is a box, though nothing under its choices says so")
    } else { t.expect(false, "a plan waiting for its yes is read as a box") }
    t.expect(boxOn(plan + "\n\n" + planInEditor)?.rows.count == 3 && boxOn(plan + "\n\n" + planInEditor)?.hints == "ctrl+g to edit in Vim · ~/.claude/plans/happy-otter.md",
             "and so it is with a line under them that names no key that answers it")
    t.expect(boxOn(plan + "\n\n ctrl+g to edit in Vim ·\n ~/.claude/plans/happy-otter.md")?.hints == "ctrl+g to edit in Vim · ~/.claude/plans/happy-otter.md",
             "or with that line wrapped onto a second by a narrow pane, set in like the first")
    t.expect(boxOn(escInRow)?.rows.map { $0.number } == [1, 2, 3] && boxOn(escInRow)?.rows[2].label.hasSuffix("(esc)") == true
             && boxOn(escInRow)?.ask.hasSuffix("Do you want to proceed?") == true, "a permission box whose one word about keys is in its last choice is a box")
    let unsaid = screenshot("permission").components(separatedBy: "\n").filter { !$0.contains("Esc to cancel") }.joined(separator: "\n")
    t.expect(unsaid != screenshot("permission") && boxOn(unsaid)?.rows.map { $0.label } == boxOn(screenshot("permission"))?.rows.map { $0.label },
             "the captured permission box reads the same with the line of keys under it taken away")
    // That makes a box of nothing else. The prompt's ❯ sits right under its rule, with
    // nothing asked between; a shell's command line has no number, and its prompt
    // starts at the edge of the pane, not set in with a box's choices.
    for (left, what) in [(unsaid, "a permission box"), (plan, "a plan"), (escInRow, "a box that says (esc)"), (screenshot("ask-submit"), "a question's last step")] {
        t.expect(boxOn(left) != nil && boxOn(left + "\nchris@mac project % ") == nil, "\(what) left on the screen of a pane that has dropped to its shell is not a box")
    }
    t.expect(boxOn([wide, " Notes from earlier", "", wide, "❯ 1. Yes", "  2. No", wide].joined(separator: "\n")) == nil
             && boxOn([wide, " Notes from earlier", "  1. Yes", wide, "❯ 2. No", "  3. Maybe", wide].joined(separator: "\n")) == nil,
             "numbered lines being written in the prompt are not a box whatever was said under a rule further up: nothing is asked between the prompt's own rule and them")
    let lettered = String(repeating: "─", count: 40) + " plan mode " + String(repeating: "─", count: 40)
    t.expect(boxOn([wide, " Notes from earlier", lettered, "❯ 1. Yes", "  2. No"].joined(separator: "\n")) == nil,
             "nor when the prompt's rule has words set in it: a ❯ right under a rule is the prompt's")
    t.expect(boxOn([wide, " Notes from earlier", "  1. Yes", wide, "  2. No", "❯ 3. Maybe"].joined(separator: "\n")) == nil,
             "and a rule through numbered lines, with no line of keys under them, is the prompt's rule under a list Claude wrote, not a box")
    t.expect(boxOn([wide, "Steps:", "  1. first", "  2. second", "❯ ls"].joined(separator: "\n")) == nil
             && boxOn([wide, "  status", "", "~/project main", "❯ make build", "  compiling a", "  compiling b"].joined(separator: "\n")) == nil,
             "nor is a shell under a rule Claude left behind: the line its ❯ is on has no number")
    t.expect(boxOn(plan + "\n\n one\n two\n three") == nil, "more under its choices than a line and its wrap is not a box's own last line")
    t.expect(boxOn([wide, " Pick one", "", " ❯ No", "   Yes"].joined(separator: "\n")) == nil,
             "choices with no numbers and no line of keys under them are not read as a box: nothing tells them from a shell's output")
    t.expect(boxOn("⏺ Which first?\n\n❯ 1. the header\n  2. the footer") == nil,
             "a numbered list you sent, still at the foot of the screen, is not a box: no rule opens it")
    t.expect(boxOn([wide, "", " ❯ 1. Yes", "   2. No"].joined(separator: "\n")) == nil,
             "nor are numbered choices under a rule that asks nothing: a tap could not tell one such box from the next")
    var draftDesk = PhoneDesk()
    let draftAsked = draftDesk.met([Reply.Pane(session: pane.session!, name: "✳ Grow guide replies — ~", screen: draft)], now: t0)
    t.expect(draftAsked.isEmpty && draftDesk.turns.count == 1 && draftDesk.turns[0].box == nil && draftDesk.turns[0].context == 51,
             "so a terminal with such a message in its prompt is not asking anything, and its status line is read as one")

    // -- every open terminal, and none that has closed ----------------------
    let other = "0A1B2C3D-0000-4000-8000-00000000000B", shell = "0A1B2C3D-0000-4000-8000-00000000000C"
    t.expectEqual(Reply.paneName("✳ Grow guide replies — ~/GitHub/grow-guide"), "Grow guide replies", "a pane's title, down to the name its turns go by")
    t.expectEqual(Reply.paneName("◐ Before — and after — ~/x"), "Before — and after", "only the folder on the end is cut")
    t.expectEqual(Reply.paneName("◑ SpeakerHug crash logs\u{00A0}—\u{00A0}~/GitHub/mac-apps/speakhud"), "SpeakerHug crash logs",
                  "as iTerm2 really gives it, with no-break spaces round the dash")
    t.expectEqual(Reply.paneName("zsh"), "zsh", "a plain title is left alone")
    /// A terminal that answers every script the same way.
    func saying(_ answer: Reply.Answer) -> Reply.Terminal { Reply.Terminal(ask: { _ in answer }, wait: { _ in }) }
    let surveyed = Reply.survey(via: saying(Reply.Answer(reply: "ok\u{1E}\(other)\u{1F}✳ Review desk — ~\u{1F}line one\nline\ttwo\n\n\u{1E}not-an-id\u{1F}x\u{1F}y\u{1E}only two\u{1F}fields")))
    t.expect(surveyed?.count == 1 && surveyed?[0] == Reply.Pane(session: other, name: "✳ Review desk — ~", screen: "line one\nline\ttwo"),
             "iTerm2's panes are read by id, title and screen, whatever the screen holds; a record that isn't one is skipped")
    t.expect(Reply.survey(via: saying(Reply.Answer(reply: "missing"))) == nil, "iTerm2 not running: nothing known, which isn't nothing open")
    t.expect(Reply.surveyScript.contains("(character id 31)") && !Reply.surveyScript.contains("& tab &"),
             "the separators are spelled as character ids: inside iTerm2's tell, tab is one of its tabs")
    t.expect(Reply.showing(atPrompt).isClaude && Reply.showing("Thinking… (esc to interrupt)").isClaude && Reply.showing("❯ 1. Yes\nEnter to select · Esc to cancel").isClaude
             && !Reply.showing("chris@mac ~ % ls\nnotes.txt").isClaude, "Claude Code's screen is told from a shell's")
    t.expect(Reply.showing(atPrompt, title: "◐ Grow guide replies — ~").busy && !Reply.showing(atPrompt, title: "✳ Grow guide replies — ~").busy
             && !Reply.showing("% ", title: "zsh").busy && Reply.showing("✻ Crunching… (esc to interrupt)", title: "✳ x").busy,
             "a spinning glyph on the title, or its screen saying so, is a terminal at work; ✳ is one waiting for you")
    t.expect(Reply.showing("chris@mac ~ % ", title: "~ — zsh") == .working(onScreen: false) && !Reply.showing("chris@mac ~ % ", title: "~ — zsh").isClaude
             && Reply.showing("⏺ A long answer, with no prompt box in sight.", title: "◐ Review desk — ~").busy,
             "a glyph on the title alone says a turn may be running, never that the screen is Claude Code's: a shell's title can start with one")
    t.expect(Reply.showing("how to answer: Esc to cancel\nchris@mac ~ % ") == .notClaude("nothing at the foot of its screen is Claude's prompt or a box of its")
             && Reply.showing(" \n ") == .notClaude("its screen is blank") && Reply.showing("Paste the code:\n > \n Enter to confirm · Esc to cancel") == .keys("Enter to confirm · Esc to cancel"),
             "what says it takes keys counts at the foot of the screen, not further up it; and what is none of Claude's says why")

    var openDesk = PhoneDesk()
    openDesk.took(turn("a", "done"), now: t0)
    let justAsked = openDesk.met([Reply.Pane(session: pane.session!, name: "✳ Grow guide replies — ~", screen: screenshot("permission")),
                                  Reply.Pane(session: other, name: "◐ Review desk — ~/x", screen: atPrompt),
                                  Reply.Pane(session: shell, name: "zsh", screen: "chris@mac ~ % ")], now: t0.addingTimeInterval(5))
    t.expectEqual(openDesk.turns.map { $0.key }, ["a", PhoneDesk.paneKey + other], "an open Claude terminal with no turn yet gets a window; a shell doesn't; one with a turn keeps it")
    t.expect(openDesk.turns[1].name == "Review desk" && openDesk.turns[1].text.isEmpty && Reply.canReach(openDesk.turns[1].origin) && openDesk.turns[1].busy,
             "named as its turns will be, empty, answerable, and marked as working")
    t.expect(justAsked == ["a"] && openDesk.turns[0].box?.rows.count == 4 && !openDesk.turns[0].busy, "a terminal showing a box has it, and is said to have just asked")
    t.expect(openDesk.met([Reply.Pane(session: pane.session!, name: "✳ Grow guide replies — ~", screen: screenshot("permission")),
                           Reply.Pane(session: other, name: "✳ Review desk — ~/x", screen: atPrompt)], now: t0.addingTimeInterval(9)).isEmpty
             && !openDesk.turns[1].busy, "the same box a look later is not new; a terminal that has finished stops being marked as working")
    openDesk.saw("a", atPrompt)
    t.expect(openDesk.turns[0].box == nil, "a fresh look that finds the prompt takes the box away")
    openDesk.took(turn("b", "hello", name: "Review desk", origin: Origin(term: "iTerm.app", session: other)), now: t0.addingTimeInterval(9))
    t.expectEqual(openDesk.turns.map { $0.key }, ["b", "a"], "its first real turn takes the empty window's place")
    let kept = PhoneDesk(snapshot: openDesk.snapshot(), now: t0.addingTimeInterval(60))
    t.expect(kept.turns == openDesk.turns, "the list comes back the same after a restart")
    t.expect(PhoneDesk(snapshot: openDesk.snapshot(), now: t0.addingTimeInterval(PhoneDesk.maxAge + 60)).turns.isEmpty
             && PhoneDesk(snapshot: Data("junk".utf8)).turns.isEmpty && PhoneDesk(snapshot: nil).turns.isEmpty,
             "but not turns a week old, and not from a file that isn't one")
    openDesk.met([Reply.Pane(session: other, name: "✳ Review desk — ~/x", screen: atPrompt)], now: t0.addingTimeInterval(20))
    t.expectEqual(openDesk.turns.map { $0.key }, ["b"], "a terminal that has closed leaves the list")

    let o = Bench()
    o.open = [Reply.Pane(session: pane.session!, name: "✳ Grow guide replies — ~", screen: atPrompt),
              Reply.Pane(session: other, name: "◐ Review desk — ~/x", screen: atPrompt)]
    let seen = turns(json(o.phone.respond(to: get("/api/state"))))
    t.expect(seen.map { $0["name"] as? String ?? "" } == ["Grow guide replies", "Review desk"] && seen.allSatisfy { $0["canReply"] as? Bool == true && $0["text"] as? String == "" },
             "the page is shown every open Claude terminal, even before any has finished a turn")
    t.expect(seen[0]["busy"] as? Bool == false && seen[1]["busy"] as? Bool == true && seen[0]["box"] is NSNull, "and which of them is working")
    t.expectEqual(o.saves, 1, "and the list is kept as it changes")
    o.open = []
    t.expectEqual(turns(json(o.phone.respond(to: get("/api/state")))).count, 2, "iTerm2 is asked at most every \(Int(Phone.scanEvery)) s, however often the page polls")
    o.open = nil
    o.phone.scan(now: Date().addingTimeInterval(Phone.scanEvery + 1))
    t.expectEqual(o.phone.desk.turns.count, 2, "iTerm2 not saying leaves the list alone")

    // -- answering a box from the page ----------------------------------------
    o.open = [Reply.Pane(session: pane.session!, name: "✳ Grow guide replies — ~", screen: screenshot("ask-single"))]
    o.phone.scan(now: Date().addingTimeInterval(2 * Phone.scanEvery + 2))
    let boxKey = PhoneDesk.paneKey + pane.session!
    let drawn = turns(o.phone.state()).first?["box"] as? [String: Any]
    let drawnRows = drawn?["rows"] as? [[String: Any]] ?? []
    t.expect(drawn?["ask"] as? String == "Which colour for the bar?" && drawnRows.count == 4 && drawnRows[1]["label"] as? String == "Navy"
             && drawnRows[1]["number"] as? Int == 2 && drawnRows[2]["types"] as? Bool == true, "the page is given the box as its terminal shows it")
    o.screen = screenshot("ask-single")
    let colours = drew(o.phone.state(), boxKey)   // a tap says which box the page had drawn
    let picked = json(o.phone.respond(to: post("/api/pick", ["key": boxKey, "row": 1, "label": "Navy", "box": colours])))
    t.expect(picked["sent"] as? Bool == true && o.pressed == ["2"] && o.logs.contains("phone pick 2 of 4 in Grow guide replies: sent"), "a tap on a choice presses its digit")
    let stale = json(o.phone.respond(to: post("/api/pick", ["key": boxKey, "row": 1, "label": "Forest", "box": colours])))
    t.expect(stale["sent"] as? Bool == false && o.pressed == ["2"] && (stale["outcome"] as? String)?.contains("changed") == true,
             "a choice that isn't where the page drew it presses nothing")
    let own = json(o.phone.respond(to: post("/api/pick", ["key": boxKey, "row": 2, "label": "Type something.", "text": " teal,\nplease ", "box": colours])))
    t.expect(own["sent"] as? Bool == true && o.pressed == ["2", "3", "enter"] && o.typed == ["teal, please"],
             "your own answer: its row's digit, the words typed on one line, Enter")
    t.expectEqual(o.phone.respond(to: post("/api/pick", ["key": boxKey, "row": 0, "label": "Forest", "text": "x", "box": colours])).status, 400, "a choice that takes no words refuses them")
    o.screen = screenshot("trust")
    let trusting = drew(json(o.phone.respond(to: get("/api/screen", query: ["key": boxKey])))["state"] as? [String: Any] ?? [:], boxKey)
    _ = o.phone.respond(to: post("/api/pick", ["key": boxKey, "row": 1, "label": "Yes, I trust this folder", "box": trusting]))
    t.expectEqual(o.pressed, ["2", "3", "enter", "down", "enter"], "a choice with no number is reached with arrows and Enter")
    o.screen = atPrompt
    let gone = json(o.phone.respond(to: post("/api/pick", ["key": boxKey, "row": 0, "label": "No, exit", "box": trusting])))
    t.expect(gone["sent"] as? Bool == false && turns(gone["state"] as? [String: Any] ?? [:]).first?["box"] is NSNull, "a box that has gone is said to have, and leaves the page")

    // A message being written in the prompt: nothing to push as asking, nothing a tap can send.
    let writing = Bench()
    writing.phone.setAway(true)
    writing.open = [Reply.Pane(session: pane.session!, name: "✳ Grow guide replies — ~", screen: draft)]
    writing.phone.scan()
    writing.screen = draft
    let statusLine = "speakhud (main*) | Opus 5.5 ctx:51% used"
    let onDraft = json(writing.phone.respond(to: post("/api/pick", ["key": boxKey, "row": 1, "label": statusLine,
                                                                    "box": ["ask": "", "tabs": NSNull(), "rows": ["fix the header", statusLine]]])))
    t.expect(writing.pushes.isEmpty, "away, a message being written that starts \"1. \" is not pushed as a question")
    t.expect(onDraft["sent"] as? Bool == false && writing.pressed.isEmpty, "and no tap presses Down and Enter on it, which would send it")
    // A plan waiting for its yes in that terminal is asking, though no line under its choices names a key.
    writing.open = [Reply.Pane(session: pane.session!, name: "✳ Grow guide replies — ~", screen: plan)]
    writing.phone.scan(now: Date().addingTimeInterval(Phone.scanEvery + 1))
    writing.screen = plan
    let planPush = String(decoding: writing.pushes.first?.httpBody ?? Data(), as: UTF8.self)
    t.expect(writing.pushes.count == 1 && planPush.contains("Grow guide replies is asking") && planPush.contains("Ready to code?"),
             "away, a plan waiting for its yes is pushed as asking, with what it says")
    let approved = json(writing.phone.respond(to: post("/api/pick", ["key": boxKey, "row": 1, "label": "Yes, and manually approve edits",
                                                                     "box": drew(writing.phone.state(), boxKey)])))
    t.expect(approved["sent"] as? Bool == true && writing.pressed == ["2"], "and a tap on one of its choices presses that choice's digit")

    // -- a tap answers the box the page drew, and no other ----------------------
    // Every permission box has Yes first: a row and its label can't tell two of them apart.
    let k = Bench()
    k.phone.took(turn("a", "Shall I?"))
    /// The page looks at a's screen: what it has drawn after that.
    func looked(_ bench: Bench) -> [String: Any] {
        drew(json(bench.phone.respond(to: get("/api/screen", query: ["key": "a"])))["state"] as? [String: Any] ?? [:], "a")
    }
    let toTouch = screenshot("permission"), toRemove = toTouch.replacingOccurrences(of: "touch made-by-test.txt", with: "rm -rf build")
    k.screen = toTouch
    let yes: [String: Any] = ["key": "a", "row": 0, "label": "Yes", "box": looked(k)]
    t.expect(json(k.phone.respond(to: post("/api/pick", yes)))["sent"] as? Bool == true && k.pressed == ["1"], "Yes, tapped on the box the page drew, is pressed")
    k.screen = toRemove
    let doubled = json(k.phone.respond(to: post("/api/pick", yes)))
    t.expect(doubled["sent"] as? Bool == false && (doubled["outcome"] as? String)?.contains("changed") == true,
             "the same tap again, with a different permission box now up, is not sent")
    t.expectEqual(k.pressed, ["1"], "and presses nothing: that box's Yes is not the Yes the page showed")
    t.expect(((turns(doubled["state"] as? [String: Any] ?? [:]).first?["box"] as? [String: Any])?["ask"] as? String)?.contains("rm -rf build") == true,
             "the page is given the box that is up now instead")
    // The same box, moved on: its cursor elsewhere, a tick made in it. It is still the box that was drawn.
    k.screen = screenshot("trust")
    let trusted = looked(k)
    k.screen = screenshot("trust").replacingOccurrences(of: " ❯ No, exit", with: "   No, exit").replacingOccurrences(of: "   Yes, I trust", with: " ❯ Yes, I trust")
    _ = k.phone.respond(to: post("/api/pick", ["key": "a", "row": 0, "label": "No, exit", "box": trusted]))
    t.expectEqual(k.pressed, ["1", "up", "enter"], "a box whose cursor has moved since it was drawn is still that box, and the arrows are counted from where the cursor is now")
    k.screen = screenshot("ask-multi")
    let extras = looked(k)
    k.screen = screenshot("ask-multi-checked")
    _ = k.phone.respond(to: post("/api/pick", ["key": "a", "row": 1, "label": "Keys", "box": extras]))
    t.expectEqual(k.pressed, ["1", "up", "enter", "2"], "and so is one with a tick made in it, which also marks its question as answered in the strip")
    t.expect(k.phone.respond(to: post("/api/pick", ["key": "a", "row": 0, "label": "Speech"])).status == 400 && k.pressed.count == 4,
             "a tap that doesn't say which box it was drawn in presses nothing")

    // -- a key goes only where Claude is showing something that takes it ---------
    let q = Bench()
    q.phone.took(turn("a", "Shall I?"))
    /// A key under a's screen, with whatever the page says it had drawn.
    func key(_ name: String, _ drawn: [String: Any] = [:]) -> [String: Any] {
        json(q.phone.respond(to: post("/api/key", ["key": "a", "press": name].merging(drawn) { $1 })))
    }
    func went(_ answer: [String: Any]) -> Bool { answer["sent"] as? Bool == true }
    // A box: the one the page has drawn, and no other.
    q.screen = toTouch
    let touching = ["box": looked(q)]
    t.expect(went(key("1", touching)) && q.pressed == ["1"], "a key goes to the box the page has drawn")
    q.screen = toRemove
    let tooLate = key("1", touching)
    t.expect(!went(tooLate) && (tooLate["outcome"] as? String)?.contains("changed") == true && tooLate["state"] != nil,
             "the same key again, with a different box now up, is not sent, and the page is given what's there")
    t.expect(!went(key("enter")) && !went(key("esc")) && !went(key("down")),
             "nor is a key from a page that had drawn no box: Enter would take whichever choice the cursor is on")
    t.expectEqual(q.pressed, ["1"], "none of those pressed anything")
    // The hook's words stand in until the screen is read: the numbers beside them are keys too.
    q.screen = screenshot("ask-single")
    let navy = ["asked": "Which colour for the bar?", "option": "Navy. Like the factory"]
    t.expect(went(key("2", navy)) && q.pressed == ["1", "2"], "a number tapped beside a question's words is pressed when the box up is that question and that its choice")
    t.expect(!went(key("1", navy)) && !went(key("2", ["asked": "Which route do you want?", "option": "Navy. Like the factory"])),
             "not when that number is another choice's, or the question another one")
    q.screen = toTouch
    t.expect(!went(key("1", ["asked": "Shall I go ahead?", "option": "Yes. Go ahead"])) && q.pressed == ["1", "2"],
             "and never in a permission box that came up since, though its first choice is Yes too")
    // Claude's prompt: Enter and Esc, and only from a page that knows the box has gone.
    q.screen = atPrompt
    t.expect(!went(key("enter", touching)) && !went(key("esc", touching)) && !went(key("enter", navy)) && q.pressed == ["1", "2"],
             "a key tapped for a box that has since gone is not pressed at the prompt: Enter there would send whatever is typed")
    t.expect(went(key("esc")) && went(key("enter")) && !went(key("down")) && !went(key("3")) && q.pressed == ["1", "2", "esc", "enter"],
             "with no box drawn, Esc and Enter are pressed at the prompt and nothing else is")
    // A turn running with no prompt in sight: Esc stops it. Nothing else means anything.
    q.screen = "⏺ Reading the files.\n\n✻ Working… (esc to interrupt)"
    t.expect(went(key("esc")) && !went(key("enter")) && !went(key("1")) && q.pressed.count == 5, "mid-turn with no prompt in sight, only Esc is pressed")
    // Something else of Claude's that says it takes keys: yours to press, by what its screen shows.
    q.screen = "Paste the code from your browser:\n\n > \n\n Enter to confirm · Esc to cancel"
    t.expect(went(key("enter")) && !went(key("enter", touching)) && q.pressed.count == 6,
             "a box that says it takes keys, though not as choices this can read, takes them")
    // Not Claude at all: nothing is pressed. Up and Enter in a shell run its last command again.
    for (shell, what) in [("chris@mac ~ % ", "a shell"), (shellPrompt, "a shell with ❯ for its prompt"),
                          ("how to answer: Enter to select · Esc to cancel\n" + toTouch + "\nchris@mac project % ", "a shell under what Claude left on the screen"),
                          ("", "a blank screen")] {
        q.screen = shell
        let answers = ["up", "enter", "esc", "1"].map { key($0) }
        t.expect(answers.allSatisfy { !went($0) } && q.pressed.count == 6, "\(what) is not Claude Code: no key is pressed there")
        t.expect((answers[0]["outcome"] as? String)?.contains("Claude") == true, "and the page is told so (\(what))")
    }
    // A question in a pane too narrow for its line of keys, which wraps onto two: no box
    // is read there, and that is not the question having gone. The hook's own words are
    // then what says whose list is at the foot of the screen.
    let narrow = String(repeating: "─", count: 62)
    let wrapped = [narrow, " ☐ Colour", "", "Which colour for the bar?", "", "❯ 1. Forest", "     Like Grow Guide", "  2. Navy", "     Like the factory",
                   "  3. Type something.", narrow, "  4. Chat about this", "", "Enter to select · ↑/↓ to navigate · ctrl+g to edit in Vim ·", "Esc to cancel"].joined(separator: "\n")
    q.screen = wrapped
    var had = q.pressed.count   // each check counts from what had been pressed before it
    t.expect(boxOn(wrapped) == nil && went(key("2", navy)) && q.pressed.count == had + 1 && q.pressed.last == "2",
             "a number beside a question's words is pressed where the box can't be read whole, when the list at the foot of its screen is that question with that choice at that number")
    had = q.pressed.count
    let otherChoice = key("1", navy), otherQuestion = key("2", ["asked": "Which route do you want?", "option": "Navy. Like the factory"])
    t.expect(!went(otherChoice) && !went(otherQuestion) && !went(key("enter", navy)) && q.pressed.count == had,
             "not when that number is another choice's or the question another one, and never any key but the number")
    t.expect((otherChoice["outcome"] as? String)?.contains("no list of choices on its screen reads as that question") == true
             && (otherQuestion["outcome"] as? String)?.contains("changed") == false,
             "and the page is told what is wrong, not that a box has changed")
    q.screen = screenshot("ask-single").replacingOccurrences(of: "Enter to select · ↑/↓ to navigate · Esc to cancel", with: "Return to choose · arrows to move")
    t.expect(boxOn(q.screen ?? "") == nil && went(key("2", navy)) && q.pressed.count == had + 1,
             "nor does it hang on the words of that line: the captured box with other words there takes the number the same way")
    had = q.pressed.count
    q.screen = screenshot("ask-single") + "\nchris@mac project % "
    let overShell = key("2", navy)
    t.expect(!went(overShell) && q.pressed.count == had && (overShell["outcome"] as? String)?.contains("isn't showing Claude Code") == true,
             "a question's box left on the screen over a shell's prompt takes no number: more is under its choices than one line, however wrapped")
    had = q.pressed.count
    q.screen = wrapped.replacingOccurrences(of: narrow, with: String(repeating: "─", count: 110))
    t.expect(!went(key("2", navy)) && q.pressed.count == had,
             "two lines under its choices in a pane wide enough for both on one are not one line that wrapped")
    had = q.pressed.count
    q.screen = wrapped.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
    t.expect(!went(key("2", navy)) && q.pressed.count == had,
             "nor are they where no rule over the question says how wide the pane is")
    had = q.pressed.count
    q.screen = "❯ Which colour for the bar?\n  1. Forest\n  2. Navy\n\n⏺ Asking you now.\n\n✻ Working… (esc to interrupt)"
    let midTurn = key("2", navy)
    t.expect(!went(midTurn) && q.pressed.count == had && (midTurn["outcome"] as? String)?.contains("no list of choices on its screen reads as that question") == true,
             "nor do the question's words further up a screen whose turn is running: they are not a list with what it asks over it")
    had = q.pressed.count
    q.screen = atPrompt
    let answered = key("2", navy)
    t.expect(!went(answered) && q.pressed.count == had && (answered["outcome"] as? String)?.contains("changed") == true && answered["state"] != nil,
             "back at Claude's prompt the question has gone: that is a box that has changed, and the page is given what's there")
    // A key that says it was tapped on a box, in words that can't be read as one, was not
    // tapped on no box: taken for that, Enter went into Claude's prompt.
    had = q.pressed.count
    let unreadable: [Any] = [[String: Any](), ["ask": "Do you want to proceed?", "rows": [["label": "Yes"], ["label": "No"]]], "a box", NSNull(),
                             ["ask": "Do you want to proceed?", "tabs": 3, "rows": ["Yes", "No"]]]
    let blind = unreadable.map { q.phone.respond(to: post("/api/key", ["key": "a", "press": "enter", "box": $0])) }
    t.expect(blind.allSatisfy { $0.status == 400 } && q.pressed.count == had,
             "a key whose box can't be read is refused outright, and nothing is pressed: at Claude's prompt Enter would have sent whatever is typed")
    had = q.pressed.count
    let halves: [[String: Any]] = [["asked": "Which colour for the bar?"], ["option": "Navy. Like the factory"], ["asked": 3, "option": "Navy. Like the factory"]]
    t.expect(halves.allSatisfy { q.phone.respond(to: post("/api/key", ["key": "a", "press": "enter"].merging($0) { $1 })).status == 400 } && q.pressed.count == had,
             "and so is one with half of a question's words, or words that aren't words")
    had = q.pressed.count
    t.expect(went(key("enter")) && q.pressed.count == had + 1, "a key that names no box at all is still a key under a screen with none drawn")
    let pageScript = String(decoding: fm.contents(atPath: "phone/app.js") ?? Data(), as: UTF8.self)
    t.expect(pageScript.contains("box: w.box") && pageScript.contains("body.box = w.box") && pageScript.contains("body.option = "),
             "the page's taps and keys say what they were drawn in")

    // -- its status line: the folder, the model, how full the context is -------
    let mine = "⏺ Done.\n\n────────────────\n❯ \n────────────────\n  speakhud (main*)  |  Opus 5.5  ctx:51% used         ✔ Update installed · Restart to update\n  ⏵⏵ auto mode on · ← 1 agent"
    t.expect(Reply.showing(mine).prompt?.status == "speakhud (main*) | Opus 5.5 ctx:51% used" && Reply.showing(mine).prompt?.context == 51,
             "the line under the prompt box, without the notice off to its right, and the context figure in it")
    t.expect(Reply.showing(screenshot("prompt")).prompt?.status?.hasPrefix("⏸ manual mode on") == true && Reply.showing(screenshot("prompt")).prompt?.context == nil,
             "whatever line a terminal has, with no figure when it gives none")
    t.expect(Reply.showing(screenshot("permission")).prompt == nil, "a box has no status line to read")
    o.open = [Reply.Pane(session: pane.session!, name: "✳ Grow guide replies — ~", screen: mine)]
    o.phone.scan(now: Date().addingTimeInterval(3 * Phone.scanEvery + 3))
    let lined = turns(o.phone.state()).first
    t.expect(lined?["status"] as? String == "speakhud (main*) | Opus 5.5 ctx:51% used" && lined?["context"] as? Int == 51, "the page is given both")
    o.open = [Reply.Pane(session: pane.session!, name: "✳ Grow guide replies — ~", screen: screenshot("permission"))]
    o.phone.scan(now: Date().addingTimeInterval(4 * Phone.scanEvery + 4))
    t.expect(turns(o.phone.state()).first?["status"] as? String == "speakhud (main*) | Opus 5.5 ctx:51% used", "and a box coming up doesn't wipe what was last read")
    o.phone.took(turn("real", "A turn of its own.", origin: Origin(term: "iTerm.app", session: pane.session!)))
    t.expect(o.phone.desk.turn("real")?.context == 51, "nor does its next turn arriving")
    o.open = [Reply.Pane(session: pane.session!, name: "✳ Grow guide replies — ~", screen: screenshot("ask-single"))]
    o.phone.scan(now: Date().addingTimeInterval(5 * Phone.scanEvery + 5))

    // -- a picture sent with an answer ----------------------------------------
    let p = Bench()
    p.phone.picturesDir = dir + "/from phone"
    p.phone.took(turn("a", "Which one is broken?"))
    func upload(_ bytes: [UInt8], header: Bool = true, paired: Bool = true) -> HTTP.Response {
        var headers = ["content-type": "image/jpeg"]
        if paired { headers["cookie"] = "\(Phone.cookie)=\(token)" }
        if header { headers["x-speakhud"] = "1" }
        return p.phone.respond(to: HTTP.Request(method: "POST", path: "/api/picture", headers: headers, body: Data(bytes)))
    }
    let jpegBytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 7, count: 2_000)
    let pngBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 9, count: 500)
    t.expect(upload(jpegBytes, paired: false).status == 401 && upload(jpegBytes, header: false).status == 404,
             "a picture is taken only from a paired phone's own page")
    t.expect(upload(Array("#!/bin/sh\nrm -rf ~".utf8)).status == 400 && ((try? fm.contentsOfDirectory(atPath: p.phone.picturesDir)) ?? []).isEmpty,
             "what isn't a picture isn't kept")
    let firstID = json(upload(jpegBytes))["id"] as? String ?? "", secondID = json(upload(pngBytes))["id"] as? String ?? ""
    let firstPath = p.phone.picturesDir + "/" + firstID, secondPath = p.phone.picturesDir + "/" + secondID
    t.expect(firstID.hasSuffix(".jpg") && secondID.hasSuffix(".png") && firstID != secondID && !firstID.contains(" ") && !firstID.contains("/"),
             "a picture is kept under a plain name of its kind")
    t.expect(fm.contents(atPath: firstPath) == Data(jpegBytes) && (try? fm.attributesOfItem(atPath: firstPath))?[.posixPermissions] as? Int == 0o600,
             "as it came, for you alone")
    // Claude Code takes a picture's path out of the prompt and puts a marker at the front
    // of it: the answer is sent only because the Mac knows which of its words those are.
    p.term.pictureFiles = [firstPath, secondPath]
    let withPics = json(p.phone.respond(to: post("/api/reply", ["key": "a", "text": "this one", "pictures": [firstID, secondID]])))
    t.expect(withPics["sent"] as? Bool == true && p.delivered.last?.text == "this one The pictures from my phone: \(firstPath) \(secondPath)",
             "an answer with pictures says where they are on the Mac, for the terminal's Claude to read")
    let named = json(p.phone.respond(to: post("/api/reply", ["key": "a", "text": "use /tmp/logo.png and https://x.com/logo.png"])))
    t.expect(named["sent"] as? Bool == true && p.delivered.last?.text == "use /tmp/logo.png and https://x.com/logo.png",
             "an answer that names a picture in its own words is sent too: those are words, and stay in the prompt as said")
    t.expect(turns(withPics["state"] as? [String: Any] ?? [:]).first?["sent"] as? String == "this one [2 pictures]"
             && p.logs.contains("phone reply to Grow guide replies (8 chars, 2 pictures): sent") && !p.logs.contains { $0.contains("from phone") },
             "the page and the log say there were pictures, not where they are")
    _ = p.phone.respond(to: post("/api/reply", ["key": "a", "text": "  ", "pictures": [firstID]]))
    t.expectEqual(p.delivered.last?.text ?? "", "Look at this picture from my phone: \(firstPath)", "a picture with no words still says what it is")
    let before = p.delivered.count
    t.expect(p.phone.respond(to: post("/api/reply", ["key": "a", "text": "and this", "pictures": ["../../etc/passwd"]])).status == 400
             && p.phone.respond(to: post("/api/reply", ["key": "a", "text": "", "pictures": []])).status == 400 && p.delivered.count == before,
             "a picture the Mac wasn't sent is refused, by the name it gave and nothing else; and nothing at all is still nothing")
    t.expect(HTTP.parse(Data("POST /api/picture HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n".utf8)) == .incomplete
             && HTTP.parse(Data("POST /api/reply HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n".utf8)) == .bad
             && HTTP.parse(Data("POST /api/picture HTTP/1.1\r\nContent-Length: \(HTTP.maxUpload + 1)\r\n\r\n".utf8)) == .bad,
             "a picture may be bigger than an answer, up to the upload limit and no further")
    try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-Phone.pictureAge - 3_600)], ofItemAtPath: firstPath)
    p.phone.sweepPictures()
    t.expect(!fm.fileExists(atPath: firstPath) && fm.fileExists(atPath: secondPath), "pictures older than a week are cleared out; newer ones stay")
    t.expectEqual(p.phone.respond(to: post("/api/reply", ["key": "a", "text": "again", "pictures": [firstID]])).status, 400, "and one that's gone can't be sent again")

    // -- what a reading did on the phone ---------------------------------------
    _ = o.phone.respond(to: post("/api/heard", ["parts": 5, "words": 140, "sized": 0, "backwards": 12, "gap": 900, "scrolls": 4, "seconds": 41,
                                              "speed": 1.25, "voices": 60, "marks": true, "lang": "en-US", "text": "what was read", "extra": "x\ny",
                                              "why": "arrival", "end": "Stopped by\nsomething long", "page": "a1b2", "voice": "Daniel (Enhanced)"]))
    t.expect(o.logs.contains("phone reading: parts 5, words 140, sized 0, backwards 12, gap 900, scrolls 4, seconds 41, speed 1.25, voices 60, marks yes, lang en-US, voice Daniel (Enhanced), why arrival, page a1b2"),
             "a reading's numbers go in the log, and nothing else the page sends with them does")
    _ = o.phone.respond(to: post("/api/heard", ["lang": "en\nforged line", "words": "many"]))
    t.expect(o.logs.last == "phone reading: ", "a report that isn't numbers adds no words of its own to the log")

    // -- quick answers ---------------------------------------------------------
    t.expectEqual(o.phone.state()["quick"] as? [String] ?? [], Phone.quickDefault, "quick answers start as a few everyone sends")
    let kept2 = json(o.phone.respond(to: post("/api/quick", ["list": ["Wrap up", " commit it\nand push ", "Wrap up", "/exit", "  "]])))
    t.expectEqual(kept2["quick"] as? [String] ?? [], ["Wrap up", "commit it and push", "exit"],
                  "yours replace them: one line each, no repeats, nothing empty, and nothing Claude's prompt would take as a command")
    _ = o.phone.respond(to: post("/api/quick", ["list": (1...20).map { "answer \($0)" }]))
    t.expectEqual(o.phone.quick.count, Phone.quickLimit, "and no more than \(Phone.quickLimit)")
    t.expectEqual(o.phone.respond(to: post("/api/quick", ["list": "Yes"])).status, 400, "a list that isn't one is refused")
    t.expect(Phone(config: PhoneConfig(token: token), defaults: o.defaults).quick.count == Phone.quickLimit, "they outlive a restart")

    // -- closing a terminal ----------------------------------------------------
    var script: [String] = []
    let promptPane: (String) -> Reply.Answer = { source in
        script.append(source.contains("contents of s") ? "look" : source.contains("\"/exit\"") ? "type /exit" : source.contains("character id 13") ? "enter"
                      : source.contains("tell s to close") ? "close" : "?")
        return Reply.Answer(reply: source.contains("contents of s") ? "ok\n" + atPrompt : "ok")
    }
    t.expect(Reply.close(pane, via: Reply.Terminal(ask: promptPane, wait: { _ in })) == .sent && script == ["look", "type /exit", "enter", "close"],
             "closing a terminal at Claude's prompt asks Claude to exit first, then closes the pane")
    script = []
    let boxPane: (String) -> Reply.Answer = { source in
        script.append(source.contains("contents of s") ? "look" : source.contains("tell s to close") ? "close" : "other")
        return Reply.Answer(reply: source.contains("contents of s") ? "ok\n" + screenshot("permission") : "ok")
    }
    t.expect(Reply.close(pane, via: Reply.Terminal(ask: boxPane, wait: { _ in })) == .sent && script == ["look", "close"], "one that isn't at its prompt is just closed: nothing is typed into a box")
    t.expect(Reply.close(Origin(term: "Apple_Terminal", tty: "/dev/ttys004"), via: saying(Reply.Answer(reply: "ok"))) == .gone, "a pane that isn't iTerm2's can't be")
    t.expect(Reply.close(pane, via: saying(Reply.Answer(reply: "missing"))) == .sent && Reply.close(pane, via: saying(Reply.Answer(errorCode: -1743))) == .denied,
             "one that had already gone is closed all the same; a refused permission is said")
    let closing = json(o.phone.respond(to: post("/api/close", ["key": "real"])))
    t.expect(closing["sent"] as? Bool == true && o.shutPanes == [pane.session] && o.phone.desk.turn("real") == nil
             && o.logs.contains("phone closed Grow guide replies: sent"), "closed from the page, its window goes")
    t.expectEqual(o.phone.respond(to: post("/api/close", ["key": "real"])).status, 404, "and can't be closed twice")

    // -- old sessions, and resuming one ---------------------------------------
    let projects = dir + "/projects"
    func transcript(_ folder: String, _ id: String, _ lines: [String], age: TimeInterval = 60) {
        try? fm.createDirectory(atPath: projects + "/" + folder, withIntermediateDirectories: true)
        let path = projects + "/" + folder + "/" + id + ".jsonl"
        fm.createFile(atPath: path, contents: Data((lines.joined(separator: "\n") + "\n").utf8))
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
    }
    let idA = "11111111-2222-4333-8444-555555555555", idB = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", idC = "99999999-8888-4777-8666-555555555555"
    transcript("-Users-you", idA, [
        #"{"type":"user","cwd":"/Users/you","message":{"content":"hello"}}"#,
        #"{"type":"ai-title","aiTitle":"First  name","sessionId":"x"}"#,
        #"{"type":"assistant","cwd":"/Users/you/GitHub/thing","message":{}}"#,
        #"{"type":"ai-title","aiTitle":"Grow guide replies","sessionId":"x"}"#,
    ], age: 120)
    transcript("-Users-you-GitHub-thing", idB, [
        #"{"type":"user","cwd":"/Users/you/GitHub/thing","message":{}}"#,
        #"{"type":"custom-title","customTitle":"My own name","sessionId":"y"}"#,
        #"{"type":"ai-title","aiTitle":"Claude's name for it","sessionId":"y"}"#,
    ], age: 30)
    transcript("-Users-you", idC, [#"{"type":"user","cwd":"/Users/you","message":{}}"#], age: OldSessions.maxAge + 3600)
    transcript("-Users-you", "not-a-session-id", [#"{"type":"user","cwd":"/Users/you","message":{}}"#])
    transcript("-Users-you", "22222222-3333-4444-8555-666666666666", [#"{"type":"summary","text":"says nothing of where it ran"}"#])
    let found = OldSessions.recent(in: projects)
    t.expectEqual(found.map { $0.id }, [idB, idA], "sessions are listed newest first; an old one, a file that isn't a session's, and one that never says where it ran are not")
    t.expect(found[0].title == "My own name" && found[1].title == "Grow guide replies", "by the name you gave it, else the last one Claude did")
    t.expectEqual(found[1].cwd, "/Users/you", "from the folder it was started in, which is where it resumes from, not the one Claude moved to")
    let resumeScript = OldSessions.script(OldSessions.Session(id: idA, title: "x", cwd: "/Users/you/it's here", at: Date())) ?? ""
    t.expect(resumeScript.contains(#"cd '/Users/you/it'\\''s here' && claude --resume \#(idA)"#) && resumeScript.contains("create window with default profile"),
             "resuming opens a new iTerm2 window, goes to that folder however it's spelled, and resumes that id")
    t.expect(OldSessions.script(OldSessions.Session(id: "x; rm -rf ~", title: "x", cwd: "/tmp", at: Date())) == nil
             && OldSessions.script(OldSessions.Session(id: idA, title: "x", cwd: "/tmp\nrm -rf ~", at: Date())) == nil,
             "an id that isn't one, or a folder with a line break in it, is never put in a command")
    var ran: [String] = []
    t.expect(OldSessions.resume(OldSessions.Session(id: idA, title: "x", cwd: dir, at: Date()), run: { ran.append($0); return Reply.Answer(reply: "ok") }) == .sent && ran.count == 1,
             "a session whose folder is there is opened")
    t.expect(OldSessions.resume(OldSessions.Session(id: idA, title: "x", cwd: dir + "/gone", at: Date()), run: { ran.append($0); return Reply.Answer(reply: "ok") }) != .sent && ran.count == 1,
             "one whose folder has gone is not, and says so")
    let sessionsDir = dir + "/sessions"
    try? fm.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
    fm.createFile(atPath: sessionsDir + "/1.json", contents: Data(#"{"pid": \#(getpid()), "sessionId": "\#(idA)"}"#.utf8))
    fm.createFile(atPath: sessionsDir + "/2.json", contents: Data(#"{"pid": 99999999, "sessionId": "\#(idB)"}"#.utf8))
    t.expectEqual(OldSessions.running(in: sessionsDir), [idA], "a session Claude Code says is running counts while its process is alive")

    o.old = found
    o.running = [idB]
    let offered = json(o.phone.respond(to: get("/api/sessions")))["sessions"] as? [[String: Any]] ?? []
    t.expect(offered.count == 2 && offered[0]["title"] as? String == "My own name" && offered[0]["open"] as? Bool == true
             && offered[1]["folder"] as? String == "you" && offered[1]["open"] as? Bool == false, "the page is offered them, with which are already open")
    t.expectEqual(o.phone.respond(to: post("/api/resume", ["id": idB])).status, 409, "one that's already open isn't opened twice")
    let resumed = json(o.phone.respond(to: post("/api/resume", ["id": idA])))
    t.expect(resumed["sent"] as? Bool == true && o.reopened == ["\(idA) in /Users/you"] && o.logs.contains("phone resumed Grow guide replies: sent"),
             "one that isn't is, from the folder this Mac's own record gives")
    t.expect(o.phone.respond(to: post("/api/resume", ["id": "../../etc"])).status == 404 && o.reopened.count == 1,
             "the page names a session by its id and nothing else: an id that isn't listed opens nothing")

    // -- a box coming up while you're away is pushed ---------------------------
    o.phone.setAway(true)
    o.open = [Reply.Pane(session: pane.session!, name: "✳ Grow guide replies — ~", screen: screenshot("permission"))]
    o.phone.tick(now: Date().addingTimeInterval(100))
    o.phone.tick(now: Date().addingTimeInterval(110))
    t.expect(o.pushes.count == 1 && String(decoding: o.pushes[0].httpBody ?? Data(), as: UTF8.self).contains("Grow guide replies is asking"),
             "away, a permission box no hook knows about is pushed, once")
    o.phone.took(turn("\(boxKey):question", "Do you want to proceed?"), now: Date().addingTimeInterval(112))
    t.expectEqual(o.pushes.count, 1, "and the question hook saying the same thing doesn't push it twice")
    o.phone.setAway(false)
    o.open = []
    o.phone.scan(now: Date().addingTimeInterval(200))
    t.expect(o.phone.desk.turns.isEmpty, "every pane closed empties the list")
    let restarted = Phone(config: PhoneConfig(token: token), defaults: o.defaults, saved: openDesk.snapshot())
    t.expectEqual(restarted.desk.turns.map { $0.key }, ["b"], "a restarted agent starts from what the last one kept")

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
    b.screen = screenshot("permission")   // a box is up, which takes no paste
    let refused = json(b.phone.respond(to: post("/api/reply", ["key": "a", "text": "again"])))
    t.expect(refused["sent"] as? Bool == false && refused["outcome"] as? String == Reply.Outcome.notAtPrompt.description,
             "one that didn't go says why")
    b.screen = FakeITerm.promptScreen
    t.expectEqual(b.phone.respond(to: post("/api/reply", ["key": "gone", "text": "hi"])).status, 404, "a terminal off the list: not found")
    t.expectEqual(b.phone.respond(to: post("/api/reply", ["key": "b", "text": "hi"])).status, 409, "a pane that can't be reached: said")
    t.expectEqual(b.phone.respond(to: post("/api/reply", ["key": "a", "text": "  \n "])).status, 400, "nothing to send: refused")
    t.expectEqual(b.delivered.count, 1, "and none of those, nor the one a box turned away, typed anything")

    // -- a question box -----------------------------------------------------
    b.phone.took(turn("a:question", "Which route?"))
    b.phone.took(turn("a:question", "- 1. Try Claude's first.\n- 2. Build our own."))
    b.screen = "Which route?\n❯ 1. Try Claude's first\n  2. Build our own\nEnter to select · Esc to cancel"
    let asking = json(b.phone.respond(to: get("/api/screen", query: ["key": "a"])))
    t.expect((asking["screen"] as? String)?.contains("Build our own") == true
             && turns(asking["state"] as? [String: Any] ?? [:]).first?["question"] as? String == "Which route?\n\n- 1. Try Claude's first.\n- 2. Build our own.",
             "its screen can be read, and the question stays up while the box does")
    t.expectEqual(b.phone.respond(to: post("/api/key", ["key": "a", "press": "rm -rf"])).status, 400, "only the named keys can be pressed")
    let keyed = json(b.phone.respond(to: post("/api/key", ["key": "a", "press": "2", "box": drew(asking["state"] as? [String: Any] ?? [:], "a")])))
    t.expect(keyed["sent"] as? Bool == true && b.pressed == ["2"] && b.logs.contains("phone key 2 to Grow guide replies: sent"), "a key goes to its pane")
    b.screen = "working…\n────────────────\n❯ \n────────────────\n  status"
    let stray = json(b.phone.respond(to: post("/api/key", ["key": "a", "press": "1"])))
    t.expect(stray["sent"] as? Bool == false && b.pressed == ["2"] && (stray["outcome"] as? String)?.contains("Claude's prompt") == true,
             "at Claude's prompt a number isn't pressed: it would type into the message, and the next answer would be pasted after it")
    _ = b.phone.respond(to: post("/api/key", ["key": "a", "press": "enter"]))
    t.expectEqual(b.pressed, ["2", "enter"], "Enter still is: it sends what's typed there")
    b.term.takesPaste = false   // the paste never shows in the prompt box, so Return isn't pressed
    let half = json(b.phone.respond(to: post("/api/reply", ["key": "a", "text": "and one more thing"])))
    t.expect(half["sent"] as? Bool == false && half["pasted"] as? Bool == true, "words pasted but not sent are said to be in the prompt, so the page doesn't offer to send them twice")
    b.term.takesPaste = true
    let after = json(b.phone.respond(to: get("/api/screen", query: ["key": "a"])))
    t.expect(turns(after["state"] as? [String: Any] ?? [:]).first?["question"] is NSNull, "back at Claude's prompt, the question is over")
    b.screen = nil
    t.expectEqual(b.phone.respond(to: get("/api/screen", query: ["key": "a"])).status, 409, "a screen that can't be read: said")

    // -- the keys and the screen, as iTerm2 is asked ------------------------
    t.expect(Reply.keyScript(pane.session!, Reply.keys["down"]!).contains("(character id 27) & (character id 91) & (character id 66)"),
             "Down is the bytes the key sends")
    var asked: [String] = []
    let atItsPrompt = Reply.Terminal(ask: { source in
        asked.append(source)
        return Reply.Answer(reply: source.contains("contents of s") ? "ok\n" + atPrompt : "ok")
    }, wait: { _ in })
    t.expect(Reply.press("enter", on: .noBox, in: pane, via: atItsPrompt) == .sent
             && asked.count == 2 && asked[0].contains("contents of s") && asked[1].contains("(character id 13)") && asked[1].contains("newline no"),
             "a key is written to the pane only after a look at it, and with no Return of its own")
    asked = []
    t.expect(Reply.press("f13", on: .noBox, in: pane, via: atItsPrompt) == .failed("no such key") && Reply.press("3", on: .noBox, in: pane, via: atItsPrompt) != .sent
             && asked.allSatisfy { $0.contains("contents of s") }, "an unknown key is never written, nor one the pane wouldn't take as an answer")
    t.expect(Reply.press("enter", on: .noBox, in: pane, via: saying(Reply.Answer(reply: "missing"))) == .gone
             && Reply.press("enter", on: .noBox, in: pane, via: saying(Reply.Answer(errorCode: -1743))) == .denied, "a closed pane and a refused permission say so")
    let writeFails = Reply.Terminal(ask: { source in
        source.contains("contents of s") ? Reply.Answer(reply: "ok\n" + atPrompt) : Reply.Answer(errorCode: -1728, errorMessage: "Can't get session.")
    }, wait: { _ in })
    t.expect(Reply.press("enter", on: .noBox, in: pane, via: writeFails) == .failed("Can't get session.")
             && Reply.pick(0, of: TerminalBox.Drawn(ask: "", rows: []), in: pane, via: saying(Reply.Answer(errorCode: -1743))) == .denied
             && Reply.press("enter", on: .noBox, in: Origin(term: "Apple_Terminal", tty: "/dev/ttys004"), via: atItsPrompt) == .gone,
             "an error from iTerm2 comes back in its own words, whichever script met it; a pane that isn't iTerm2's can't be pressed in")
    t.expectEqual(Reply.screen(of: pane, lines: 2, via: saying(Reply.Answer(reply: "ok\none\ntwo\nthree\n\n   \n"))) ?? "", "two\nthree",
                  "the screen is its last lines, without the blank foot")
    t.expect(Reply.screen(of: pane, via: saying(Reply.Answer(reply: "missing"))) == nil, "and nil once the pane is gone")

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

    // -- what a turn made, shown under it ------------------------------------
    let shots = dir + "/shots"
    try? fm.createDirectory(atPath: shots, withIntermediateDirectories: true)
    /// A real PNG, `side` pixels square, of noise (so it stays heavy), see-through all over if `clear`.
    func picture(_ path: String, side: Int, clear: Bool = false) {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt32 = 12345
        for i in pixels.indices {
            seed = seed &* 1664525 &+ 1013904223
            pixels[i] = clear && i % 4 == 3 ? 128 : UInt8(seed >> 24) / (clear ? 2 : 1)
        }
        let info: CGImageAlphaInfo = clear ? .premultipliedLast : .noneSkipLast
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue),
              let image = context.makeImage(),
              let to = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(to, image, nil)
        CGImageDestinationFinalize(to)
    }
    picture(shots + "/big.png", side: 600)
    picture(shots + "/cutout.png", side: 600, clear: true)
    fm.createFile(atPath: shots + "/small.jpg", contents: Data(repeating: 7, count: 2_000))
    let clip = Data((0..<700_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
    fm.createFile(atPath: shots + "/clip one.mp4", contents: clip)
    fm.createFile(atPath: shots + "/secret.txt", contents: Data("keys".utf8))
    try? fm.createSymbolicLink(atPath: shots + "/sneaky.png", withDestinationPath: shots + "/secret.txt")
    try? fm.createSymbolicLink(atPath: shots + "/alias.mp4", withDestinationPath: shots + "/clip one.mp4")

    t.expectEqual(PhoneMedia.parse([shots + "/big.png", "relative.png", shots + "/secret.txt", 7, shots + "/big.png", shots + "/clip one.mp4"]),
                  [shots + "/big.png", shots + "/clip one.mp4"],
                  "a turn's media: absolute paths of a kind the page shows, each once")
    t.expectEqual(PhoneMedia.parse((0..<20).map { "/x/\($0).png" }).count, PhoneMedia.limit, "and no more than the page takes")
    t.expect(PhoneMedia.parse("nonsense").isEmpty && PhoneMedia.parse(nil).isEmpty, "anything that isn't a list is none")
    t.expect(PhoneMedia.file(shots + "/sneaky.png") == nil, "a picture's name on a link to something else: not followed")
    t.expect(PhoneMedia.file(shots + "/alias.mp4")?.kind == "video" && PhoneMedia.file(shots + "/alias.mp4")?.name == "clip one.mp4",
             "a link to a video is the video")
    t.expect(PhoneMedia.file(shots + "/gone.png") == nil && PhoneMedia.file(shots) == nil, "gone, or a folder: nothing to show")
    t.expect(PhoneMedia.said(["/a.png", "/b.jpg"]) == "2 pictures" && PhoneMedia.said(["/a.mov"]) == "1 video"
             && PhoneMedia.said(["/a.png", "/b.mp4", "/c.pdf"]) == "3 files" && PhoneMedia.said([]) == nil,
             "what came with a turn, in words")

    // The hook finds them, so its list of kinds and its limit are this one's.
    let hookSource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("hook/read-summary.py").path
    let ask = Process(), told = Pipe()
    ask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    ask.arguments = ["python3", "-c", """
        import importlib.util, json, sys
        spec = importlib.util.spec_from_file_location("read_summary", sys.argv[1])
        hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hook)
        print(json.dumps({"kinds": sorted(hook.MEDIA_EXT), "limit": hook.MAX_MEDIA}))
        """, hookSource]
    ask.standardOutput = told
    ask.standardError = FileHandle.nullDevice
    try? ask.run()
    let hooks = (try? JSONSerialization.jsonObject(with: told.fileHandleForReading.readDataToEndOfFile()) as? [String: Any]) ?? [:]
    ask.waitUntilExit()
    t.expectEqual(hooks["kinds"] as? [String] ?? [], PhoneMedia.types.keys.sorted(), "the hook looks for exactly the kinds the page shows")
    t.expectEqual(hooks["limit"] as? Int ?? 0, PhoneMedia.limit, "and sends no more than the page takes")

    t.expect(HTTP.range(nil, of: 10) == .whole && HTTP.range("bytes=0-", of: 10) == .part(0...9)
             && HTTP.range("bytes=2-5", of: 10) == .part(2...5) && HTTP.range(" Bytes=2-99", of: 10) == .part(2...9),
             "a range: none asked is the whole file, an open end runs to the last byte, an end past it is cut to it")
    t.expect(HTTP.range("bytes=-3", of: 10) == .part(7...9) && HTTP.range("bytes=-99", of: 10) == .part(0...9),
             "the last so many bytes")
    t.expect(HTTP.range("bytes=10-", of: 10) == .none && HTTP.range("bytes=-0", of: 10) == .none && HTTP.range("bytes=0-", of: 0) == .none,
             "a start past the end, or none of an empty file: nothing to send")
    t.expect(HTTP.range("bytes=0-1,4-5", of: 10) == .whole && HTTP.range("lines=1-2", of: 10) == .whole
             && HTTP.range("bytes=5-2", of: 10) == .whole && HTTP.range("bytes=a-b", of: 10) == .whole,
             "a range this doesn't read gets the whole file, as a server may")

    let m = Bench()
    var three = turn("m", "Three made.")
    three.media = [shots + "/big.png", shots + "/sneaky.png", shots + "/clip one.mp4", shots + "/small.jpg"]
    m.phone.took(three)
    let listed = turns(m.phone.state()).first?["media"] as? [[String: Any]] ?? []
    t.expectEqual(listed.map { $0["i"] as? Int ?? -1 }, [0, 2, 3], "each is listed by its place in the turn's list; what isn't a file of its kind is left out")
    t.expectEqual(listed.map { $0["kind"] as? String ?? "" }, ["image", "video", "image"], "with what the page should do with it")
    t.expect(listed.first?["name"] as? String == "big.png" && ((listed.first?["size"] as? NSNumber)?.intValue ?? 0) > 300_000
             && (listed.first?["v"] as? String)?.isEmpty == false && !String(describing: listed).contains(shots),
             "by name, size and a mark that changes with the file: never by where it is on the Mac")

    func file(_ i: String, key: String = "m", range: String? = nil, w: String? = nil, save: Bool = false, paired: Bool = true) -> HTTP.Response {
        var query = ["key": key, "i": i]
        if let w = w { query["w"] = w }
        if save { query["save"] = "1" }
        var r = get("/api/file", query: query, paired: paired)
        if let range = range { r.headers["range"] = range }
        return m.phone.respond(to: r)
    }
    t.expectEqual(file("2", paired: false).status, 401, "an unpaired phone gets no file")
    let whole = file("2")
    t.expect(whole.status == 200 && whole.type == "video/mp4" && whole.file?.offset == 0 && whole.file?.length == 700_000 && whole.body.isEmpty,
             "a video is handed over as a file to send in pieces, never read whole")
    let part = file("2", range: "bytes=100-199")
    t.expect(part.status == 206 && part.file?.offset == 100 && part.file?.length == 100
             && part.headers.contains { $0 == ("Content-Range", "bytes 100-199/700000") }, "the part a phone asks for, and where it sits in the whole")
    let partHead = String(decoding: part.head(), as: UTF8.self)
    t.expect(partHead.hasPrefix("HTTP/1.1 206 Partial Content\r\n") && partHead.contains("Content-Length: 100\r\n")
             && partHead.contains("Accept-Ranges: bytes\r\n") && partHead.contains("filename*=UTF-8''clip%20one.mp4\r\n"),
             "said as a part, by its own length and name")
    t.expect(partHead.contains("Cache-Control: private, max-age=3600\r\n") && !partHead.contains("no-store")
             && partHead.contains("media-src 'self'") && partHead.contains("X-Content-Type-Options: nosniff"),
             "the phone may keep a file a while, and the page may play what comes from the Mac")
    let past = file("2", range: "bytes=700000-")
    t.expect(past.status == 416 && past.file == nil && past.headers.contains { $0 == ("Content-Range", "bytes */700000") },
             "a part past the end: refused, with the real length")
    t.expectEqual(file("1").status, 404, "the link to something else is never sent")
    t.expect(file("9").status == 404 && file("x").status == 404 && file("-1").status == 404 && file("0", key: "nope").status == 404,
             "a place the turn's list doesn't have, or a turn that isn't there: nothing")
    t.expect(m.logs.contains { $0.contains("phone shown clip one.mp4 (video, 683 KB) from Grow guide replies") }
             && !m.logs.contains { $0.contains(shots) }, "what the phone was shown is logged by name, not by path")

    let lighter = file("0", w: "400")
    let lightRep = NSBitmapImageRep(data: lighter.body)
    t.expect(lighter.status == 200 && lighter.file == nil && lighter.type == "image/jpeg" && lighter.body.count < 300_000
             && max(lightRep?.pixelsWide ?? 0, lightRep?.pixelsHigh ?? 0) == 400, "a heavy picture goes as a lighter copy, as wide as asked")
    t.expect((file("0").file?.length ?? 0) > 300_000, "and whole when no width is asked: that's the tap to open it")
    t.expect(file("3", w: "400").file?.length == 2_000, "a light picture goes as it is")
    let toKeep = file("0", w: "400", save: true)
    t.expect((toKeep.file?.length ?? 0) > 300_000 && toKeep.body.isEmpty && toKeep.type == "image/png"
             && toKeep.headers.contains { $0.0 == "Content-Disposition" && $0.1 == "attachment; filename*=UTF-8''big.png" },
             "asked for to keep, a picture goes as the file itself, whatever width was asked, marked for the phone to download under its name")
    t.expect(file("0").headers.contains { $0.0 == "Content-Disposition" && $0.1.hasPrefix("inline;") }
             && file("2", save: true).headers.contains { $0.0 == "Content-Disposition" && $0.1.hasPrefix("attachment;") }
             && file("2", range: "bytes=100-199", save: true).status == 206,
             "shown, a file is marked to show; a video to keep is still sent in the parts asked for")
    t.expect(m.logs.contains { $0.contains("phone saved big.png (image,") } && file("1", save: true).status == 404 && file("0", save: true, paired: false).status == 401,
             "what was saved is logged by name; keeping reaches nothing that showing doesn't")
    t.expect((NSBitmapImageRep(data: file("0", w: "99999").body)?.pixelsWide ?? 9999) <= 2400, "a silly width is cut down")

    try? fm.removeItem(atPath: shots + "/small.jpg")
    t.expect((turns(m.phone.state()).first?["media"] as? [[String: Any]])?.count == 2 && file("3").status == 404,
             "a file deleted since is off the list, and asking for it gets nothing")

    var asks = turn("m:question", "Which of these?")
    asks.media = [shots + "/cutout.png"]
    m.phone.took(asks)
    t.expect(m.phone.desk.turn("m")?.media == [shots + "/cutout.png"] && m.phone.desk.turn("m")?.text == "Three made.",
             "a question brings what its turn has made so far")
    m.phone.took(turn("m:question", "- 1. One.\n- 2. Two."))
    t.expectEqual(m.phone.desk.turn("m")?.media.count ?? 0, 1, "and its options, which come by themselves, don't take it away")
    let cut = file("0", w: "400")
    t.expect(cut.type == "image/png" && cut.file == nil && !cut.body.isEmpty, "a picture with see-through parts stays see-through when made lighter")
    t.expectEqual(PhoneDesk(snapshot: m.phone.desk.snapshot()).turn("m")?.media ?? [], [shots + "/cutout.png"],
                  "the list is kept across a restart of the agent")
    m.phone.took(turn("m", "Nothing made this time."))
    t.expect(m.phone.desk.turn("m")?.media.isEmpty == true && file("0").status == 404, "the next turn's window shows only what that turn made")
    m.phone.setAway(true)
    var ready = turn("m", "The clip is ready.")
    ready.media = [shots + "/clip one.mp4"]
    m.phone.took(ready)
    let pushed = (try? JSONSerialization.jsonObject(with: m.pushes.last?.httpBody ?? Data()) as? [String: Any]) ?? [:]
    t.expectEqual(pushed["title"] as? String ?? "", "Grow guide replies (1 video)", "away, the push says something came with the turn")
    m.phone.setAway(false)

    // -- dictation: a recording from the page comes back as words -------------
    /// A WAV as the page makes one: 44 bytes of header, then `seconds` of 16-bit sound.
    func recording(_ seconds: Double) -> Data {
        let sound = Data(count: Int(seconds * 16_000) * 2)
        var head = Data("RIFF".utf8)
        func put(_ n: Int, _ bytes: Int) { for i in 0..<bytes { head.append(UInt8((n >> (8 * i)) & 0xff)) } }
        put(36 + sound.count, 4)
        head.append(Data("WAVEfmt ".utf8))
        put(16, 4); put(1, 2); put(1, 2); put(16_000, 4); put(32_000, 4); put(2, 2); put(16, 2)
        head.append(Data("data".utf8))
        put(sound.count, 4)
        return head + sound
    }
    func said(_ body: Data, type: String? = "audio/wav", header: Bool = true, paired: Bool = true, to phone: Phone) -> HTTP.Response? {
        var headers: [String: String] = paired ? ["cookie": "\(Phone.cookie)=\(token)"] : [:]
        if let type = type { headers["content-type"] = type }
        if header { headers["x-speakhud"] = "1" }
        var answer: HTTP.Response?
        let taken = phone.respondLater(to: HTTP.Request(method: "POST", path: "/api/hear", headers: headers, body: body)) { answer = $0 }
        return taken ? answer : HTTP.Response(status: -1)
    }
    let twoSeconds = recording(2)
    t.expect(Dictation.looksRight(twoSeconds) && Dictation.seconds(twoSeconds) == 2 && !Dictation.looksRight(Data(count: 9_000))
             && !Dictation.looksRight(recording(0.05)), "a recording is told by its own first bytes, and by being long enough to hold a word")
    // Only exactly what the page writes: a header that doesn't match what follows it once
    // kept the real transcriber busy for ever (10-08), and every later recording was turned away.
    var longer = twoSeconds; longer.append(Data(count: 64_000))
    var stereo = twoSeconds; stereo[22] = 2
    var extra = twoSeconds; extra.replaceSubrange(36..<40, with: Data("LIST".utf8))
    t.expect(!Dictation.looksRight(longer) && !Dictation.looksRight(stereo) && !Dictation.looksRight(extra) && !Dictation.looksRight(twoSeconds.dropLast(2)),
             "a header that says one length over sound of another, two channels, or a chunk the page never writes: not a recording")
    let h = Bench()
    h.phone.took(turn("a", "Want me to merge it?"))
    t.expect(h.phone.state()["canHear"] as? Bool == true, "the page is told this Mac can turn a recording into words")
    var never: HTTP.Response?
    t.expect(!h.phone.respondLater(to: get("/api/state")) { never = $0 } && never == nil
             && !h.phone.respondLater(to: post("/api/reply", ["key": "a", "text": "x"])) { never = $0 } && never == nil,
             "every other request is answered at once, the usual way")
    t.expect(said(twoSeconds, paired: false, to: h.phone)?.status == 401 && said(twoSeconds, header: false, to: h.phone)?.status == 404
             && h.heardSizes.isEmpty, "an unpaired phone, or another site's page, is never heard")
    t.expect(said(twoSeconds, type: "application/json", to: h.phone)?.status == 400 && said(Data(count: 9_000), to: h.phone)?.status == 400
             && said(recording(0.05), to: h.phone)?.status == 400 && h.heardSizes.isEmpty, "what isn't a recording isn't given to the transcriber")
    let words = said(twoSeconds, to: h.phone)
    t.expect(words?.status == 200 && json(words ?? HTTP.Response())["text"] as? String == "Yes, go ahead." && h.heardSizes == [twoSeconds.count],
             "a recording comes back as its words")
    t.expect(h.logs.contains { $0.hasPrefix("phone dictated 3 words (2.0 s of sound, heard in ") } && !h.logs.contains { $0.contains("go ahead") },
             "the log says how much was said, never what")
    h.hearAnswer = nil
    let waiting = said(twoSeconds, to: h.phone)
    t.expect(waiting == nil && h.hearDone != nil, "while the Mac is hearing it, the page's request waits")
    t.expectEqual(said(twoSeconds, to: h.phone)?.status ?? 0, 409, "and a second recording meanwhile is turned away")
    var late: HTTP.Response?
    _ = h.phone.respondLater(to: HTTP.Request(method: "GET", path: "/nothing")) { late = $0 }
    h.hearDone?(.failure(Dictation.Failure("the speech model couldn't be readied")))
    h.hearAnswer = .success("")
    let nothing = said(twoSeconds, to: h.phone)
    t.expect(late == nil && nothing?.status == 200 && json(nothing ?? HTTP.Response())["text"] as? String == "",
             "once it has answered, the next is heard; a recording with no words in it comes back empty, not as an error")
    t.expect(h.logs.contains("phone dictation failed after 0.0 s: the speech model couldn't be readied")
             || h.logs.contains { $0.hasPrefix("phone dictation failed after ") && $0.hasSuffix(": the speech model couldn't be readied") },
             "a failure is logged with its reason")
    let deaf = Bench()
    deaf.phone.hear = nil
    t.expect(deaf.phone.state()["canHear"] as? Bool == false && said(twoSeconds, to: deaf.phone)?.status == 501,
             "a Mac with no transcriber says so, and its page shows no mic")
    // Word for word: the same route, a piece of sound at a time, each answered with the words so far.
    func piece(_ bytes: Int, id: String = "ab12cd34ef", rate: String? = "16000", last: Bool = false, type: String = "audio/pcm",
               header: Bool = true, paired: Bool = true, to phone: Phone) -> HTTP.Response? {
        var query = ["live": id]
        if let rate = rate { query["rate"] = rate }
        if last { query["last"] = "1" }
        var headers: [String: String] = paired ? ["cookie": "\(Phone.cookie)=\(token)"] : [:]
        headers["content-type"] = type
        if header { headers["x-speakhud"] = "1" }
        var answer: HTTP.Response?
        _ = phone.respondLater(to: HTTP.Request(method: "POST", path: "/api/hear", query: query, headers: headers, body: Data(count: bytes))) { answer = $0 }
        return answer
    }
    let w = Bench()
    w.phone.took(turn("a", "Want me to merge it?"))
    t.expect(w.phone.state()["canHearLive"] as? Bool == true, "the page is told this Mac can hear word for word")
    let soFar = piece(16_000, to: w.phone)
    t.expect(soFar?.status == 200 && json(soFar ?? HTTP.Response())["text"] as? String == "Yes, go" && w.livePieces == ["ab12cd34ef 16000 16000 more"],
             "a piece of sound comes back as the words so far")
    w.liveAnswer = .success("Yes, go ahead.")
    let final = piece(8_000, last: true, to: w.phone)
    t.expect(final?.status == 200 && json(final ?? HTTP.Response())["text"] as? String == "Yes, go ahead."
             && w.livePieces.last == "ab12cd34ef 16000 8000 last", "and the last piece as the words as they finally stand")
    t.expect(w.logs.contains { $0.hasPrefix("phone dictated 3 words word for word (0.8 s of sound, done ") } && !w.logs.contains { $0.contains("go ahead") },
             "logged once, when it's done: how much was said, never what")
    t.expect(piece(0, last: true, to: w.phone)?.status == 200 && piece(0, to: w.phone)?.status == 400,
             "the last piece may be empty (you stopped between two); any other must hold sound")
    let pieces = w.livePieces.count
    t.expect(piece(16_000, paired: false, to: w.phone)?.status == 401 && piece(16_000, header: false, to: w.phone)?.status == 404
             && piece(16_000, id: "../etc", to: w.phone)?.status == 400 && piece(16_000, id: "abc", to: w.phone)?.status == 400
             && piece(16_000, rate: nil, to: w.phone)?.status == 400 && piece(16_000, rate: "96000", to: w.phone)?.status == 400
             && piece(16_001, to: w.phone)?.status == 400 && piece(16_000, type: "audio/wav", to: w.phone)?.status == 400
             && w.livePieces.count == pieces,
             "an unpaired phone, another site's page, a name or a rate that isn't one, half a sample, or the wrong kind of sound: never heard")
    w.liveAnswer = .failure(Dictation.Failure("that dictation is over"))
    let over = piece(16_000, to: w.phone)
    t.expect(over?.status == 503 && String(decoding: over?.body ?? Data(), as: UTF8.self).contains("that dictation is over")
             && w.logs.contains { $0.hasPrefix("phone dictation failed ") && $0.hasSuffix("that dictation is over") },
             "a piece the transcriber can't take says why, to the page and the log")
    w.phone.hearLive = nil
    t.expect(w.phone.state()["canHearLive"] as? Bool == false && piece(16_000, to: w.phone)?.status == 501
             && said(twoSeconds, to: w.phone)?.status == 200, "a Mac that can't hear word for word still hears a whole recording")

    let micScript = h.phone.respond(to: get("/mic.js"))
    t.expect(micScript.status == 200 && micScript.type.hasPrefix("text/javascript") && String(decoding: micScript.body, as: UTF8.self).contains("registerProcessor"),
             "the page's microphone script is served with the page")

    t.expect(h.phone.respond(to: post("/api/mic", ["why": "NotAllowedError"])).status == 200
             && h.logs.contains("phone dictation didn't start: NotAllowedError")
             && h.phone.respond(to: post("/api/mic", ["why": "said: my password is 1234"])).status == 400
             && !h.logs.contains { $0.contains("password") },
             "a microphone that wouldn't start on the phone is logged by its error's name, and nothing else gets in")

    func announced(_ path: String, bytes: Int, method: String = "POST") -> HTTP.Parsed {
        HTTP.parse(Data("\(method) \(path) HTTP/1.1\r\nContent-Length: \(bytes)\r\n\r\n".utf8))
    }
    t.expect(announced("/api/hear", bytes: HTTP.maxBody + 1) == .incomplete && announced("/api/hear", bytes: HTTP.maxUpload) == .incomplete,
             "a recording may be far bigger than any other request")
    t.expect(announced("/api/hear", bytes: HTTP.maxUpload + 1) == .bad && announced("/api/reply", bytes: HTTP.maxBody + 1) == .bad
             && announced("/api/hear", bytes: HTTP.maxBody + 1, method: "PUT") == .bad, "but only so big, and only there")

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

    // A video through the real server: whole (more than two pieces of it), and in part.
    var film = turn("film", "Rendered.")
    film.media = [shots + "/clip one.mp4"]
    b.phone.took(film)
    func download(_ range: String?) -> (status: Int, range: String?, data: Data)? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/file?key=film&i=0")!)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 10
        request.setValue("\(Phone.cookie)=\(token)", forHTTPHeaderField: "Cookie")
        if let range = range { request.setValue(range, forHTTPHeaderField: "Range") }
        var got: (Int, String?, Data)?
        var finished = false
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                got = (http.statusCode, http.value(forHTTPHeaderField: "Content-Range"), data ?? Data())
            }
            finished = true
        }.resume()
        spin(12) { finished }
        return got.map { (status: $0.0, range: $0.1, data: $0.2) }
    }
    t.expect(clip.count > 2 * PhoneServer.piece, "the test video is more than two pieces long")
    let all = download(nil)
    t.expect(all?.status == 200 && all?.data == clip, "over a real connection a video arrives whole and unchanged, piece by piece")
    let some = download("bytes=300000-300099")
    t.expect(some?.status == 206 && some?.range == "bytes 300000-300099/700000" && some?.data == clip.subdata(in: 300_000..<300_100),
             "and the part asked for is exactly that part")
    t.expectEqual(download("bytes=-5")?.data ?? Data(), clip.suffix(5), "down to its last few bytes")
    try? fm.removeItem(atPath: shots + "/clip one.mp4")
    t.expectEqual(download(nil)?.status ?? 0, 404, "a file gone by the time it's asked for: nothing")

    // A recording through the real server: far bigger than an ordinary request, and
    // answered only when the transcriber (a stand-in here) has had its say, a moment later.
    server.slow = { b.phone.respondLater(to: $0, done: $1) }
    let minute = recording(60)
    b.hearAnswer = nil
    func dictate(_ body: Data, cookie: Bool = true) -> (status: Int, body: String)? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/hear")!)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15
        if cookie { request.setValue("\(Phone.cookie)=\(token)", forHTTPHeaderField: "Cookie") }
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-SpeakHUD")
        request.httpBody = body
        var got: (Int, String)?
        var finished = false
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { got = (http.statusCode, String(decoding: data ?? Data(), as: UTF8.self)) }
            finished = true
        }.resume()
        // The stand-in transcriber answers half a second after the recording has arrived.
        var answered = false
        spin(14) {
            if let done = b.hearDone, !answered {
                answered = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done(.success("Run the tests again.")) }
            }
            return finished
        }
        return got.map { (status: $0.0, body: $0.1) }
    }
    t.expect(minute.count > 20 * HTTP.maxBody, "the test recording is a minute long, thirty times an ordinary request's limit")
    let dictated = dictate(minute)
    t.expect(dictated?.status == 200 && dictated?.body.contains("Run the tests again.") == true && b.heardSizes.last == minute.count,
             "over a real connection a minute's recording arrives whole, and its words come back when they're ready")
    t.expectEqual(dictate(minute, cookie: false)?.status ?? 0, 401, "an unpaired phone's recording is turned away")

    // A transcriber that never answers: the page is told after a while, and the next
    // recording is heard. (The first build left every later one turned away.)
    let stuck = Bench()
    stuck.phone.hearPatience = 0.3
    stuck.hearAnswer = nil
    var gaveUp: HTTP.Response?, answers = 0
    _ = stuck.phone.respondLater(to: HTTP.Request(method: "POST", path: "/api/hear",
                                                   headers: ["cookie": "\(Phone.cookie)=\(token)", "content-type": "audio/wav", "x-speakhud": "1"],
                                                   body: twoSeconds)) { gaveUp = $0; answers += 1 }
    t.expect(gaveUp == nil, "a transcriber that hasn't answered yet: the page waits")
    spin(3) { gaveUp != nil }
    t.expect(gaveUp?.status == 503 && String(decoding: gaveUp?.body ?? Data(), as: UTF8.self).contains("took too long")
             && stuck.logs.contains { $0.hasPrefix("phone dictation failed after ") && $0.hasSuffix("the Mac took too long to hear it") },
             "past its patience the page is told the Mac took too long, and the log says so")
    stuck.hearDone?(.success("words that came far too late"))
    stuck.hearAnswer = .success("Heard this one.")
    let heardNext = said(twoSeconds, to: stuck.phone)
    t.expect(answers == 1 && heardNext?.status == 200 && json(heardNext ?? HTTP.Response())["text"] as? String == "Heard this one.",
             "the late answer goes nowhere, and the next recording is heard instead of being turned away")
}
