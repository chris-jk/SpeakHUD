// Reply tests. Registered in tests/main.swift.
//
// Answering a turn out loud: the words (Reply.clean, SpokenCommand), reading a pane's
// screen for Claude's prompt box (the screens below are what Claude Code 2.1.293 drew,
// captured from iTerm2 and from a tmux pane), the paste-then-Return exchange with
// iTerm2 against a fake one, and Playback's reply window on a fake mic.
import Foundation

private let rule = String(repeating: "─", count: 94)

private func screen(_ lines: String...) -> String { lines.joined(separator: "\n") }

/// A session at its prompt, with whatever `box` lines the prompt holds, as iTerm2 reports
/// it: trailing spaces, a status line and the mode line under the box.
private func atPrompt(_ box: String...) -> String {
    screen("⏺ Done.", " ", rule, box.joined(separator: "\n"), rule,
           "  me  |  Opus  ctx:21% used ", "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent")
}

private let questionBox = screen(
    "❯ Use the AskUserQuestion tool to ask me one question: which color do I prefer, red or blue?",
    rule,
    " ☐ Color",
    "Which color do you prefer, red or blue?",
    "❯ 1. Red",
    "     You prefer red.",
    "  2. Blue",
    "     You prefer blue.",
    "  3. Type something.",
    rule,
    "  4. Chat about this",
    "Enter to select · ↑/↓ to navigate · Esc to cancel")

private let trustBox = screen(
    rule,
    " Accessing workspace:",
    " /private/tmp/scratch",
    " Quick safety check: Is this a project you created or one you trust?",
    " Security guide",
    " ❯ No, exit",
    "   Yes, I trust this folder",
    " Enter to confirm · Esc to cancel")

/// iTerm2 with one pane, as Reply.send sees it: asked for the screen it gives `screen`;
/// handed a paste it does what `onPaste` says; Return is only recorded.
private final class FakeTerm {
    enum Call: Equatable { case screen, paste(String), enter }
    var screen: String
    var calls: [Call] = []
    var waits = 0
    /// What a paste does to the screen. Default: Claude's prompt takes it.
    var onPaste: (FakeTerm, String) -> Void = { term, text in term.screen = atPrompt("❯ " + text) }
    /// What Return does to the screen. Default: the message goes and the box empties.
    var onEnter: (FakeTerm) -> Void = { term in term.screen = atPrompt("❯  ") }
    var answer: Reply.Answer?   // set to answer every script the same way (gone, denied…)

    init(_ screen: String) { self.screen = screen }

    func ask(_ source: String) -> Reply.Answer {
        if let a = answer { calls.append(.screen); return a }
        if source.contains("contents of s") {
            calls.append(.screen)
            return Reply.Answer(reply: "ok\n" + screen)
        }
        if source.contains("character id 13") {
            calls.append(.enter)
            onEnter(self)
            return Reply.Answer(reply: "ok")
        }
        // The pasted line: what sits between the paste brackets, un-escaped.
        let body = source.components(separatedBy: "\"[200~\" & \"").last?
            .components(separatedBy: "\" & (character id 27) & \"[201~\"").first ?? ""
        let text = body.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        calls.append(.paste(text))
        onPaste(self, text)
        return Reply.Answer(reply: "ok")
    }

    func send(_ heard: String, to origin: Origin = pane) -> Reply.Outcome {
        Reply.send(heard, to: origin, ask: ask, wait: { _ in self.waits += 1 })
    }
}

private let pane = Origin(term: "iTerm.app", session: "1A2B3C4D-0000-4000-8000-00000000ABCD")

/// A finished Claude Code turn from an iTerm2 pane: the kind you can answer.
private func turn(_ text: String, key: String, answerable: Bool = true, origin: Origin? = pane) -> SpeechItem {
    SpeechItem(text: text, source: key, key: key, created: Date(), file: "/tmp/\(text).taken",
               origin: origin, answerable: answerable)
}

/// A rig that listens, with `texts` queued as turns from sessions named after them, the
/// first one read to its end: the reply window for it is open.
private func listening(_ texts: String...) -> Rig {
    let r = Rig()
    r.playback.listens = true
    for text in texts { r.playback.enqueue(turn(text, key: text.uppercased())) }
    _ = r.voice.take()
    r.voice.finish()
    return r
}

