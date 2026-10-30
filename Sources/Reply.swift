import Cocoa

// Answering a turn out loud: what was heard goes into the prompt of the terminal that
// spoke, and Return is pressed once it shows there. iTerm2 only, which can be asked for
// a pane's screen and written to by AppleScript without coming forward.
//
// Pasted, never typed. A question or permission box takes a typed digit as its answer
// on the spot, and ignores a paste (both tried against Claude Code 2.1.293: a typed "2"
// picked the second option, a pasted "2" did nothing). So the words go in as a bracketed
// paste, only into a pane whose screen shows Claude's prompt box and no such box, and
// Return follows only when the prompt box then shows them. It counts as sent once they
// have left the box again.
//
// The phone answers the same panes, and a box as well, by its keys. So this is the one
// place a pane is read and written: `showing` says what a screen holds (Claude's prompt,
// a box, a turn at work, or nothing of Claude's), and `send`, `press`, `pick` and
// `close` each look at the pane themselves before they write a thing to it. `press` and
// `pick` are also told what the page had drawn, and write only if that still stands.
// iTerm2 is reached through `Terminal`, which tests swap for a fake one.
enum Reply {
    static let maxLength = 4000
    /// How often, and how far apart, the screen is read again for the paste to show.
    static let looks = 8
    static let lookGap: TimeInterval = 0.1

    /// Whether an item from `origin` can be answered: an iTerm2 pane or an Agent Terminal
    /// session, by its id.
    static func canReach(_ origin: Origin?) -> Bool {
        guard let o = origin, o.session != nil else { return false }
        let term = o.term ?? ""
        return term == "iTerm.app" || term == AgentLink.term || term.isEmpty
    }

