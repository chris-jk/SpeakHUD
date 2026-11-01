import Foundation

// Claude Code turns arrive as files here rather than as processes, so a finished
// turn can never interrupt one that's already speaking. The hook writes `<name>.tmp`
// and renames it to `<name>.json`, which is atomic within a filesystem — the agent
// therefore never observes a half-written item.
//
// The contract with hook/read-summary.py (pinned by tests/SpoolTests.swift, which runs
// the real Python `enqueue()` against the real `drain`):
//   v        schema version, optional → legacy (read as 1); anything but 1 → dropped,
//            so a newer hook's items are never misread by an older agent
//   text     string, required; blank after trimming → dropped
//   source   string, optional → "Claude Code"
//   key      string, optional → the file stem (unique, so that item never coalesces)
//   created  epoch seconds, optional → the file's mtime (when the hook wrote it);
//            present but not a number → dropped. Either way older than maxAge → dropped.
//   origin   object, optional: {term, session, tty, app_pid}, where the turn came from.
//            Unusable fields are ignored, never a reason to drop the item.
//   links    array, optional: [{at, len, path} | {at, len, run}], UTF-16 ranges of `text`
//            to click — a path to open, a command to type into a terminal. Entries
//            that don't fit are ignored (TextLink.parse).
//   cwd      string, optional: the turn's working directory, where commands are typed.
//   blocks   array, optional: [{at, code, links}], fenced code shown but never spoken —
//            `at` is where in `text` it goes back, `links` as above but within `code`.
//   reply    string, optional: "prompt" when the turn left its terminal waiting at
//            Claude's prompt, so an answer said out loud can be pasted there (Reply);
//            "choice" for a question box's options, answered by picking one, with
//   choices  object: {asked, options: [label]}, the question and its choices in order.
//            Anything else, or missing, is an item nobody can answer.
//   reread   string, optional: a terminal session id. This file is then a request, from
//            Agent Terminal's Reread button, and no other field but `v` counts: read that
//            session's last turn again. An older agent drops it as having no text.
// Every dropped item comes back as a `Drop` with its reason, for the agent to log.
//
// The last turn of each terminal session stays in `last/<session>.json`, beside the queue,
// a copy of the file as it arrived. Agent Terminal looks there to say whether a Reread
// can work; `lastKeep` after the session's last turn it goes.
//
// Liveness: the agent touches `heartbeatName` in the spool dir at startup and every
// `heartbeatInterval`; the hook queues only while that mtime is fresh, and otherwise
// speaks the turn itself (tests/HookTests.swift pins both sides).
enum Spool {
    static let maxAge: TimeInterval = 600   // a stopped agent shouldn't wake up and read you the backlog
    static let version = 1                  // the `v` this agent reads
    /// Deliberately not .json/.tmp/.taken, so drain and recover never touch it.
    static let heartbeatName = "agent.heartbeat"
    static let heartbeatInterval: TimeInterval = 3
    static let lastKeep: TimeInterval = 7 * 86_400
    /// Points both sides at another queue — the hook reads the same variable. For tests;
    /// set it for one side only and the hook writes where nobody reads.
    static let dirEnv = "SPEAKHUD_QUEUE_DIR"
    static var dir: String {
        let override = ProcessInfo.processInfo.environment[dirEnv] ?? ""
        return NSString(string: override.isEmpty ? "~/.local/state/speakhud/queue" : override)
            .expandingTildeInPath
    }

    enum DropReason: Equatable, CustomStringConvertible {
        case malformed        // unreadable, or not a JSON object
        case emptyText        // text missing, not a string, or only whitespace
        case invalidCreated   // created present but not a number
        case tooOld           // waited longer than maxAge
        case staleTmp         // a hook died between writing and renaming
        case unsupportedVersion  // `v` present but not the version this agent reads
        case nothingToReread  // a reread for a session with no turn kept