let replySuite = Suite("Reply") { t in
    // -- the words ---------------------------------------------------------

    t.expectEqual(Reply.clean("  Yes,\n go ahead\t now  "), "Yes, go ahead now", "one line, space closed up")
    t.expectEqual(Reply.clean("run\u{1B}[201~ this\u{07}"), "run [201~ this",
                  "no escape or other control character survives: one could end the paste early, or be a key")
    t.expectEqual(Reply.clean("!rm -rf x"), "rm -rf x", "nothing ahead of the first word for the prompt to take as shell mode")
    t.expectEqual(Reply.clean("/clear"), "clear", "…or as a slash command")
    t.expectEqual(Reply.clean("\"quoted\" start"), "\"quoted\" start", "a quote may open it")
    t.expectEqual(Reply.clean("2 retries, please."), "2 retries, please.", "a number may open it")
    t.expect(Reply.clean(" \n ") == nil && Reply.clean("...") == nil, "nothing said is nothing to send")
    t.expectEqual(Reply.clean(String(repeating: "word ", count: 2000))?.count, Reply.maxLength, "a runaway reply is cut off")

    t.expectEqual(SpokenCommand.parse("Say that again."), .again, "a command is heard through its punctuation")
    t.expectEqual(SpokenCommand.parse("remind me again"), .again, "remind me again")
    t.expectEqual(SpokenCommand.parse("Put it off to the end"), .later, "put it off to the end")
    t.expectEqual(SpokenCommand.parse("No reply."), .skip, "no reply")
    t.expectEqual(SpokenCommand.parse("Skip."), .skip, "skip: the short way to say you've nothing to say")
    t.expectEqual(SpokenCommand.parse("skip this part"), .skip, "skip this part")
    for said in ["Clear that.", "clear", "never mind", "Don't send that.", "cancel that",
                 "and that's the weather for today, clear that", "uh run the, no, don't send that"] {
        t.expectEqual(SpokenCommand.parse(said), .scratch, "\"\(said)\" throws away what was heard")
    }
    for said in ["cancel", "clear the cache", "the sky is clear", "never mind the tests, ship it"] {
        t.expect(SpokenCommand.parse(said) == nil, "\"\(said)\" is a reply")
    }
    t.expectEqual(SpokenCommand.parse("Scratch that"), .scratch, "scratch that")
    t.expectEqual(SpokenCommand.parse("run the tests, no wait, scratch that"), .scratch, "scratch that takes back what came before it")
    for said in ["later", "again", "next", "stop", "skip the tests", "do it again", "put it off until the tests pass", ""] {
        t.expect(SpokenCommand.parse(said) == nil, "\"\(said)\" is for Claude, not a command")
    }

    // -- reading the screen ------------------------------------------------

    t.expectEqual(Reply.promptText(in: atPrompt("❯  ")), "", "an empty prompt box, as iTerm2 reports it")
    t.expectEqual(Reply.promptText(in: atPrompt("❯ Try \"edit <filepath> to...\"")), "Try \"edit <filepath> to...\"",
                  "the box's text (a placeholder reads the same as typing)")
    t.expectEqual(Reply.promptText(in: atPrompt("❯ word0 word1 word2", "  word3 word4", "  word5")),
                  "word0 word1 word2 word3 word4 word5", "a wrapped message is joined up")
    t.expectEqual(Reply.promptText(in: atPrompt("❯\u{00A0}hello")), "hello", "a no-break space after the mark is a space")
    t.expect(Reply.promptText(in: questionBox) == nil, "a question box is not a prompt")
    t.expect(Reply.promptText(in: trustBox) == nil, "the trust box is not a prompt")
    t.expect(Reply.promptText(in: screen("Last login: Tue Oct  7", "❯ ls", "TODO.md", "❯ ")) == nil,
             "a shell prompt that happens to use ❯ is not Claude's")
    t.expect(Reply.promptText(in: atPrompt("! ls -la")) == nil, "shell mode: what's pasted there would be run")
    t.expect(Reply.promptText(in: atPrompt("❯ 1. Yes", "  2. No")) == nil, "options between two rules are still options")
    t.expect(Reply.promptText(in: screen(rule, "❯ ", rule, "  status", "Esc to cancel")) == nil,
             "a box that says how to answer it underneath takes keys as answers")
    t.expect(Reply.promptText(in: screen(rule, "❯ quoted earlier", rule, "a", "b", "c", "d", "e", "f")) == nil,
             "a rule with more than a status line or two under it isn't the prompt box")
    t.expect(Reply.promptText(in: "") == nil, "no screen, no prompt")

    t.expect(Reply.shows("blue please", inPrompt: "blue please"), "the paste shows")
    t.expect(Reply.shows("word0 word1 word2 word3", inPrompt: "word0 word1 wo rd2 word3"), "however it wrapped")
    t.expect(Reply.shows(String(repeating: "word ", count: 400), inPrompt: "[Pasted text #1]"), "a long paste shows as Claude's marker")
    t.expect(!Reply.shows("blue please", inPrompt: "half a thought blue please"), "text you'd typed ahead of it: not confirmed")
    t.expect(!Reply.shows("blue please", inPrompt: ""), "an empty box hasn't taken it")
    t.expect(!Reply.shows("blue please", inPrompt: "Try \"edit <filepath> to...\""), "nor has one still showing its placeholder")

    // -- the scripts -------------------------------------------------------

    do {
        let id = pane.session!
        let scripts = [Reply.screenScript(id), Reply.pasteScript(id, "say \"hi\" \\ there"), Reply.returnScript(id)]
        t.expect(scripts.allSatisfy { $0.contains("(id of s) is \"\(id)\"") }, "each script finds the pane by its id")
        t.expect(scripts.allSatisfy { !$0.contains("activate") && !$0.contains("select") },
                 "none brings iTerm2 forward or changes what's selected")
        t.expect(scripts.allSatisfy { $0.hasSuffix("return \"missing\"") }, "a pane that's gone answers missing")
        t.expect(scripts[0].contains("contents of s"), "the screen is the pane's visible text")
        t.expect(scripts[1].contains("(character id 27) & \"[200~\" & \"say \\\"hi\\\" \\\\ there\" & (character id 27) & \"[201~\") newline no"),
                 "the line goes in as a bracketed paste, quoted for AppleScript, with no Return")
        t.expect(scripts[2].contains("write text (character id 13) newline no"), "Return is a carriage return, sent alone")
    }

    // -- the exchange with iTerm2 ------------------------------------------

    do {  // at its prompt: paste, see it there, Return
        let term = FakeTerm(atPrompt("❯  "))
        t.expectEqual(term.send("blue,\nplease"), .sent, "a reply to a pane at its prompt is sent")
        t.expectEqual(term.calls, [.screen, .paste("blue, please"), .screen, .enter, .screen],
                      "screen first, then the paste, then Return only once it shows, then a look to see it gone")
    }
    do {  // Return didn't take: the words are still in the box
        let term = FakeTerm(atPrompt("❯  "))
        term.onEnter = { _ in }
        t.expectEqual(term.send("blue please"), .unconfirmed, "a reply still sitting in the box after Return is not called sent")
        t.expectEqual(term.calls.filter { $0 == .enter }.count, 1, "and Return isn't pressed twice")
    }
    do {  // Return was answered by a box: the message went, the screen has moved on
        let term = FakeTerm(atPrompt("❯  "))
        term.onEnter = { term in term.screen = questionBox }
        t.expectEqual(term.send("blue please"), .sent, "a screen that has moved on has taken the message")
    }
    do {  // a question box is up: nothing is pasted
        let term = FakeTerm(questionBox)
        t.expectEqual(term.send("2"), .notAtPrompt, "a pane showing a question box is left alone")
        t.expectEqual(term.calls, [.screen], "nothing is written to it at all")
    }
    do {  // the paste never shows: Return is not pressed
        let term = FakeTerm(atPrompt("❯  "))
        term.onPaste = { _, _ in }
        t.expectEqual(term.send("blue please"), .unconfirmed, "a paste that never shows is not followed by Return")
        t.expect(!term.calls.contains(.enter), "no Return")
        t.expectEqual(term.calls.filter { $0 == .screen }.count, 1 + Reply.looks, "it looked \(Reply.looks) more times first")
        t.expectEqual(term.waits, Reply.looks, "waiting between looks")
    }
    do {  // the paste shows late
        let term = FakeTerm(atPrompt("❯  "))
        term.onPaste = { _, _ in }
        var looks = 0
        let outcome = Reply.send("blue please", to: pane, ask: { source in
            if source.contains("contents of s") {
                looks += 1
                if looks == 4 { term.screen = atPrompt("❯ blue please") }
            }
            return term.ask(source)
        }, wait: { _ in })
        t.expectEqual(outcome, .sent, "a paste that takes a moment to show is still sent")
    }
    do {  // you'd typed something there already
        let term = FakeTerm(atPrompt("❯ half a thought"))
        term.onPaste = { term, text in term.screen = atPrompt("❯ half a thought" + text) }
        t.expectEqual(term.send("blue please"), .unconfirmed, "a reply that landed after your own typing isn't sent for you")
        t.expect(!term.calls.contains(.enter), "no Return")
    }
    do {  // the question box opens between the look and the paste
        let term = FakeTerm(atPrompt("❯  "))
        term.onPaste = { term, _ in term.screen = questionBox }
        t.expectEqual(term.send("2"), .unconfirmed, "a box that opened under the paste gets no Return")
        t.expect(!term.calls.contains(.enter), "no Return")
    }
    do {  // gone, refused, broken
        let gone = FakeTerm(""); gone.answer = Reply.Answer(reply: "missing")
        t.expectEqual(gone.send("hi"), .gone, "a pane that has closed")
        let denied = FakeTerm(""); denied.answer = Reply.Answer(errorCode: -1743)
        t.expectEqual(denied.send("hi"), .denied, "Automation permission refused")
        let broken = FakeTerm(""); broken.answer = Reply.Answer(errorCode: -1728, errorMessage: "Can't get session.")
        t.expectEqual(broken.send("hi"), .failed("Can't get session."), "any other AppleScript error, in its own words")
        let term = FakeTerm(atPrompt("❯  "))
        t.expectEqual(term.send("hi", to: Origin(term: "Apple_Terminal", tty: "/dev/ttys009")), .gone, "Terminal.app can't be answered")
        t.expectEqual(term.send("hi", to: Origin(appPID: 321)), .gone, "nor can an app with no pane")
        t.expectEqual(term.send(" \n "), .failed("nothing to send"), "nothing said")
        t.expectEqual(term.calls, [], "none of those touched iTerm2")
    }
    t.expect(Reply.canReach(pane) && Reply.canReach(Origin(session: pane.session)), "an iTerm2 pane can be answered")
    t.expect(!Reply.canReach(nil) && !Reply.canReach(Origin(term: "vscode", session: pane.session)), "nothing else can")

    // -- the reply window --------------------------------------------------

    do {  // off: nothing changes
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a", key: "A")); p.enqueue(turn("b", key: "B"))
        _ = r.voice.take()
        r.voice.finish()
        t.expectEqual(r.ear.take(), [], "off: the mic is never opened")
        t.expectEqual(r.voice.take(), [.speak("b", from: 0, rate: Playback.rateSteps[1])], "off: the next item starts as it always did")
    }

    do {  // on: the mic opens when an answerable turn ends, and everything waits
        let r = listening("a", "b"), p = r.playback!
        t.expectEqual(r.ear.take(), [.listen(1)], "the mic opens when the turn has been read")
        t.expectEqual(r.listened, ["a"], "the HUD is told whose turn it is")
        t.expectEqual(r.voice.take(), [], "the next item waits for you")
        t.expect(p.current == nil && p.queue.map(\.text) == ["b"], "it stays in line")
        t.expectEqual(p.state.status, "🎙 Listening: answer A, or say nothing", "the HUD says it's listening, and to whom you'd be talking")
        t.expect(p.state.isActive && p.state.canSkip, "the HUD stays up, and Skip is live")
        t.expectEqual(p.state.heard, "", "nothing heard yet")
        t.expectEqual(r.armed?.seconds, Playback.replyWait, "you have \(Int(Playback.replyWait))s to start")

        // Say nothing: it shuts by itself and moves on.
        r.fire()
        t.expectEqual(r.ear.take(), [.stop], "silence shuts the mic")
        t.expectEqual(r.voice.take(), [.speak("b", from: 0, rate: Playback.rateSteps[1])], "…and the next item starts")
        t.expect(r.sent.isEmpty && r.replied.isEmpty, "nothing was sent")
        t.expect(p.state.heard == nil, "nothing is left on screen")
    }

    do {  // a real mic takes a moment to open: your time starts when it has
        let r = Rig(), p = r.playback!
        r.ear.opensAtOnce = false
        p.listens = true
        p.enqueue(turn("a", key: "A")); p.enqueue(turn("b", key: "B"))
        _ = r.voice.take()
        r.voice.finish()
        t.expectEqual(r.ear.take(), [.listen(1)], "the mic is asked for")
        t.expectEqual(p.state.status, "🎙 Opening the mic…", "the HUD says it's opening")
        t.expectEqual(r.listened, [], "no \"your turn\" yet")
        t.expectEqual(r.armed?.seconds, Playback.replyWait + Playback.micOpenLimit, "only a limit on how long it may take")
        r.ear.open()
        t.expectEqual(r.listened, ["a"], "open: now it's your turn")
        t.expectEqual(p.state.status, "🎙 Listening: answer A, or say nothing", "and the HUD says so")
        t.expectEqual(r.armed?.seconds, Playback.replyWait, "with the full \(Int(Playback.replyWait))s to start")
        r.ear.open()
        t.expectEqual(r.listened, ["a"], "a second \"open\" is not a second turn")

        let s = Rig(), q = s.playback!
        s.ear.opensAtOnce = false
        q.listens = true
        q.enqueue(turn("a", key: "A")); q.enqueue(turn("b", key: "B"))
        _ = s.voice.take()
        s.voice.finish()
        _ = s.ear.take()
        s.fire()
        t.expectEqual(s.ear.take(), [.stop], "a mic that never opens is given up on")
        t.expectEqual(q.current?.text, "b", "and the queue moves")
        t.expect(s.listened.isEmpty && s.sent.isEmpty, "with no turn offered and nothing sent")
    }

    do {  // a reply: heard, settled, shown as sending, sent
        let r = listening("a", "b"), p = r.playback!
        _ = r.ear.take()
        r.ear.hear("yes")
        t.expectEqual(p.state.status, "🎙 Listening… “clear that” takes it back", "words arriving, and the way out")
        t.expectEqual(p.state.heard, "yes", "the HUD shows what's been heard")
        let pause = r.armed
        t.expectEqual(pause?.seconds, Playback.replyPause, "a pause of \(Playback.replyPause)s ends it")
        r.ear.hear("Yes.")
        t.expect(r.armed === pause, "the same words re-punctuated don't restart the pause")
        t.expectEqual(p.state.heard, "Yes.", "…though the HUD takes the tidier text")
        r.ear.hear("Yes, go ahead")
        t.expect(r.armed !== pause && pause?.cancelled == true, "more words do")

        r.fire()   // the pause runs out
        t.expectEqual(p.state.status, "➤ Sending to A… “clear that” stops it", "it shows as sending first")
        t.expectEqual(r.armed?.seconds, Playback.replyGrace, "for \(Playback.replyGrace)s")
        t.expect(r.sent.isEmpty, "nothing sent yet")
        r.ear.hear("Yes, go ahead and commit")
        t.expectEqual(p.state.status, "🎙 Listening… “clear that” takes it back", "saying more takes it back to listening")
        r.fire(); r.fire()   // pause, then grace
        t.expectEqual(r.sent.map(\.text), ["Yes, go ahead and commit"], "then what you said is sent")
        t.expectEqual(r.sent.map(\.to), ["A"], "to the terminal whose turn it was")
        t.expectEqual(r.replied, [.sent], "the HUD hears how it went")
        t.expectEqual(r.ear.take(), [.stop], "the mic is shut")
        t.expectEqual(r.voice.take(), [.speak("b", from: 0, rate: Playback.rateSteps[1])], "and the next item starts")
        t.expect(r.armed == nil, "no timer is left running")
    }

    do {  // sent with nothing waiting: the HUD keeps saying so
        let r = listening("a"), p = r.playback!
        r.ear.hear("line one\nline two")
        r.fire(); r.fire()
        t.expectEqual(r.sent.map(\.text), ["line one line two"], "what's sent is the cleaned line")
        t.expectEqual(p.state.status, "✓ Sent to A", "the status says it went")
        t.expectEqual(p.state.heard, "line one line two", "and what went stays on screen")
        t.expect(!p.state.isActive, "idle again, so the HUD may hide")
        t.expectEqual(r.ranDry, 1, "ran dry once the window shut")
        p.enqueue(turn("c", key: "C", answerable: false))
        t.expect(p.state.heard == nil, "the next item clears it")
    }

    do {  // it didn't arrive
        let r = listening("a"), p = r.playback!
        r.delivery = .notAtPrompt
        r.ear.hear("blue please")
        r.fire(); r.fire()
        t.expectEqual(r.replied, [.notAtPrompt], "the HUD hears it didn't go")
        t.expectEqual(p.state.status, "✗ Not sent: its terminal isn't at Claude's prompt", "and says why")
        t.expectEqual(p.state.heard, "blue please", "what you said isn't lost")
    }

    // -- commands ----------------------------------------------------------

    do {  // "say that again"
        let r = listening("a", "b")
        _ = r.ear.take()
        r.ear.hear("Say that again.")
        r.fire()
        t.expectEqual(r.ear.take(), [.stop], "again: the mic shuts")
        t.expectEqual(r.voice.take(), [.speak("a", from: 0, rate: Playback.rateSteps[1])], "…and the turn is read from the top")
        t.expect(r.sent.isEmpty, "nothing goes to Claude")
        r.voice.finish()
        t.expectEqual(r.ear.take(), [.listen(2)], "and you're asked again after it")
    }

    do {  // "put it off": to the end of the line
        let r = listening("a", "b", "c"), p = r.playback!
        r.ear.hear("put it off to the end")
        r.fire()
        t.expect(r.sent.isEmpty, "later: nothing goes to Claude")
        t.expectEqual(p.current?.text, "b", "the next item starts")
        t.expectEqual(p.queue.map(\.text), ["c", "a"], "and the turn waits at the end of the line")
        t.expect(p.queue.last?.file == nil && p.queue.last?.answerable == true, "without its spool file, still answerable")
    }

    do {  // "put it off" with no line: it waits for the next thing to arrive
        let r = listening("a"), p = r.playback!
        r.ear.hear("remind me later")
        r.fire()
        t.expect(p.current == nil && p.queue.isEmpty, "nothing to read now")
        t.expectEqual(p.state.putOff, 1, "the HUD counts it")
        t.expectEqual(p.state.status, "⏳ Put off to the end", "and says so")
        _ = r.voice.take()
        p.enqueue(turn("b", key: "B", answerable: false))
        t.expectEqual(r.voice.take(), [.speak("b", from: 0, rate: Playback.rateSteps[1])], "the next arrival is read first")
        t.expectEqual(p.queue.map(\.text), ["a"], "with the put-off turn behind it")
        t.expectEqual(p.state.putOff, 0, "no longer put off")
    }

    do {  // put off, then its own session says something newer
        let r = listening("a"), p = r.playback!
        r.ear.hear("put it off")
        r.fire()
        p.enqueue(turn("a2", key: "A"))
        t.expectEqual(p.current?.text, "a2", "the newer turn is read")
        t.expect(p.queue.isEmpty, "and the one put off is dropped: newest per session wins")
    }

    do {  // "no reply" and "scratch that"
        let r = listening("a", "b")
        _ = r.ear.take()
        r.ear.hear("no reply")
        r.fire()
        t.expectEqual(r.ear.take(), [.stop], "no reply: the mic shuts at once")
        t.expectEqual(r.voice.take(), [.speak("b", from: 0, rate: Playback.rateSteps[1])], "and the next item starts")
        t.expect(r.sent.isEmpty, "nothing sent")

        let k = listening("a", "b")
        k.ear.hear("Skip.")
        k.fire()
        t.expectEqual(k.playback.current?.text, "b", "skip: the same, in one word")
        t.expect(k.sent.isEmpty && k.replied.isEmpty, "and \"skip\" isn't sent to Claude")

        let s = listening("a"), p = s.playback!
        _ = s.ear.take()
        s.ear.hear("delete the whole thing, no, scratch that")
        s.fire()
        t.expectEqual(s.ear.take(), [.listen(2)], "scratch that: a fresh window")
        t.expectEqual(p.state.heard, "", "with nothing heard")
        t.expectEqual(s.armed?.seconds, Playback.replyRetry, "and \(Int(Playback.replyRetry))s to say it again")
        t.expectEqual(p.state.status, "🎙 Cleared. Say it again, or say nothing", "the HUD says it's wiped and still listening")
        t.expectEqual(s.listened, ["a", "a"], "with a second \"your turn\"")
        s.ear.hear("delete the whole thing", window: 1)
        t.expectEqual(p.state.heard, "", "the old window's words are stale")
        s.ear.hear("keep it")
        s.fire(); s.fire()
        t.expectEqual(s.sent.map(\.text), ["keep it"], "only what came after is sent")
    }

    // -- when it doesn't open ----------------------------------------------

    do {
        func opens(_ item: SpeechItem, then setup: (Rig) -> Void = { _ in }) -> Bool {
            let r = Rig()
            r.playback.listens = true
            r.playback.enqueue(item)
            setup(r)
            r.voice.finish()
            return !r.ear.take().isEmpty
        }
        t.expect(opens(turn("a", key: "A")), "an answerable turn from an iTerm2 pane opens it")
        t.expect(!opens(turn("a", key: "A", answerable: false)), "a question, or anything else not marked answerable, doesn't")
        t.expect(!opens(turn("a", key: "A", origin: Origin(term: "Apple_Terminal", tty: "/dev/ttys009"))),
                 "nor a turn from a terminal that can't be written to")
        t.expect(!opens(turn("a", key: "A", origin: nil)), "nor one from nowhere")
        t.expect(!opens(turn("a", key: "A")) { $0.playback.enqueue(turn("a2", key: "A")) },
                 "nor a turn whose session already has a newer one waiting")
        t.expect(!opens(turn("a", key: "A")) { $0.playback.micChanged(busy: true) },
                 "nor while another app has the mic: you're already answering with a key held")
    }

    // -- when something else happens meanwhile -----------------------------

    do {  // another app takes the mic: you're answering with a key
        let r = listening("a", "b"), p = r.playback!
        _ = r.ear.take()
        r.ear.hear("half a sen")
        p.micChanged(busy: true)
        t.expectEqual(r.ear.take(), [.stop], "the window shuts")
        t.expect(r.armed == nil && r.sent.isEmpty, "nothing will be sent")
        t.expectEqual(p.current?.text, "b", "the next item is up")
        t.expectEqual(r.voice.take(), [], "but silent while the mic is busy")
        p.micChanged(busy: false)
        t.expectEqual(r.voice.take(), [.speak("b", from: 0, rate: Playback.rateSteps[1])], "it speaks when the mic frees up")
    }

    do {  // a turn arriving doesn't talk over you
        let r = listening("a"), p = r.playback!
        t.expect(!p.enqueue(turn("b", key: "B")), "a turn that arrives while you may be speaking waits")
        t.expectEqual(r.voice.take(), [], "silently")
        t.expectEqual(p.state.queued, ["B"], "in line")
        r.fire()
        t.expectEqual(r.voice.take(), [.speak("b", from: 0, rate: Playback.rateSteps[1])], "until the window shuts")
    }

    do {  // the buttons and keys
        var r = listening("a", "b")
        _ = r.ear.take()
        r.playback.skip()
        t.expectEqual(r.ear.take(), [.stop], "Skip shuts the window")
        t.expectEqual(r.playback.current?.text, "b", "and moves on")
        t.expect(r.sent.isEmpty, "sending nothing")

        r = listening("a", "b")
        r.ear.hear("send this"); r.fire()   // showing as "sending"
        r.playback.skip()
        r.fire()
        t.expect(r.sent.isEmpty, "Skip while it shows as sending takes it back")

        r = listening("a", "b")
        t.expectEqual(r.playback.state.pauseTitle, "✕ Close", "while it listens with nothing heard, the Pause button is Close")
        r.playback.togglePause()
        t.expectEqual(r.playback.current?.text, "b", "and it, or its key, shuts the mic and moves on")
        t.expectEqual(r.playback.state.pauseTitle, "❚❚ Pause", "where the button is Pause again, and nothing is paused")

        r = listening("a", "b")
        _ = r.ear.take(); _ = r.voice.take()
        r.ear.hear("something the room said"); r.fire()   // showing as "sending"
        t.expectEqual(r.playback.state.pauseTitle, "✕ Clear", "with something heard it's Clear, right up until it's sent")
        r.playback.togglePause()
        t.expect(r.sent.isEmpty && r.replied.isEmpty, "Clear throws away what was heard: nothing is sent")
        t.expectEqual(r.ear.take(), [.listen(2)], "and it listens again, afresh")
        t.expectEqual(r.playback.state.heard, "", "with nothing heard")
        t.expectEqual(r.armed?.seconds, Playback.replyRetry, "for \(Int(Playback.replyRetry))s, in case you want to say it properly")
        t.expectEqual(r.voice.take(), [], "nothing else is read meanwhile")
        r.ear.hear("what I meant"); r.fire(); r.fire()
        t.expectEqual(r.sent.map(\.text), ["what I meant"], "say it again and that's what's sent")

        r = listening("a", "b")
        r.ear.hear("something the room said")
        r.playback.togglePause()   // Clear
        t.expectEqual(r.playback.state.pauseTitle, "✕ Close", "cleared: the button is Close again")
        r.fire()                   // …and nothing more is said
        t.expectEqual(r.playback.current?.text, "b", "say nothing after a Clear and it shuts by itself and moves on")
        t.expect(r.sent.isEmpty, "with nothing sent")

        r = listening("a", "b")
        r.ear.hear("something the room said")
        r.playback.togglePause(); r.playback.togglePause()   // Clear, then Close
        t.expectEqual(r.playback.current?.text, "b", "Clear twice shuts it at once")

        r = listening("a", "b")
        _ = r.ear.take()
        r.ear.hear("and that's the weather for today")
        r.fire()   // "sending"
        r.ear.hear("and that's the weather for today clear that")
        r.fire()
        t.expect(r.sent.isEmpty, "\"clear that\", said while it shows as sending, stops it")
        t.expectEqual(r.ear.take(), [.listen(2)], "and it listens again")
        t.expect(r.playback.current == nil, "holding the next turn back a little longer")

        r = listening("a", "b")
        _ = r.ear.take(); _ = r.voice.take()
        r.playback.replay()
        t.expectEqual(r.ear.take(), [.stop], "Replay shuts the window")
        t.expectEqual(r.voice.take(), [.speak("a", from: 0, rate: Playback.rateSteps[1])], "and reads the turn again")

        r = listening("a", "b")
        r.playback.stop()
        t.expect(r.armed == nil && r.playback.queue.isEmpty && r.playback.state.heard == nil, "Stop shuts it and empties the line")
        t.expectEqual(r.stopped, 1, "as Stop does")

        r = listening("a", "b")
        _ = r.ear.take(); _ = r.voice.take()
        r.playback.playNow(SpeechItem(text: "read me", source: "Selection", key: "x", created: Date()))
        t.expectEqual(r.ear.take(), [.stop], "a hotkey read shuts the window")
        t.expectEqual(r.voice.take(), [.speak("read me", from: 0, rate: Playback.rateSteps[1])], "and is read now")

        r = listening("a", "b")
        r.playback.listens = false
        t.expectEqual(r.playback.current?.text, "b", "switching it off shuts the window and moves on")
    }

    do {  // the mic can't be opened
        let r = listening("a", "b"), p = r.playback!
        r.ear.fail("no microphone")
        t.expectEqual(r.earFailures, ["no microphone"], "the HUD hears why")
        t.expectEqual(p.current?.text, "b", "and the queue isn't held up")
        t.expect(r.sent.isEmpty, "nothing is sent")

        let s = listening("a")
        s.ear.fail("no microphone")
        t.expectEqual(s.playback.state.status, "✗ Can't listen: no microphone", "with nothing else to read, the status says why")
    }

    do {  // nothing from a shut window counts
        let r = listening("a", "b"), p = r.playback!
        r.fire()   // nothing said: shut
        r.ear.hear("too late")
        t.expect(p.state.heard == nil && r.armed == nil, "words after it shut are ignored")
        t.expect(r.sent.isEmpty, "and never sent")
    }
}