    /// What was heard as one line a terminal can take: no line breaks or control
    /// characters (either could be a keypress, or end the paste early), space closed up,
    /// and nothing ahead of the first word that Claude's prompt would take as a mode
    /// ("!" runs a shell command, "/" a slash command). Nil if nothing is left.
    static func clean(_ heard: String) -> String? {
        let breaks = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        var line = heard.components(separatedBy: breaks).filter { !$0.isEmpty }.joined(separator: " ")
        while let first = line.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first),
              first != "\"", first != "'", first != "(" {
            line = String(line.unicodeScalars.dropFirst())
            line = line.trimmingCharacters(in: .whitespaces)
        }
        return line.isEmpty ? nil : String(line.prefix(maxLength))
    }

    // -- what a pane is showing ----------------------------------------------
    //
    // Everything that writes to a pane asks this first, and it is asked one way:
    // `showing`. What a prompt, a box and a rule look like is known here and nowhere else.

    /// Claude's prompt box as a screen shows it.
    struct Prompt: Equatable {
        var text: String            // what it holds: nothing, a placeholder, or a message being written
        var status: String? = nil   // the status line under it (yours to set: a folder, the model, the context)
        var context: Int? = nil     // how full the context is, in percent, if that line says
        var working = false         // a turn is running over it: what's sent now waits its turn
    }

    /// What a pane is showing: the one answer to what a paste or a key would do there.
    enum Showing: Equatable {
        /// Claude's prompt box: takes a paste as a message, and Enter and Esc.
        case prompt(Prompt)
        /// A box of choices, read whole: a question, a permission prompt, the folder-trust check. Takes keys as answers.
        case box(TerminalBox)
        /// Something that says it takes keys (this line of it), but not as choices this can read.
        case keys(String)
        /// A turn running with no prompt box in sight, where Esc stops it. The screen says
        /// so itself, or (`onScreen` false) only the glyph spinning on the pane's title does.
        case working(onScreen: Bool)
        /// None of those, and why: a shell, a blank screen. Nothing is written to it.
        case notClaude(String)

        var prompt: Prompt? { if case .prompt(let prompt) = self { return prompt }; return nil }
        var box: TerminalBox? { if case .box(let box) = self { return box }; return nil }

        /// In the middle of a turn. A box that's up is waiting on you, whatever runs behind it.
        var busy: Bool {
            switch self {
            case .prompt(let prompt): return prompt.working
            case .working: return true
            case .box, .keys, .notClaude: return false
            }
        }

        /// Whether the screen itself is Claude Code's. A glyph on the title isn't that:
        /// a shell's title can start with one too.
        var isClaude: Bool {
            switch self {
            case .prompt, .box, .keys, .working(onScreen: true): return true
            case .working, .notClaude: return false
            }
        }
    }

    /// What `screen` (a pane's visible text) is showing. `title` is the pane's: Claude Code
    /// spins a glyph at the front of it while it works and leaves ✳ there when it's
    /// waiting for you.
    static func showing(_ screen: String, title: String? = nil) -> Showing {
        let lines = lines(of: screen)
        let onScreen = screen.contains("esc to interrupt")
        if var prompt = prompt(in: lines) {
            prompt.working = onScreen || spins(title)
            return .prompt(prompt)
        }
        if let box = box(in: lines) { return .box(box) }
        // The last thing on the screen says which keys answer it: a box of Claude's all
        // the same. Said further up, it's something Claude left behind, or was talking about.
        let foot = lines.map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        if let foot = foot, saysKeys(foot) { return .keys(foot) }
        if onScreen || spins(title) { return .working(onScreen: onScreen) }
        return .notClaude(foot == nil ? "its screen is blank" : "nothing at the foot of its screen is Claude's prompt or a box of its")
    }

    /// The newest thing Claude has put on a screen: its last stretch of words, or the tool
    /// it's running ("Bash(npm test)"), as one line cut to `maxLength`. Nil when none is in
    /// sight. For the phone, under its working bar: a long turn otherwise says nothing
    /// until it ends (Chris, 10-07, twenty minutes into one: "Yo, are you stuck?").
    static func doing(_ screen: String, maxLength: Int = 160) -> String? {
        let lines = lines(of: screen)
        guard let at = lines.lastIndex(where: { $0.hasPrefix("⏺ ") }) else { return nil }
        var parts = [String(lines[at].dropFirst(2))]
        // Its words wrap onto lines set in by two; what a tool gave back starts "⎿".
        for line in lines[(at + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("  "), !t.isEmpty, !t.hasPrefix("⎿") else { break }
            parts.append(t)
        }
        let words = parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return words.count > maxLength ? String(words.prefix(maxLength - 1)) + "…" : words
    }

    /// A screen as its lines, a no-break space read as a space.
    private static func lines(of screen: String) -> [String] {
        screen.components(separatedBy: .newlines).map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
    }

    /// What a box that takes keys as answers says about itself.
    private static let boxHints = ["Esc to cancel", "Enter to select", "Enter to confirm", "(esc)"]
    private static func saysKeys(_ line: String) -> Bool { boxHints.contains { line.contains($0) } }

    private static func spins(_ title: String?) -> Bool {
        guard let name = title?.replacingOccurrences(of: "\u{00A0}", with: " "),
              let first = name.unicodeScalars.first, name.dropFirst().hasPrefix(" ") else { return false }
        return first != "✳" && !CharacterSet.alphanumerics.contains(first)
    }

    /// A line ruled across the pane, and how: solid from end to end, solid with something
    /// set in it, or dashed. The prompt box sits between rules that aren't dashed; a box
    /// of choices opens under a solid one, and solid or dashed ones may cross it.
    private enum Rule { case solid, lettered, dashed }
    private static func rule(_ line: String) -> Rule? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 10 else { return nil }
        if t.allSatisfy({ $0 == "─" }) { return .solid }
        if t.allSatisfy({ $0 == "─" || $0 == "╌" }) { return .dashed }
        return t.hasPrefix("─") && t.hasSuffix("─") && t.filter({ $0 == "─" }).count >= 10 ? .lettered : nil
    }

    /// Claude Code's prompt box, if the foot of the screen shows one that would take a
    /// paste as a message: a line starting "❯" with a rule right above it and a rule
    /// below, after any wrapped lines. Nil for anything else: a question or permission
    /// box (their options sit under the question, not under a rule, and say how to
    /// answer underneath), shell mode ("!"), a pane that isn't running Claude at all.
    private static func prompt(in lines: [String]) -> Prompt? {
        func ruled(_ line: String) -> Bool { rule(line).map { $0 != .dashed } ?? false }
        guard let bottom = lines.lastIndex(where: ruled) else { return nil }
        // A box that takes keys as answers says so under itself.
        let under = lines[(bottom + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if under.contains(where: saysKeys) { return nil }
        // The prompt box sits at the foot of the screen, over a status line or two. A
        // rule with more than that under it belongs to something else.
        guard under.count <= 5 else { return nil }
        var top = bottom - 1
        while top >= 0, !lines[top].hasPrefix("❯"), !ruled(lines[top]) { top -= 1 }
        guard top >= 1, lines[top].hasPrefix("❯"), ruled(lines[top - 1]) else { return nil }
        var parts = [String(lines[top].dropFirst())]
        parts += lines[(top + 1)..<bottom]
        let held = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // "1. Yes" over "2. No": an option list that happens to sit between rules is still
        // not a prompt. One numbered line is a message you're writing ("1. fix the header").
        let numbered = held.filter { $0.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil }
        if numbered.count >= 2, held.first == numbered.first { return nil }
        var prompt = Prompt(text: held.joined(separator: " "))
        // Its status line is the first thing under it. Whatever sits far to the right of
        // that, a notice with a gap before it, is left off.
        let left = under.first?.components(separatedBy: "   ").first ?? ""
        let line = left.components(separatedBy: " ").filter { !$0.isEmpty }.joined(separator: " ")
        guard !line.isEmpty else { return prompt }
        prompt.status = line
        if let m = line.range(of: #"(?i)(ctx|context)\D{0,3}(\d{1,3})\s?%|(\d{1,3})\s?%\s*(ctx|context)"#, options: .regularExpression),
           let n = Int(line[m].filter { $0.isNumber }), (0...100).contains(n) {
            prompt.context = n
        }
        return prompt
    }

    /// The box of choices at the foot of the screen, or nil: nothing there reads as a
    /// list of choices with a cursor on one, or nothing says it is a box of Claude's.
    private static func box(in screen: [String]) -> TerminalBox? {
        list(in: screen).flatMap { $0.isBox ? $0.box : nil }
    }

    /// The list of choices at the foot of the screen as it reads, with a cursor on one,
    /// whoever drew it. `isBox`: the screen itself says it is a box of Claude's.
    /// `footed`: no more is under it than one line, however a narrow pane wrapped that.
    private static func list(in screen: [String]) -> (box: TerminalBox, isBox: Bool, footed: Bool)? {
        var lines = screen
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        func col(_ line: String) -> Int? {
            line.firstIndex { $0 != " " }.map { line.distance(from: line.startIndex, to: $0) }
        }
        func blank(_ i: Int) -> Bool { lines[i].trimmingCharacters(in: .whitespaces).isEmpty }
        func ruled(_ i: Int) -> Bool { rule(lines[i]).map { $0 != .lettered } ?? false }
        // The cursor: the last line that starts with ❯ and something after it.
        guard let at = lines.lastIndex(where: { l in col(l).map { l.dropFirst($0).hasPrefix("❯ ") } ?? false }),
              let c = col(lines[at]) else { return nil }
        // Its list runs up and down from there: rows start two columns in from the
        // cursor, what's under a row is indented further, and a rule may cross it.
        func inList(_ i: Int) -> Bool {
            if blank(i) { return false }
            if ruled(i) { return true }
            return i == at || (col(lines[i]) ?? 0) >= c + 2
        }
        var top = at, bottom = at
        while top > 0, inList(top - 1) { top -= 1 }
        while bottom < lines.count - 1, inList(bottom + 1) { bottom += 1 }
        while top < at, ruled(top) { top += 1 }
        // Under a box's list there's nothing but its hint line: with anything more, that ❯
        // was a line of the conversation, not a cursor. What "more" is, is weighed below.
        let under = (bottom + 1..<lines.count).filter { !blank($0) }
        let hints = under.isEmpty ? nil : under.map { lines[$0].trimmingCharacters(in: .whitespaces) }.joined(separator: " ")

        var rows: [TerminalBox.Row] = []
        var labelCol = c + 2
        for i in top...bottom where !ruled(i) {
            let k = i == at ? c + 2 : (col(lines[i]) ?? 0)
            var text = String(lines[i].dropFirst(min(k, lines[i].count))).trimmingCharacters(in: .whitespaces)
            if i == at { text = String(lines[i].dropFirst(c + 1)).trimmingCharacters(in: .whitespaces) }
            let numbered = text.range(of: #"^\d{1,2}\.\s+"#, options: .regularExpression)
            if k == c + 2, let n = numbered {
                var row = TerminalBox.Row(label: String(text[n.upperBound...]), number: Int(text.prefix { $0.isNumber }), cursor: i == at)
                labelCol = k + text.distance(from: text.startIndex, to: n.upperBound)
                if let box = row.label.range(of: #"^\[(.)\]\s+"#, options: .regularExpression) {
                    row.checked = !row.label[box].hasPrefix("[ ]")
                    labelCol += row.label.distance(from: row.label.startIndex, to: box.upperBound)
                    row.label = String(row.label[box.upperBound...])
                }
                rows.append(row)
            } else if k == c + 2 || (k < labelCol && rows.last?.checked != nil) || rows.isEmpty {
                // A row with no number: the trust box's choices, or Submit under a list of ticks.
                rows.append(TerminalBox.Row(label: text, cursor: i == at))
            } else {
                // Under a row: its description, or the rest of a label that wrapped.
                rows[rows.count - 1].detail = [rows[rows.count - 1].detail, text].compactMap { $0 }.joined(separator: " ")
            }
        }
        guard rows.count >= 2, rows.contains(where: { $0.cursor }) else { return nil }

        // What it says: from the rule that opens the box down to the list.
        var open = top
        while open > 0, rule(lines[open - 1]) != .solid, top - open < 40 { open -= 1 }
        var said: [String] = []
        var tabs: String?
        for i in open..<top where !blank(i) && !ruled(i) {
            let text = lines[i].trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("←") || (said.isEmpty && (text.hasPrefix("☐ ") || text.hasPrefix("☒ "))) {
                // The strip of questions (several), or the one question's own heading.
                tabs = text.trimmingCharacters(in: CharacterSet(charactersIn: "←→ ")).replacingOccurrences(of: "  ", with: " ")
            } else {
                said.append(text)
            }
        }
        let box = TerminalBox(ask: said.joined(separator: "\n"), tabs: tabs, rows: rows, hints: hints)
        let opened = open > 0 && rule(lines[open - 1]) == .solid
        // Lines under it are one line a narrow pane wrapped if the first word of each
        // wouldn't have fitted on the end of the one before. How wide the pane is, the
        // rule that opens the box says; a box set in from the edge is set in at both.
        let width = opened ? lines[open - 1].trimmingCharacters(in: .whitespaces).count : 0
        let footed = under.count <= 1 || opened && zip(under, under.dropFirst()).allSatisfy { a, b in
            let line = lines[a].replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            let word = lines[b].split(separator: " ").first?.count ?? 0
            return line.count + 1 + word > width - (col(line) ?? 0)
        }
        // Something has to say this is a box of Claude's: not being the prompt isn't
        // enough (a shell isn't the prompt either). One of two things does.
        // The one line under its choices names the keys that answer it.
        if under.count == 1, let h = hints, saysKeys(h) { return (box, true, footed) }
        // Or it is drawn the way Claude draws every dialog, whatever words it uses: a rule
        // across the pane, what it asks, then its choices numbered from 1, with no rule
        // through them, and under them nothing but a line set in from the edge as they are
        // (the plan to approve has one that names no key; some permission boxes have none).
        // The prompt box is never that: its ❯ sits right under its rule, with nothing
        // asked between. Nor is a shell: the line its ❯ is on has no number, and its
        // prompt starts at the edge of the pane.
        let headed = tabs != nil || !said.isEmpty
        let counted = rows.enumerated().allSatisfy { $0.element.number == $0.offset + 1 }
        let unruled = at > 0 && rule(lines[at - 1]) == nil && !(top...bottom).contains { rule(lines[$0]) != nil }
        let setIn = under.count <= 2 && under.allSatisfy { c > 0 && col(lines[$0]) == c && rule(lines[$0]) == nil }
        return (box, opened && headed && counted && unruled && setIn, footed)
    }

    /// Whether the list of choices at the foot of `screen` is the question the hook read
    /// out as `asked`, with its choice numbered `number` the one worded `option`. For a
    /// screen no box is read on (its line of keys wrapped by a narrow pane, or worded
    /// some new way): the hook's words are then what says whose list it is. No more may
    /// be under it than its one line, so a box left on the screen over a shell's prompt
    /// is not that.
    private static func asks(_ screen: String, choice number: Int, worded option: String, asked: String) -> Bool {
        guard let list = list(in: lines(of: screen)), list.footed else { return false }
        return list.box.isChoice(number, worded: option, asked: asked)
    }

    /// Whether the prompt box now holds what was pasted and nothing ahead of it: it
    /// starts with the first stretch of it (wrapping aside), or, for a long paste, with
    /// the marker Claude Code folds one into. Text you had already typed there fails
    /// this, and Return is left to you.
    ///
    /// `pictures` are the paths this paste itself put on the end of the words (the
    /// phone's, sent with an answer). Such a path doesn't stay in the words: Claude Code
    /// takes it out and puts "[Image #1]" at the front of the box instead (seen in
    /// 2.1.294: a paste of "Look at this picture from my phone: /…/a.jpg" shows as
    /// "[Image #1]Look at this picture from my phone:"). So those paths aren't looked
    /// for, and that many markers at the front aren't something put there ahead. Only
    /// those: a link or a path the reply names in its own words stays where it was said,
    /// and a picture already in the box is yours.
    ///
    /// `markerIsOurs` false: the box started with that marker before this paste, so it
    /// is a long paste of yours, and it says nothing about this one.
    static func shows(_ text: String, inPrompt box: String, pictures: [String] = [], markerIsOurs: Bool = true) -> Bool {
        func squash(_ s: String) -> String { String(s.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }) }
        var words = text, held = box
        for path in pictures where !path.isEmpty {
            words = words.replacingOccurrences(of: path, with: "")
            held = held.replacingOccurrences(of: #"^\s*\[Image #\d+\]"#, with: "", options: .regularExpression)
        }
        let want = squash(words), have = squash(held)
        guard !want.isEmpty else { return false }
        return have.hasPrefix(String(want.prefix(40))) || (markerIsOurs && folded(held))
    }

    /// Whether a prompt box starts with the marker Claude Code folds a long paste into.
    static func folded(_ box: String) -> Bool {
        String(box.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }).hasPrefix("[Pastedtext#")
    }

    // -- iTerm2 ----------------------------------------------------------------

    /// What iTerm2 said to one script: its reply, or the AppleScript error.
    struct Answer: Equatable {
        var reply: String? = nil
        var errorCode: Int? = nil
        var errorMessage: String? = nil
    }

    /// iTerm2 as everything here reaches it: a script goes in and its answer comes back,
    /// and there's a wait between writing to a pane and looking at it again. This is the
    /// one seam: the app's is the real iTerm2, a test's is a fake one answering `ask`.
    struct Terminal {
        var ask: (String) -> Answer = Reply.ask
        var wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        /// Agent Terminal, for its own sessions (`AgentLink`).
        #if TESTING
        var link: (([String: Any]) -> [String: Any]?)? = nil
        #else
        var link: (([String: Any]) -> [String: Any]?)? = AgentLink.call
        #endif
    }

    /// One thing to do to a pane, said both ways: the AppleScript for iTerm2 and the
    /// request for Agent Terminal. The session's id decides which goes.
    struct Op {
        var session: String
        var source: String
        var link: [String: Any]

        static func screen(_ session: String) -> Op {
            Op(session: session, source: screenScript(session), link: ["op": "screen"])
        }
        static func write(_ session: String, _ text: String, _ source: String) -> Op {
            Op(session: session, source: source, link: ["op": "write", "text": text])
        }
    }

    private static func tell(_ terminal: Terminal, _ op: Op) -> Result<String, Outcome> {
        guard AgentLink.owns(op.session) else { return tell(terminal, op.source) }
        var request = op.link
        request["session"] = op.session
        guard let answer = terminal.link?(request), answer["ok"] as? Bool == true else { return .failure(.gone) }
        return .success(answer["text"] as? String ?? "")
    }

    /// Run one script: what it gave back after its "ok", or why there's nothing. The one
    /// place a pane that has gone, a refused permission and an AppleScript error get
    /// their names.
    private static func tell(_ terminal: Terminal, _ source: String) -> Result<String, Outcome> {
        let a = terminal.ask(source)
        if let code = a.errorCode {
            return .failure(code == -1743 ? .denied : .failed(a.errorMessage ?? "AppleScript error \(code)"))   // errAEEventNotPermitted
        }
        guard let reply = a.reply, reply.hasPrefix("ok") else { return .failure(.gone) }
        return .success(String(reply.dropFirst(2)))
    }

    /// A script that writes to a pane: nil once it has, or why it didn't.
    private static func wrote(_ terminal: Terminal, _ op: Op) -> Outcome? {
        if case .failure(let why) = tell(terminal, op) { return why }
        return nil
    }

    /// One look at the pane `session`: what the foot of its screen is showing.
    private static func look(_ session: String, _ terminal: Terminal) -> Result<Showing, Outcome> {
        tell(terminal, .screen(session)).map { showing(foot($0)) }
    }

    /// An AppleScript that finds the pane `session` and does `action` with it as `s`.
    /// `action` ends by returning something starting "ok"; "missing" comes back when the
    /// pane is gone. Only a validated id (Origin) and a cleaned line are ever put in.
    static func script(_ session: String, _ action: String) -> String {
        """
        tell application id "\(Reveal.iTerm)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (id of s) is "\(session)" then
                            \(action)
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    static func screenScript(_ session: String) -> String {
        script(session, "return \"ok\" & linefeed & (contents of s)")
    }

    /// The line as a bracketed paste: Claude's prompt takes it as one paste, and a box
    /// that answers to keys doesn't take it at all.
    static func pasteScript(_ session: String, _ line: String) -> String {
        script(session, """
        tell s to write text ((character id 27) & "[200~" & \(LoadCommand.literal(line)) & (character id 27) & "[201~") newline no
                            return "ok"
        """)
    }

    /// Return, as the key sends it (a carriage return; a line feed is Claude's "new line").
    static func returnScript(_ session: String) -> String {
        script(session, """
        tell s to write text (character id 13) newline no
                            return "ok"
        """)
    }

    /// What the phone's key buttons send: the bytes the keys send themselves.
    static let keys: [String: [Int]] = [
        "enter": [13], "esc": [27], "tab": [9], "space": [32],
        "up": [27, 91, 65], "down": [27, 91, 66],
        "1": [49], "2": [50], "3": [51], "4": [52], "5": [53], "6": [54], "7": [55], "8": [56], "9": [57],
    ]

    static func keyScript(_ session: String, _ codes: [Int]) -> String {
        let chars = codes.map { "(character id \($0))" }.joined(separator: " & ")
        return script(session, """
        tell s to write text (\(chars)) newline no
                            return "ok"
        """)
    }

    /// One named key, written to the pane as it is. Only for what has already looked at
    /// the pane and knows the key belongs there: `press`, `pick`, `close`.
    private static func key(_ name: String, _ session: String, _ terminal: Terminal) -> Outcome {
        guard let codes = keys[name] else { return .failed("no such key") }
        let text = String(String.UnicodeScalarView(codes.compactMap { Unicode.Scalar($0) }))
        return wrote(terminal, .write(session, text, keyScript(session, codes))) ?? .sent
    }

    /// `line` typed into the pane as keys (not a paste: a question's own text field takes
    /// no paste), with no Return. For the same callers as `key`.
    private static func type(_ line: String, _ session: String, _ terminal: Terminal) -> Outcome {
        wrote(terminal, .write(session, line, script(session, """
        tell s to write text \(LoadCommand.literal(line)) newline no
                            return "ok"
        """))) ?? .sent
    }

    /// What a page had drawn where a key was tapped. Pressing asks for it: a key goes
    /// only into what was drawn, so nothing is pressed blind.
    enum Tapped: Equatable {
        /// A box: one of its own buttons, or a key under its screen.
        case box(TerminalBox.Drawn)
        /// The question hook's words, which stand in until the screen is read, and the
        /// choice the tapped number was beside.
        case question(asked: String, option: String)
        /// No box: a key under a screen that had none drawn.
        case noBox
    }

    /// Press one named key in the pane `origin` names, if the pane is showing what the
    /// page had drawn when it was `tapped`, and that takes the key:
    /// - a box takes any key, and only if it's the box that was drawn (for a hook's
    ///   question: the box that asks it, where that number is that choice; where no box
    ///   is read, the list at the foot of the screen that is that question and choice);
    /// - something else that says it takes keys takes any, from a page with no box drawn;
    /// - Claude's prompt takes Enter and Esc (send what's typed; stop the turn). Any
    ///   other key lands in the message being typed, and the next answer is pasted after it;
    /// - a turn running with no prompt in sight takes Esc;
    /// - anything else takes nothing. In a pane that has dropped to its shell, Up and
    ///   Enter run its last command again.
    static func press(_ key: String, on tapped: Tapped, in origin: Origin, via terminal: Terminal = Terminal()) -> Outcome {
        guard canReach(origin), let session = origin.session else { return .gone }
        guard keys[key] != nil else { return .failed("no such key") }
        switch tell(terminal, .screen(session)).map({ foot($0) }) {
        case .failure(let stop): return stop
        case .success(let screen): return refusal(of: key, on: tapped, screen: screen) ?? self.key(key, session, terminal)
        }
    }

    /// Why `key`, tapped on what the page had drawn, isn't pressed in a pane whose
    /// screen is this. Nil when it is to be.
    private static func refusal(of key: String, on tapped: Tapped, screen: String) -> Outcome? {
        func notClaude(_ why: String) -> Outcome { .failed("its terminal isn't showing Claude Code (\(why)), so no key is pressed there") }
        switch (showing(screen), tapped) {
        case (.box(let box), .box(let drawn)):
            return box.isBox(drawn) ? nil : .changed
        case (.box(let box), .question(let asked, let option)):
            return box.isChoice(Int(key) ?? 0, worded: option, asked: asked) ? nil : .changed
        case (.box, .noBox):
            return .changed   // a box the page never drew: Enter would take whichever choice its cursor is on
        case (_, .box), (.prompt, .question):
            return .changed   // the box it was tapped for has gone: Enter would now send whatever is typed
        case (let showing, .question(let asked, let option)):
            // No box is read there, and that isn't the same as the question having gone:
            // its number is pressed if the list at the foot of the screen is that
            // question with that choice. If not, what is wrong is said, not "changed".
            if asks(screen, choice: Int(key) ?? 0, worded: option, asked: asked) { return nil }
            if case .notClaude(let why) = showing { return notClaude(why) }
            return .failed("no list of choices on its screen reads as that question with that choice at that number, so no key is pressed there")
        case (.keys, .noBox):
            return nil
        case (.prompt, .noBox):
            return ["enter", "esc"].contains(key) ? nil : .failed("its terminal is at Claude's prompt, where that key would only type into your message")
        case (.working, .noBox):
            // Esc stops a turn, and does nothing to a shell whose title only looked like one.
            return key == "esc" ? nil : .failed("its terminal is in the middle of a turn with no box up, where only Esc (which stops it) is pressed")
        case (.notClaude(let why), .noBox):
            return notClaude(why)
        }
    }

    /// What `pick` answers when words come with a choice that isn't a text field.
    static let takesNoWords = "that choice doesn't take words"

    /// Pick choice `row` of the box that was `drawn`, if that is the box the pane is
    /// showing now: its digit, or the arrows from where the cursor is now and Enter.
    /// `words` are for the choice that turns into a text field: it's picked, they're
    /// typed on one line, and Enter follows.
    static func pick(_ row: Int, of drawn: TerminalBox.Drawn, words: String? = nil, in origin: Origin,
                     via terminal: Terminal = Terminal()) -> Outcome {
        guard canReach(origin), let session = origin.session else { return .gone }
        let showing: Showing
        switch look(session, terminal) {
        case .failure(let stop): return stop
        case .success(let seen): showing = seen
        }
        guard let box = showing.box, box.isBox(drawn), var keys = box.keys(toPick: row) else { return .changed }
        var line: String?
        if let words = words {
            guard box.rows[row].types, box.rows[row].checked == nil, let cleaned = clean(words) else { return .failed(takesNoWords) }
            line = cleaned
            keys.append("enter")
        }
        var outcome = Outcome.sent
        for (i, name) in keys.enumerated() where outcome == .sent {
            if i > 0 { terminal.wait(0.15) }
            if let line = line, i == keys.count - 1 {
                outcome = type(line, session, terminal)
                if outcome == .sent { terminal.wait(0.15) }
            }
            if outcome == .sent { outcome = key(name, session, terminal) }
        }
        return outcome
    }

    /// The foot of the pane's screen as text, for the phone to show. Nil when it's gone.
    static func screen(of origin: Origin, lines: Int = 40, via terminal: Terminal = Terminal()) -> String? {
        guard canReach(origin), let session = origin.session,
              case .success(let contents) = tell(terminal, .screen(session)) else { return nil }
        return foot(contents, lines: lines)
    }

    /// A pane iTerm2 has open: its id, its title, and the foot of its screen.
    struct Pane: Equatable {
        var session: String
        var name: String
        var screen: String

        var showing: Showing { Reply.showing(screen, title: name) }
    }

    /// Every pane, in one ask. The separators are control characters spelled as
    /// character ids: a title or a screen can hold anything else, and inside iTerm2's
    /// `tell` the word `tab` means one of its tabs.
    static let surveyScript = """
        tell application id "\(Reveal.iTerm)"
            set out to "ok"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set out to out & (character id 30) & (id of s) & (character id 31) & (name of s) & (character id 31) & (contents of s)
                    end repeat
                end repeat
            end repeat
            return out
        end tell
        """

    /// The open panes, or nil when iTerm2 isn't running or won't say (then nothing is
    /// known, which is not the same as nothing being open).
    static func survey(via terminal: Terminal = Terminal()) -> [Pane]? {
        guard case .success(let records) = tell(terminal, surveyScript) else { return nil }
        return records.components(separatedBy: "\u{1E}").dropFirst().compactMap { record in
            let fields = record.components(separatedBy: "\u{1F}")
            guard fields.count == 3, Origin(json: ["session": fields[0]]) != nil else { return nil }
            return Pane(session: fields[0], name: fields[1], screen: foot(fields[2]))
        }
    }

    /// What `survey` found plus Agent Terminal's sessions, and whether iTerm2 said at all:
    /// if it didn't, nothing is known about its panes. Nil when neither said.
    static func surveyAll(via terminal: Terminal = Terminal()) -> (panes: [Pane], iTermSaid: Bool)? {
        let iTerm = survey(via: terminal)
        let own = (terminal.link?(["op": "survey"])?["panes"] as? [[String: String]])?.compactMap { pane -> Pane? in
            guard let id = pane["session"], AgentLink.owns(id) else { return nil }
            return Pane(session: id, name: pane["name"] ?? "", screen: foot(pane["screen"] ?? ""))
        }
        if iTerm == nil && own == nil { return nil }
        return ((iTerm ?? []) + (own ?? []), iTerm != nil)
    }

    /// The last `lines` lines of a screen, without the blank ones under them.
    static func foot(_ contents: String, lines: Int = 40) -> String {
        let all = contents.components(separatedBy: .newlines)
        var end = all.count
        while end > 0, all[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return all[max(0, end - lines)..<end].joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// Close the pane: Claude Code is asked to exit first if it's at its prompt (so the
    /// session ends cleanly and iTerm2 has no running job to ask about), then the pane goes.
    static func close(_ origin: Origin, via terminal: Terminal = Terminal()) -> Outcome {
        guard canReach(origin), let session = origin.session else { return .gone }
        if case .success(.prompt(let prompt)) = look(session, terminal), prompt.text.isEmpty {
            _ = type("/exit", session, terminal)
            terminal.wait(0.3)
            _ = key("enter", session, terminal)
            terminal.wait(1.5)
        }
        let closing = Op(session: session, source: script(session, """
        tell s to close
                            return "ok"
        """), link: ["op": "close"])
        switch wrote(terminal, closing) {
        case nil, .gone?: return .sent   // gone: it had already closed when Claude exited. Closed all the same.
        case let stop?: return stop
        }
    }

    /// A pane's title as Claude Code sets it ("✳ Grow guide replies — ~/some/dir"), down
    /// to the name a turn from it goes by.
    static func paneName(_ title: String) -> String {
        var name = title.replacingOccurrences(of: "\u{00A0}", with: " ")   // it's set with no-break spaces
        if let dir = name.range(of: " — ", options: .backwards) { name = String(name[..<dir.lowerBound]) }
        if let first = name.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first),
           let space = name.firstIndex(of: " ") {
            name = String(name[name.index(after: space)...])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? title.trimmingCharacters(in: .whitespaces) : name
    }

    enum Outcome: Equatable, CustomStringConvertible, Error {
        case sent
        case notAtPrompt   // nothing pasted: a question or permission box is up, or no prompt in sight
        case unconfirmed   // pasted, but it didn't show at the start of the prompt (Return not pressed), or it's still there after Return
        case changed       // no key pressed: the box up now isn't the one the tap was drawn on
        case gone          // its terminal has closed
        case denied        // Automation permission refused
        case failed(String)

        var description: String {
            switch self {
            case .sent: return "sent"
            case .notAtPrompt: return "its terminal isn't at Claude's prompt"
            case .unconfirmed: return "pasted, but Return is yours to press"
            case .changed: return "its box has changed since this was drawn"
            case .gone: return "its terminal is gone"
            case .denied: return "not allowed to control iTerm2 — grant it in System Settings › Privacy & Security › Automation › SpeakHUD"
            case .failed(let why): return why
            }
        }
    }

    /// Runs a script against iTerm2 if it's running. `tell application` would launch one
    /// that's been quit; a quit iTerm2 has no pane to answer in.
    static func ask(_ source: String) -> Answer {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Reveal.iTerm).isEmpty else {
            return Answer(reply: "missing")
        }
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err = err {
            return Answer(errorCode: err[NSAppleScript.errorNumber] as? Int ?? 0,
                          errorMessage: err[NSAppleScript.errorMessage] as? String)
        }
        return Answer(reply: result?.stringValue)
    }

    /// Paste `heard` into the prompt of the pane `origin` names and press Return.
    /// `pictures` are the paths on the end of it that are pictures being sent with it.
    static func send(_ heard: String, to origin: Origin, pictures: [String] = [], via terminal: Terminal = Terminal()) -> Outcome {
        guard canReach(origin), let session = origin.session else { return .gone }
        guard let line = clean(heard) else { return .failed("nothing to send") }

        let foldedBefore: Bool
        switch look(session, terminal) {
        case .failure(let stop): return stop
        case .success(let before):
            guard let box = before.prompt else { return .notAtPrompt }
            foldedBefore = folded(box.text)
        }
        /// Whether the prompt box is what's showing, holding the paste and nothing ahead of it.
        func holdsIt(_ showing: Showing) -> Bool {
            showing.prompt.map { shows(line, inPrompt: $0.text, pictures: pictures, markerIsOurs: !foldedBefore) } ?? false
        }
        let paste = "\u{1B}[200~" + line + "\u{1B}[201~"
        if let stop = wrote(terminal, .write(session, paste, pasteScript(session, line))) { return stop }
        for _ in 0..<looks {
            terminal.wait(lookGap)
            switch look(session, terminal) {
            case .failure(let stop): return stop
            case .success(let now): guard holdsIt(now) else { continue }
            }
            if let stop = wrote(terminal, .write(session, "\r", returnScript(session))) { return stop }
            // Sent means gone from the box. Still sitting there, Return didn't take.
            for _ in 0..<looks {
                terminal.wait(lookGap)
                switch look(session, terminal) {
                case .failure(let stop): return stop
                case .success(let after): guard holdsIt(after) else { return .sent }
                }
            }
            return .unconfirmed
        }
        return .unconfirmed
    }
}