        var description: String {
            switch self {
            case .nothingToReread: return "no turn kept to read again"
            case .unsupportedVersion: return "unsupported schema version (this agent reads v\(Spool.version)) — update SpeakHUD"
            case .malformed: return "malformed JSON"
            case .emptyText: return "no text"
            case .invalidCreated: return "created is not a number"
            case .tooOld: return "older than \(Int(Spool.maxAge))s"
            case .staleTmp: return "abandoned .tmp"
            }
        }
    }
    struct Drop: Equatable { let name: String; let reason: DropReason }
    struct Batch {
        var items: [SpeechItem] = []
        var dropped: [Drop] = []
        var rereads: [SpeechItem] = []  // asked for again: the kept turn, with no spool file
    }

    static func ensure(_ dir: String = Spool.dir) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    /// Items a previous agent had picked up but never finished speaking — it was
    /// restarted or crashed mid-queue. Hand them back so they get another turn.
    static func recover(in dir: String = Spool.dir) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in names where name.hasSuffix(".taken") {
            let stem = String(name.dropLast(6))
            try? fm.moveItem(atPath: dir + "/" + name, toPath: dir + "/" + stem + ".json")
        }
    }

    /// Take every queued item, in arrival order. A taken item is renamed rather than
    /// deleted, so it still exists on disk until it has actually been spoken; `done()`
    /// is what finally removes it. Also sweeps `.tmp` files older than maxAge: a hook
    /// killed between open and rename leaves one, and nothing else ever would.
    static func drain(in dir: String = Spool.dir, now: Date = Date()) -> Batch {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return Batch() }
        var batch = Batch()
        func mtime(_ path: String) -> Date? {
            (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        for name in names where name.hasSuffix(".tmp") {
            let path = dir + "/" + name
            // Young ones are a hook mid-write; leave those alone.
            guard let m = mtime(path), now.timeIntervalSince(m) >= maxAge,
                  (try? fm.removeItem(atPath: path)) != nil else { continue }
            batch.dropped.append(Drop(name: name, reason: .staleTmp))
        }
        for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let stem = String(name.dropLast(5))
            let taken = dir + "/" + stem + ".taken"
            // Claim it atomically; if the rename loses, someone else has it.
            guard (try? fm.moveItem(atPath: dir + "/" + name, toPath: taken)) != nil else { continue }
            func drop(_ reason: DropReason) {   // don't wedge the queue on a bad item
                done(taken)
                batch.dropped.append(Drop(name: name, reason: reason))
            }
            guard let data = fm.contents(atPath: taken),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { drop(.malformed); continue }
            // Before any field is read: a newer schema may have moved them all.
            if let raw = obj["v"] {
                guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue == Double(version)
                else { drop(.unsupportedVersion); continue }
            }
            if let session = obj["reread"] as? String {
                guard let turn = lastTurn(session: session, queue: dir, now: now)
                else { drop(.nothingToReread); continue }
                done(taken)
                batch.rereads.append(turn)
                continue
            }
            guard let text = obj["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { drop(.emptyText); continue }
            let created: Date
            if let raw = obj["created"] {
                // JSON booleans also bridge to NSNumber; they aren't timestamps.
                guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue.isFinite
                else { drop(.invalidCreated); continue }
                created = Date(timeIntervalSince1970: n.doubleValue)
            } else {
                // Rename keeps mtime, so this is when the producer wrote the file.
                created = mtime(taken) ?? now
            }
            guard now.timeIntervalSince(created) < maxAge else { drop(.tooOld); continue }
            var item = speechItem(obj, text: text, stem: stem, created: created, file: taken)
            item.quiet = saysNothing(text)
            batch.items.append(item)
            // A question's pieces are no turn to read again: they'd take the turn's place.
            if let session = item.origin?.session, !item.key.hasSuffix(PhoneDesk.questionSuffix) {
                keepLast(data, session: session, queue: dir, now: now)
            }
        }
        return batch
    }

    private static func speechItem(_ obj: [String: Any], text: String, stem: String, created: Date,
                                    file: String?) -> SpeechItem {
        let source = obj["source"] as? String ?? ""
        let key = obj["key"] as? String ?? ""
        return SpeechItem(text: text,
                          source: source.isEmpty ? "Claude Code" : source,
                          key: key.isEmpty ? stem : key,
                          created: created,
                          file: file,
                          origin: Origin(json: obj["origin"]),
                          links: TextLink.parse(obj["links"], in: text),
                          cwd: TextLink.absolutePath(obj["cwd"]),
                          blocks: CodeBlock.parse(obj["blocks"], in: text),
                          answerable: obj["reply"] as? String == "prompt",
                          choices: obj["reply"] as? String == "choice" ? choices(obj["choices"]) : nil,
                          media: PhoneMedia.parse(obj["media"]))
    }

    static func lastDir(queue dir: String) -> String {
        (dir as NSString).deletingLastPathComponent + "/last"
    }

    /// Replaces the session's kept turn, and lets go of any past `lastKeep`.
    static func keepLast(_ data: Data, session: String, queue dir: String, now: Date = Date()) {
        let fm = FileManager.default
        let last = lastDir(queue: dir)
        try? fm.createDirectory(atPath: last, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let path = last + "/" + session + ".json", tmp = path + ".tmp"
        guard fm.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        rename(tmp, path)
        for name in (try? fm.contentsOfDirectory(atPath: last)) ?? [] {
            let old = last + "/" + name
            if let m = (try? fm.attributesOfItem(atPath: old))?[.modificationDate] as? Date,
               now.timeIntervalSince(m) >= lastKeep { try? fm.removeItem(atPath: old) }
        }
    }

    /// The session's kept turn, to read again. Nobody can answer it: the terminal has
    /// moved on since, and a question's box may be long gone.
    static func lastTurn(session: String, queue dir: String, now: Date = Date()) -> SpeechItem? {
        guard let safe = Origin(json: ["session": session])?.session,
              let data = FileManager.default.contents(atPath: lastDir(queue: dir) + "/" + safe + ".json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else { return nil }
        var item = speechItem(obj, text: text, stem: safe, created: now, file: nil)
        item.answerable = false
        item.choices = nil
        return item
    }

    /// A question's choices as the hook sends them, or nil if they aren't: a question,
    /// and one to nine labels, none blank (a number is pressed for the one said).
    static func choices(_ raw: Any?) -> SpeechItem.Choices? {
        guard let obj = raw as? [String: Any], let asked = obj["asked"] as? String,
              !asked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let options = obj["options"] as? [String], (1...9).contains(options.count),
              options.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        return SpeechItem.Choices(asked: asked, options: options)
    }

    /// "The agent is alive and draining": touch the heartbeat's mtime. Only its first
    /// write creates a directory entry; after that it's a pure mtime change, which the
    /// spool's directory watcher doesn't see, so beating never triggers a drain.
    @discardableResult
    static func beat(in dir: String = Spool.dir, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        let path = dir + "/" + heartbeatName
        // The dir can be removed from under a live agent; the hook only recreates it when
        // it queues, which it won't do while the heartbeat is missing. So bring it back here.
        if !fm.fileExists(atPath: dir) { ensure(dir) }
        if !fm.fileExists(atPath: path), !fm.createFile(atPath: path, contents: nil) { return false }
        return (try? fm.setAttributes([.modificationDate: now], ofItemAtPath: path)) != nil
    }

    /// A turn whose whole reply is "Nothing": an answer to a hook's check, not to Chris.
    static func saysNothing(_ text: String) -> Bool {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased() == "nothing"
    }

    /// This item will never be spoken again — finished, skipped, stopped, or superseded.
    static func done(_ path: String?) {
        guard let path = path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
