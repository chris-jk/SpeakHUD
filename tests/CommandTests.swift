// Command tests. Registered in tests/main.swift.
//
// Listen While Reading: what counts as a command while a turn is being read
// (SpokenCommand), when the mic is open for them, and what each one does (Playback on a
// fake voice and a fake mic, its timers fired by hand).
import Foundation

private let r1: Float = Playback.rateSteps[1]
private let pane = Origin(term: "iTerm.app", session: "1A2B3C4D-0000-4000-8000-00000000ABCD")

private func turn(_ text: String, key: String, answerable: Bool = false) -> SpeechItem {
    SpeechItem(text: text, source: key, key: key, created: Date(), file: "/tmp/\(key).taken",
               origin: pane, answerable: answerable)
}

/// A rig that obeys, with `texts` queued as turns from sessions A, B, C… and the first
/// one being read.
private func reading(_ texts: String...) -> Rig {
    let r = Rig()
    r.playback.obeys = true
    for (i, text) in texts.enumerated() { r.playback.enqueue(turn(text, key: String(UnicodeScalar(UInt8(65 + i))))) }
    _ = r.voice.take()
    return r
}

/// The mic hears `everything` (all that's been said since it opened), then it goes quiet.
private func say(_ r: Rig, _ everything: String) {
    r.ear.hear(everything)
    r.fire(Playback.commandPause)
}

