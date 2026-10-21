import Foundation

/// The few things said that are for the HUD and not for Claude.
///
/// In a reply window, whole phrases only, and ones you wouldn't say to Claude: a reply
/// taken for a command never arrives, and nothing tells you. (Said to Claude by mistake,
/// "say that again" just gets you an answer.) "Skip", or saying nothing at all, is how
/// you don't reply.
///
/// While a turn is being read nothing you say is for Claude, so the short forms count
/// too: "skip", "later", "again", "pause". They still have to be said on their own.
enum SpokenCommand: Equatable {
    case again     // read it to me once more
    case later     // put it at the end of the line and ask me then
    case skip      // after a turn: no reply, move on now. During one: drop it and move on
    case scratch   // forget what was just heard and listen again a little while (reply window only)
    case pause     // stop talking (this and the two below: while reading only)
    case resume    // carry on
    case stopAll   // stop, and throw the queue away

    /// Said at the end of anything, these throw away all of it: the mic heard something
    /// it wasn't meant to (the room, a video, a thought you've dropped). It then listens
    /// again for a little while, in case you want to say it properly.
    private static let takeBacks = ["scratch that", "clear that", "cancel that", "don't send that",
                                    "never mind", "nevermind"]

    private static let phrases: [String: SpokenCommand] = {
        var table: [String: SpokenCommand] = [:]
        for p in ["say that again", "say it again", "read that again", "read it again", "repeat that",
                  "remind me again", "one more time"] { table[p] = .again }
        for p in ["come back to this", "come back to this later", "come back to that later",
                  "come back to it later", "put this off", "put that off", "put it off",
                  "put this off to the end", "put that off to the end", "put it off to the end",
                  "put off to the end", "ask me later", "remind me later"] { table[p] = .later }
        // "Skip" is the one short form that counts here too: it's the word people reach
        // for when they've nothing to say (Chris's first two tries, 10-07).
        for p in ["no reply", "no answer", "nothing to say", "skip", "skip it", "skip this", "skip that",
                  "skip this part"] { table[p] = .skip }
        for p in takeBacks + ["start over", "clear", "clear it", "don't send"] {
            table[words(p)] = .scratch
        }
        return table
    }()

    /// Said while a turn is being read: the reply window's ways of saying again and
    /// later, and the short ones. "Stop" is a pause, which "go on" undoes; only "stop
    /// everything" throws the queue away.
    private static let reading: [String: SpokenCommand] = {
        var table = phrases.filter { $0.value == .again || $0.value == .later }
        for p in ["again", "repeat", "replay", "start over", "from the top"] { table[p] = .again }
        for p in ["later", "not now"] { table[p] = .later }
        for p in ["skip", "skip it", "skip this", "skip that", "skip this one", "next", "next one",
                  "move on"] { table[p] = .skip }
        for p in ["pause", "stop", "wait", "hold on", "hang on", "quiet", "be quiet"] { table[p] = .pause }
        for p in ["resume", "go on", "continue", "keep going", "carry on", "go ahead"] { table[p] = .resume }
        for p in ["stop everything", "stop all", "clear the queue"] { table[p] = .stopAll }
        return table
    }()
    /// A word of lead-in that doesn't stop a phrase being a command while reading.
    private static let leadIns = ["ok", "okay", "hey", "uh", "um", "and", "so", "please"]

    /// The words alone: lower case, no punctuation, single spaces. The transcriber
    /// re-punctuates as it goes, and "Later." is the same thing said as "later".
    static func words(_ heard: String) -> String {
        heard.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `whileReading`: the voice is mid-turn, so the short forms count, and "okay, skip"
    /// or "skip, please" is still "skip".
    static func parse(_ heard: String, whileReading: Bool = false) -> SpokenCommand? {
        let said = words(heard)
        guard whileReading else {
            if let c = phrases[said] { return c }
            // "…no wait, scratch that" takes back everything before it.
            return takeBacks.contains { said.hasSuffix(" " + words($0)) } ? .scratch : nil
        }
        if let c = reading[said] { return c }
        var bare = said.split(separator: " ").map(String.init)
        if let first = bare.first, leadIns.contains(first) { bare.removeFirst() }
        if bare.last == "please" { bare.removeLast() }
        return reading[bare.joined(separator: " ")]
    }
}

/// Which of a question box's choices was said, after its options were read: a number
/// ("two", "the second one", "number 2", "option three please") or the choice's own
/// words ("Navy", "go with navy"). Nil when it isn't plainly one of them: a choice is
/// pressed at once and can't be taken back.
enum SpokenChoice {
    private static let numbers: [String: Int] = {
        var table: [String: Int] = [:]
        let words = [("one", "first", "1st"), ("two", "second", "2nd"), ("three", "third", "3rd"),
                     ("four", "fourth", "4th"), ("five", "fifth", "5th"), ("six", "sixth", "6th"),
                     ("seven", "seventh", "7th"), ("eight", "eighth", "8th"), ("nine", "ninth", "9th")]
        for (i, w) in words.enumerated() {
            for name in [String(i + 1), w.0, w.1, w.2] { table[name] = i + 1 }
        }
        return table
    }()
    /// Said around a number without changing it. "One" is among them for "the second
    /// one"; said on its own it's still the first.
    private static let filler: Set<String> = ["the", "option", "number", "choice", "answer", "pick", "go", "with",
                                              "i", "ll", "take", "choose", "let", "s", "lets", "please", "okay", "ok",
                                              "um", "uh", "one", "it", "is", "its", "that", "say"]

    /// The choice's number, counting from 1 in the box's order.
    static func pick(_ heard: String, from options: [String]) -> Int? {
        let said = SpokenCommand.words(heard).split(separator: " ").map(String.init)
        guard !said.isEmpty, !options.isEmpty else { return nil }
        // A number, give or take the words around it.
        let kept = said.filter { !filler.contains($0) }
        let counted = kept.compactMap { numbers[$0] }
        if counted.count == kept.count {
            let found = counted.isEmpty ? (said.contains("one") ? [1] : []) : counted
            if Set(found).count == 1, let n = found.first, (1...options.count).contains(n) { return n }
            if !found.isEmpty { return nil }   // two numbers, or one past the last choice
        }
        // Its own words: every word of a label said. The longest such label wins ("Yes,
        // and don't ask again" over "Yes"); two of the same length is no answer.
        let heard = Set(said)
        var best: (n: Int, size: Int)?
        var tie = false
        for (i, option) in options.enumerated() {
            let label = SpokenCommand.words(option).split(separator: " ").map(String.init)
            guard !label.isEmpty, label.allSatisfy(heard.contains) else { continue }
            if let b = best, label.count == b.size { tie = true; continue }
            if best == nil || label.count > best!.size { (best, tie) = ((i + 1, label.count), false) }
        }
        return tie ? nil : best?.n
    }
}