let commandSuite = Suite("Commands") { t in
    // -- what counts -------------------------------------------------------

    let said: [(String, SpokenCommand)] = [
        ("skip", .skip), ("Skip.", .skip), ("next", .skip), ("skip this one", .skip), ("move on", .skip),
        ("again", .again), ("repeat", .again), ("start over", .again), ("Say that again.", .again),
        ("remind me again", .again),
        ("later", .later), ("not now", .later), ("put it off to the end", .later), ("ask me later", .later),
        ("pause", .pause), ("stop", .pause), ("wait", .pause), ("hold on", .pause),
        ("go on", .resume), ("continue", .resume), ("keep going", .resume),
        ("stop everything", .stopAll), ("clear the queue", .stopAll),
        ("Okay, skip.", .skip), ("skip, please", .skip), ("um later", .later),
    ]
    for (phrase, command) in said {
        t.expectEqual(SpokenCommand.parse(phrase, whileReading: true), command, "while reading, \"\(phrase)\"")
    }
    for phrase in ["skip the tests", "what's next", "stop it right there", "okay", "no reply", "scratch that",
                   "later on we should skip", ""] {
        t.expect(SpokenCommand.parse(phrase, whileReading: true) == nil, "while reading, \"\(phrase)\" is not a command")
    }
    for phrase in ["later", "again", "next", "stop", "pause", "go on", "stop everything"] {
        t.expect(SpokenCommand.parse(phrase) == nil, "in a reply window \"\(phrase)\" is still for Claude")
    }
    t.expectEqual(SpokenCommand.parse("start over"), .scratch, "and \"start over\" still takes back what you said there")

    // -- when the mic is open ----------------------------------------------

    do {  // off: never
        let r = Rig(), p = r.playback!
        p.enqueue(turn("a", key: "A"))
        t.expectEqual(r.ear.take(), [], "off: the mic stays shut while reading")
        t.expect(!p.state.listening, "and the HUD doesn't say otherwise")
        t.expectEqual(p.state.status, "🔊 Speaking…  1×", "the status is as it was")
    }

    do {  // on: open for as long as there's reading to do
        let r = Rig(), p = r.playback!
        p.obeys = true
        t.expectEqual(r.ear.take(), [], "on with nothing to read: still shut")
        p.enqueue(turn("a", key: "A")); p.enqueue(turn("b", key: "B"))
        t.expectEqual(r.ear.take(), [.attend(1)], "it opens, over the voice, when reading starts")
        t.expect(p.state.listening, "the HUD knows")
        t.expectEqual(p.state.status, "🔊 Speaking…  1×   🎙 again · later · skip · pause", "and says what you can say")
        r.voice.finish()
        t.expectEqual(p.current?.text, "b", "the next turn is read")
        t.expectEqual(r.ear.take(), [], "on the same open mic: it isn't shut and reopened between turns")
        r.voice.finish()
        t.expectEqual(r.ear.take(), [.stop], "it shuts when there's nothing left to read")
        t.expect(!p.state.listening, "and the HUD knows that too")
    }

    do {  // things that take the mic away, and give it back
        let r = reading("a", "b"), p = r.playback!
        _ = r.ear.take()
        p.micChanged(busy: true)
        t.expectEqual(r.ear.take(), [.stop], "another app recording: ours shuts, so your dictation isn't taken for commands")
        p.micChanged(busy: false)
        t.expectEqual(r.ear.take(), [.attend(2)], "and reopens when it's done")

        p.togglePause()
        t.expectEqual(r.ear.take(), [.stop], "paused by key or button: shut (your hands are on it)")
        t.expectEqual(p.state.status, "⏸ Paused", "an ordinary pause")
        p.togglePause()
        t.expectEqual(r.ear.take(), [.attend(3)], "resumed: open again")

        p.obeys = false
        t.expectEqual(r.ear.take(), [.stop], "switched off mid-turn: shut at once")
        p.obeys = true
        t.expectEqual(r.ear.take(), [.attend(4)], "switched back on: open")

        p.stop()
        t.expectEqual(r.ear.take(), [.stop], "Stop shuts it")
    }

    do {  // a reply window takes the mic over, and hands it back
        let r = Rig(), p = r.playback!
        p.obeys = true; p.listens = true
        p.enqueue(turn("a", key: "A", answerable: true)); p.enqueue(turn("b", key: "B"))
        _ = r.voice.take(); _ = r.ear.take()
        r.voice.finish()
        t.expectEqual(r.ear.take(), [.attend(2)], "the turn ends: the mic is reopened for the reply, on the same kind of mic")
        t.expect(!p.state.listening, "commands are off while you answer")
        r.ear.hear("later")
        r.fire(Playback.commandPause)
        t.expect(r.commands.isEmpty, "\"later\" said in the window is a reply, not a command")
        r.fire(Playback.replyPause); r.fire(Playback.replyGrace)
        t.expectEqual(r.sent.map(\.text), ["later"], "and is sent")
        t.expectEqual(r.ear.take(), [.stop, .attend(3)], "then the mic goes back to commands for the next turn")
        t.expectEqual(p.current?.text, "b", "which is being read")
    }

    // -- what they do ------------------------------------------------------

    do {  // skip
        let r = reading("a", "b"), p = r.playback!
        r.ear.hear("skip")
        t.expectEqual(r.voice.take(), [], "nothing happens until it's gone quiet after the word")
        t.expectEqual(r.armed?.seconds, Playback.commandPause, "\(Playback.commandPause)s of quiet")
        r.fire()
        t.expectEqual(r.commands, [.skip], "then the HUD is told what was heard")
        t.expectEqual(r.voice.take(), [.stop, .speak("b", from: 0, rate: r1)], "skip: the turn is dropped and the next one read")
        t.expectEqual(r.retired, ["a"], "for good")
        t.expect(r.logs.contains("heard \"skip\""), "and the log says what it heard")
    }

    do {  // again
        let r = reading("one two three four", "b")
        r.voice.word(at: 8)
        say(r, "again")
        t.expectEqual(r.voice.take(), [.stop, .speak("one two three four", from: 0, rate: r1)], "again: from the top")
        t.expect(r.retired.isEmpty, "nothing is dropped")
    }

    do {  // later, with a line
        let r = reading("a", "b", "c"), p = r.playback!
        say(r, "later")
        t.expectEqual(p.current?.text, "b", "later: the next turn is read")
        t.expectEqual(p.queue.map(\.text), ["c", "a"], "and this one goes to the back of the line")
        t.expect(r.retired.isEmpty && p.queue.last?.file != nil, "keeping its spool file: it hasn't been heard out")
    }

    do {  // later, with no line
        let r = reading("a"), p = r.playback!
        _ = r.ear.take()
        say(r, "put it off")
        t.expect(p.current == nil && p.queue.isEmpty, "later with nothing else waiting: silence")
        t.expectEqual(p.state.putOff, 1, "the turn is kept")
        t.expectEqual(p.state.status, "⏳ Put off to the end", "and the HUD says so")
        t.expectEqual(r.ear.take(), [.stop], "the mic shuts: nothing is being read")
        t.expect(r.retired.isEmpty, "its file stays")
        p.enqueue(turn("b", key: "B"))
        t.expectEqual(p.current?.text, "b", "the next arrival is read first")
        t.expectEqual(p.queue.map(\.text), ["a"], "with the put-off turn behind it")
    }

    do {  // a put-off turn's file is let go when the turn is
        let r = reading("a"), p = r.playback!
        say(r, "later")
        p.stop()
        t.expectEqual(r.retired, ["a"], "Stop lets go of a put-off turn's file")

        let s = reading("a"), q = s.playback!
        say(s, "later")
        q.enqueue(turn("a2", key: "A"))
        t.expectEqual(s.retired, ["a"], "so does a newer turn from its own session")
        t.expectEqual(q.current?.text, "a2", "which is the one read")

        let u = reading("a", "b"), v = u.playback!
        v.enqueue(turn("a2", key: "A"))
        say(u, "later")
        t.expectEqual(u.retired, ["a"], "put off with a newer turn of its own already waiting: dropped instead")
        t.expectEqual(v.queue.map(\.text), ["a2"], "newest per session wins")
    }

    do {  // pause and go on
        let r = reading("a", "b"), p = r.playback!
        _ = r.ear.take()
        say(r, "stop")
        t.expectEqual(r.voice.take(), [.pause(immediately: false)], "\"stop\" is a pause")
        t.expectEqual(r.stopped, 0, "nothing is thrown away")
        t.expectEqual(p.state.status, "⏸ Paused: say “go on”", "the HUD says how to carry on")
        t.expectEqual(r.ear.take(), [], "the mic stays open for that")
        say(r, "stop go on")
        t.expectEqual(r.voice.take(), [.resume], "\"go on\" carries on, from where it was")
        t.expectEqual(r.commands, [.pause, .resume], "two commands, the second taken from where the first ended")
        say(r, "stop go on go on")
        t.expectEqual(r.voice.take(), [], "\"go on\" with nothing paused does nothing")
    }

    do {  // a voice pause doesn't keep the mic open for ever
        let r = reading("a"), p = r.playback!
        _ = r.ear.take()
        say(r, "pause")
        r.fire(Playback.pausedListen)
        t.expectEqual(r.ear.take(), [.stop], "after \(Int(Playback.pausedListen))s paused, the mic shuts")
        t.expectEqual(p.state.status, "⏸ Paused", "still paused; a key resumes it")
        p.togglePause()
        t.expectEqual(r.voice.take().last, .resume, "and does")

        let s = reading("a")
        _ = s.ear.take()
        say(s, "pause")
        s.playback.togglePause()   // resumed by key
        s.playback.togglePause()   // paused by key
        t.expectEqual(s.ear.take(), [.stop], "paused again by key: the mic shuts, voice pause or not")
    }

    do {  // a voice pause that ends some other way leaves nothing behind
        for (ending, how) in [("pause skip", "skip"), ("pause later", "later"), ("pause go on", "go on")] {
            let r = reading("a", "b", "c")
            say(r, "pause")
            say(r, ending)
            let waiting = r.timers.filter { $0.seconds == Playback.pausedListen && !$0.cancelled && !$0.fired }
            t.expect(waiting.isEmpty, "after \"pause\" then \"\(how)\", the minute's wait for \"go on\" is called off")
        }
    }

    do {  // again while paused is asking for sound
        let r = reading("one two three")
        say(r, "wait")
        _ = r.voice.take()
        say(r, "wait again")
        t.expectEqual(r.voice.take(), [.stop, .speak("one two three", from: 0, rate: r1)], "again while paused: read from the top, aloud")
    }

    do {  // stop everything
        let r = reading("a", "b", "c"), p = r.playback!
        say(r, "stop everything")
        t.expect(p.current == nil && p.queue.isEmpty, "stop everything: the queue is thrown away")
        t.expectEqual(r.stopped, 1, "as the Stop button does")
    }

    // -- what isn't a command ------------------------------------------------

    do {  // only a phrase on its own
        let r = reading("a", "b"), p = r.playback!
        say(r, "I think we should skip the tests")
        t.expect(r.commands.isEmpty && p.current?.text == "a", "a command word inside a sentence does nothing")
        say(r, "I think we should skip the tests skip")
        t.expectEqual(r.commands, [.skip], "said on its own after that, it does")
    }

    do {  // the transcriber changes its mind about what came before
        let r = reading("a", "b"), p = r.playback!
        say(r, "the cat")
        say(r, "a cat skip")
        t.expect(r.commands.isEmpty && p.current?.text == "a", "words that changed under the phrase make it all one phrase: no command")
        say(r, "a cat skip skip")
        t.expectEqual(r.commands, [.skip], "say it again and it's heard")
    }

    do {  // the voice's own words
        let text = "First run the build, then skip the slow tests and move on to the release notes."
        let at = (text as NSString).range(of: "slow").location
        let r = Rig(), p = r.playback!
        p.obeys = true
        p.enqueue(turn(text, key: "A")); p.enqueue(turn("b", key: "B"))
        _ = r.voice.take()
        r.voice.word(at: at)
        say(r, "skip")
        t.expect(r.commands.isEmpty && p.current?.text == text, "\"skip\" heard just after the voice said it is the voice: ignored")
        t.expect(r.logs.contains("ignored \"skip\": the voice had just said it"), "and logged as that")
        say(r, "skip move on")
        t.expect(r.commands.isEmpty, "\"move on\", which it's about to say, likewise")
        say(r, "skip move on later")
        t.expectEqual(r.commands, [.later], "a word it hasn't said is you")

        let long = "Skip nothing. " + String(repeating: "Plenty of other words follow here. ", count: 12) + "The end."
        let s = Rig(), q = s.playback!
        q.obeys = true
        q.enqueue(turn(long, key: "A")); q.enqueue(turn("b", key: "B"))
        s.voice.word(at: (long as NSString).range(of: "The end").location)
        say(s, "skip")
        t.expectEqual(s.commands, [.skip], "a word the voice said a long while back is you too")

        let paused = Rig(), u = paused.playback!
        u.obeys = true
        u.enqueue(turn("then pause here", key: "A"))
        say(paused, "pause")   // the voice has not got that far; position 0 reaches "pause"
        t.expect(paused.commands.isEmpty, "the reach includes what it's just about to say")
    }

    do {  // your dictation key cuts a half-heard command off
        let r = reading("a", "b"), p = r.playback!
        r.ear.hear("skip")
        p.micChanged(busy: true)
        r.fire(Playback.commandPause)
        t.expect(r.commands.isEmpty && p.current?.text == "a", "a word caught as another app took the mic is never obeyed")
    }

    do {  // a mic that won't open
        let r = reading("a", "b"), p = r.playback!
        _ = r.ear.take(); _ = r.voice.take()
        r.ear.fail("echo cancelling wouldn't start")
        t.expectEqual(r.ear.take(), [.stop], "a mic that fails is let go")
        t.expect(!p.state.listening, "the HUD stops offering commands")
        t.expectEqual(r.voice.take(), [], "and the reading carries on")
        t.expect(r.earFailures.isEmpty, "without a fuss: that's for replies")
        t.expect(r.logs.contains("can't listen for commands: echo cancelling wouldn't start"), "the log has why")
        r.voice.finish()
        t.expectEqual(r.ear.take(), [.attend(2)], "the next turn tries again")
    }

    do {  // nothing from a mic that's been shut
        let r = reading("a", "b"), p = r.playback!
        p.micChanged(busy: true); p.micChanged(busy: false)   // window 1 shut, 2 open
        r.ear.hear("skip", window: 1)
        r.fire(Playback.commandPause)
        t.expect(r.commands.isEmpty && p.current?.text == "a", "words from a mic that's since been shut are stale")
    }
}
