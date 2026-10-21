import Cocoa

// ---------------------------------------------------------------------------
// The phone. A page that shows each terminal's last turn and takes an answer for it,
// and a push when a turn finishes while you're away. The page is served on this Mac
// only (127.0.0.1): reaching it from a phone is your tailnet's job (`tailscale serve`),
// so nothing here listens on a network. Off until ~/.config/speakhud/phone.json exists
// (`speak-hud --setup-phone`).
// ---------------------------------------------------------------------------

/// What the page asks and what it's told, and the push when you're away. No network of
/// its own: PhoneServer hands it requests, and `transport` takes the pushes.
final class Phone {
    static let awayKey = "phoneAway"
    static let cookie = "speakhud"
    static let pushLength = 300
    static let assets = ["/": ("index.html", "text/html; charset=utf-8"),
                         "/app.css": ("app.css", "text/css; charset=utf-8"),
                         "/app.js": ("app.js", "text/javascript; charset=utf-8"),
                         "/mic.js": ("mic.js", "text/javascript; charset=utf-8")]

    /// How often, at most, iTerm2 is asked what its panes are showing: while a page is
    /// polling, or while you're away and a box coming up needs a push.
    static let scanEvery: TimeInterval = 4
    /// A page that asked this recently is still open.
    static let pageOpen: TimeInterval = 15
    /// One push per question, whichever of the hook and the screen sees it first.
    static let askGap: TimeInterval = 120
    /// The answers you send often, as buttons on the page. Yours to change there.
    static let quickKey = "phoneQuick"
    static let quickDefault = ["Yes", "No", "Go ahead", "Wrap up"]
    static let quickLimit = 12
    static let pinnedKey = "phonePinned"   // folders you pinned for new terminals, in order

    let config: PhoneConfig
    private(set) var desk: PhoneDesk { didSet { if desk.turns != oldValue.turns { save(desk.snapshot()) } } }
    private let defaults: UserDefaults
    private var scanned = Date.distantPast
    private var polled = Date.distantPast
    private var askPushed: [String: Date] = [:]
    /// iTerm2, which every terminal is read and written through (`Reply`). Tests put a
    /// fake one here, so the page's requests run the real reading, guarding and writing.
    var terminal = Reply.Terminal()
    /// Sends a push. Tests keep the request instead.
    var transport: (URLRequest, @escaping (String?) -> Void) -> Void = Phone.post
    /// How long to wait before each try again of a push that didn't get through. A phone
    /// on the move drops off the network for a moment, and a push lost then never comes.
    static let pushRetries: [TimeInterval] = [5, 30]
    /// Runs `work` after a wait. Tests hold it instead.
    var later: (TimeInterval, @escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }
    /// A file of the page, by name. The app's are in its bundle; tests read the repo's.
    var asset: (String) -> Data? = { name in
        Bundle.main.resourcePath.flatMap { FileManager.default.contents(atPath: $0 + "/phone/" + name) }
    }
    /// The sessions that could be resumed, and what opens one.
    var oldSessions: () -> [OldSessions.Session] = { OldSessions.recent() }
    var reopen: (OldSessions.Session) -> Reply.Outcome = { OldSessions.resume($0) }
    var runningIDs: () -> Set<String> = { OldSessions.running() }
    /// What starts a fresh Claude terminal in a folder, with a first message or none.
    var startNew: (String, String?) -> Reply.Outcome = { NewTerminal.start(folder: $0, message: $1) }
    var home = NSHomeDirectory()
    var isFolder: (String) -> Bool = NewTerminal.isFolder
    var knownFolders: () -> [String] = { NewTerminal.known() }

    var pinned: [String] { defaults.stringArray(forKey: Self.pinnedKey) ?? [] }

    /// The folders a new terminal can start in, as the page is offered them.
    func projects() -> [NewTerminal.Project] {
        NewTerminal.projects(pinned: pinned, sessions: oldSessions(), known: knownFolders(), home: home, isFolder: isFolder)
    }

    private func projectsJSON() -> [String: Any] {
        ["projects": projects().map { p -> [String: Any] in
            ["folder": p.folder, "name": p.name, "where": (p.folder as NSString).abbreviatingWithTildeInPath, "pinned": p.pinned]
        }]
    }

    /// Whether `session` already has a window on the page: resuming it again would put
    /// two terminals on one conversation.
    private func isOpen(_ session: OldSessions.Session) -> Bool {
        desk.turns.contains { $0.key == session.id || ($0.key.hasPrefix(PhoneDesk.paneKey) && $0.name == session.title) }
    }

    var quick: [String] { defaults.stringArray(forKey: Self.quickKey) ?? Self.quickDefault }

    /// Keep `list` as the quick answers: each as it would be sent (one line), no
    /// repeats, no more than `quickLimit`.
    func setQuick(_ list: [String]) {
        var kept: [String] = []
        for raw in list {
            guard let line = Reply.clean(raw).map({ String($0.prefix(200)) }), !kept.contains(line) else { continue }
            kept.append(line)
            if kept.count == Self.quickLimit { break }
        }
        defaults.set(kept, forKey: Self.quickKey)
    }
    /// Turns a recording from the page into words, where this Mac can. Tests answer for it.
    var hear: ((Data, @escaping (Result<String, Dictation.Failure>) -> Void) -> Void)? = Dictation.transcriber
    private var hearing = false
    /// Hears a dictation word for word, a piece of sound at a time (`Dictation.live`).
    var hearLive: ((String, Int, Data, Bool, @escaping (Result<String, Dictation.Failure>) -> Void) -> Void)? = Dictation.live
    /// The dictation being heard word for word: its id, when it began, how much sound so far.
    private var live: (id: String, began: Date, seconds: Double)?
    /// What the page sends a piece of a live dictation as: 16-bit sound and nothing else.
    static let liveType = "audio/pcm"
    /// How long the page waits for its words. Past this the transcriber is taken to be
    /// stuck, the page is told, and the next recording is heard: one that never answers
    /// must not leave every later one turned away.
    var hearPatience: TimeInterval = Dictation.patience + 15
    /// Keeps the list for the next run of the agent. `saved` is what the last one kept.
    var save: (Data) -> Void = { _ in }
    var log: (String) -> Void = { _ in }
    var onAwayChange: (Bool) -> Void = { _ in }

    init(config: PhoneConfig, defaults: UserDefaults = prefs, saved: Data? = nil) {
        self.config = config
        self.defaults = defaults
        desk = PhoneDesk(snapshot: saved)
    }

    /// Ask iTerm2 what's open and showing, so the page lists every Claude Code terminal,
    /// none that has closed, and each one's box. Cheap to call: it asks at most every
    /// `scanEvery`.
    func scan(now: Date = Date()) {
        guard now.timeIntervalSince(scanned) >= Self.scanEvery else { return }
        scanned = now
        guard let open = Reply.survey(via: terminal) else { return }   // iTerm2 not running, or not saying: nothing learned
        for key in desk.met(open, now: now) where away {
            guard let turn = desk.turn(key), let box = turn.box, firstAsk(key, now) else { continue }
            push(title: "\(turn.name) is asking", message: box.ask, key: key, name: turn.name)
        }
    }

    /// The agent's heartbeat calls this: keep looking while someone is, or while a box
    /// coming up would otherwise sit there unseen.
    func tick(now: Date = Date()) {
        if away || now.timeIntervalSince(polled) < Self.pageOpen { scan(now: now) }
    }

    /// Whether `key` hasn't been pushed as asking in the last `askGap`; marks it so.
    private func firstAsk(_ key: String, _ now: Date) -> Bool {
        if let last = askPushed[key], now.timeIntervalSince(last) < Self.askGap { return false }
        askPushed[key] = now
        return true
    }

    // -- away --------------------------------------------------------------

    /// Away: finished turns go to the phone instead of being read to an empty room.
    var away: Bool { defaults.bool(forKey: Self.awayKey) }

    func setAway(_ on: Bool) {
        guard on != away else { return }
        defaults.set(on, forKey: Self.awayKey)
        log("away: \(on ? "on — turns go to the phone" : "off")")
        onAwayChange(on)
    }

    // -- turns in ----------------------------------------------------------

    /// A turn or question off the spool. Kept for the page either way; pushed when away.
    /// False when the page has nowhere to show it, so the phone doesn't have it.
    @discardableResult
    func took(_ item: SpeechItem, now: Date = Date()) -> Bool {
        let asking = item.key.hasSuffix(PhoneDesk.questionSuffix)
        guard item.answerable || asking else { return false }   // only Claude Code's turns have a terminal to answer in
        let first = desk.took(item, now: now)
        guard away, first else { return true }
        let key = asking ? String(item.key.dropLast(PhoneDesk.questionSuffix.count)) : item.key
        if asking, !firstAsk(key, now) { return true }   // the screen already said so
        // What came with it is said in the title: the words are cut to length.
        let with = PhoneMedia.said(item.media).map { " (\($0))" } ?? ""
        push(title: (asking ? "\(item.source) is asking" : item.source) + with, message: item.text, key: key, name: item.source)
        return true
    }

    /// `text` as a push's body: one line, cut to length.
    static func brief(_ text: String) -> String {
        let line = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return line.count > pushLength ? String(line.prefix(pushLength - 1)) + "…" : line
    }

    /// The push for a terminal, or nil when there's nowhere to send one. A tap on it
    /// opens the page at that terminal's window.
    func pushRequest(title: String, message: String, key: String) -> URLRequest? {
        guard let topicURL = config.ntfy.flatMap({ URL(string: $0) }), !topicURL.lastPathComponent.isEmpty,
              topicURL.lastPathComponent != "/" else { return nil }
        var body: [String: Any] = ["topic": topicURL.lastPathComponent, "title": title, "message": Self.brief(message)]
        if let url = config.url {
            body["click"] = url + "/#" + (key.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
        }
        var request = URLRequest(url: topicURL.deletingLastPathComponent())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("SpeakHUD", forHTTPHeaderField: "User-Agent")
        if let token = config.ntfyToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func push(title: String, message: String, key: String, name: String) {
        guard let request = pushRequest(title: title, message: message, key: key) else {
            log("away: no push for \(name) — phone.json has no ntfy topic")
            return
        }
        send(request, name: name, tries: 0)
    }

    /// One try at a push; one that fails is tried again after each of `pushRetries`,
    /// unless you're back at the Mac by then.
    private func send(_ request: URLRequest, name: String, tries: Int) {
        transport(request) { [weak self] problem in
            guard let self = self else { return }
            guard let problem = problem else {
                self.log("away: pushed \(name)" + (tries > 0 ? " (try \(tries + 1))" : ""))
                return
            }
            guard tries < Self.pushRetries.count else {
                self.log("away: push for \(name) failed — \(problem); gave up")
                return
            }
            let wait = Self.pushRetries[tries]
            self.log("away: push for \(name) failed — \(problem); trying again in \(Int(wait)) s")
            self.later(wait) { [weak self] in
                guard let self = self else { return }
                guard self.away else { self.log("away: push for \(name) not tried again — back at the Mac"); return }
                self.send(request, name: name, tries: tries + 1)
            }
        }
    }

    /// Sends `request`; `done` gets what went wrong, or nil, on the main queue.
    static func post(_ request: URLRequest, done: @escaping (String?) -> Void) {
        URLSession.shared.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let problem = error?.localizedDescription ?? ((200..<300).contains(code) ? nil : "the server answered \(code)")
            DispatchQueue.main.async { done(problem) }
        }.resume()
    }

    // -- the page ----------------------------------------------------------

    private func paired(_ r: HTTP.Request) -> Bool {
        Self.same(r.cookies[Self.cookie] ?? "", config.token)
    }

    /// Compared without stopping at the first difference, so timing says nothing.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<y.count { diff |= (i < x.count ? x[i] : 0) ^ y[i] }
        return diff == 0
    }

    func state(now: Date = Date()) -> [String: Any] {
        ["away": away,
         "quick": quick,
         "canHear": hear != nil,   // whether a recording sent here comes back as words
         "canHearLive": hearLive != nil,   // and whether it can be heard word for word as it's said
         "turns": desk.turns.map { t -> [String: Any] in
            ["key": t.key, "name": t.name, "text": t.text,
             "at": ((t.askedAt.map { max($0, t.at) } ?? t.at).timeIntervalSince1970).rounded(),
             "color": t.origin?.color as Any? ?? NSNull(),
             "canReply": Reply.canReach(t.origin),
             "question": t.question as Any? ?? NSNull(),
             "sent": t.sent as Any? ?? NSNull(),
             "note": t.note as Any? ?? NSNull(),
             "box": t.box?.json as Any? ?? NSNull(),
             "busy": t.busy,
             "status": t.status as Any? ?? NSNull(),
             "context": t.context as Any? ?? NSNull(),
             // Each by its place in the turn's list, which is all the page ever asks by.
             "media": t.media.enumerated().compactMap { i, path -> [String: Any]? in
                PhoneMedia.file(path).map { ["i": i, "name": $0.name, "kind": $0.kind, "size": $0.size, "v": $0.version] }
             }]
         }]
    }

    // -- pictures from the phone -------------------------------------------

    /// Where a picture sent with an answer is kept for the terminal's Claude to read, and
    /// for how long. The page shrinks it first; here it only has to be a picture.
    var picturesDir = (Spool.dir as NSString).deletingLastPathComponent + "/from-phone"
    static let pictureAge: TimeInterval = 7 * 86_400
    private var pictures: [String: String] = [:]   // what the page was told to call it -> where it is
    private var pictureCount = 0

    /// A picture the page will name in its next answer. It's kept under a name with no
    /// spaces in it, so the path can go into a terminal's prompt as it is.
    private func picture(_ r: HTTP.Request, now: Date = Date()) -> HTTP.Response {
        guard r.headers["x-speakhud"] == "1" else { return .json(["error": "not found"], status: 404) }
        let jpeg = r.body.starts(with: [0xFF, 0xD8, 0xFF])
        let png = r.body.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard jpeg || png else { return .json(["error": "that isn't a picture"], status: 400) }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: picturesDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        pictureCount += 1
        let name = "\(stamp.string(from: now))-\(pictureCount).\(jpeg ? "jpg" : "png")"
        guard fm.createFile(atPath: picturesDir + "/" + name, contents: r.body, attributes: [.posixPermissions: 0o600]) else {
            return .json(["error": "the Mac couldn't keep that picture"], status: 500)
        }
        pictures[name] = picturesDir + "/" + name
        return .json(["id": name])
    }

    /// Pictures from the phone are for the turn they went with: old ones go.
    func sweepPictures(now: Date = Date()) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: picturesDir)) ?? [] {
            let path = picturesDir + "/" + name
            guard let changed = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(changed) > Self.pictureAge else { continue }
            try? fm.removeItem(atPath: path)
        }
    }

    /// A file a turn made or named, for the page to show under it. Asked for by the
    /// turn and its place in that turn's list, so nothing else on this Mac can be.
    private func media(_ r: HTTP.Request) -> HTTP.Response {
        guard let turn = desk.turn(r.query["key"] ?? ""), let i = Int(r.query["i"] ?? ""), turn.media.indices.contains(i),
              let file = PhoneMedia.file(turn.media[i]) else {
            return .json(["error": "that file isn't there any more"], status: 404)
        }
        let range = r.headers["range"]
        // To keep on the phone: always the file itself, never the lighter copy of a picture.
        let save = r.query["save"] == "1"
        if HTTP.range(range, of: file.size) != .none, range == nil || range?.hasPrefix("bytes=0-") == true {
            log("phone \(save ? "saved" : "shown") \(file.name) (\(file.kind), \(file.size / 1024) KB) from \(turn.name)")
        }
        if save { return .file(file.path, size: file.size, type: file.type, range: range, save: true) }
        if PhoneMedia.sendsSmaller(file), let side = Int(r.query["w"] ?? ""),
           let small = PhoneMedia.small(file.path, side: min(max(side, 64), 2400)) {
            return HTTP.Response(type: small.type, headers: [("Cache-Control", "private, max-age=3600")], body: small.data)
        }
        return .file(file.path, size: file.size, type: file.type, range: range)
    }

    /// The one request whose answer takes a while: a recording of what you said, to be
    /// turned into words for the page's answer box. False for any other request, which
    /// `respond` answers at once. The words are never logged, only how many.
    func respondLater(to r: HTTP.Request, done: @escaping (HTTP.Response) -> Void) -> Bool {
        guard r.method == "POST", r.path == "/api/hear" else { return false }
        guard paired(r) else { done(.json(["error": "not paired"], status: 401)); return true }
        guard r.headers["x-speakhud"] == "1" else { done(.json(["error": "not found"], status: 404)); return true }
        if let id = r.query["live"] { hearPiece(r, of: id, done); return true }
        guard let hear = hear else {
            done(.json(["error": "this Mac can't turn speech into words (it needs macOS 26)"], status: 501))
            return true
        }
        guard r.headers["content-type"]?.lowercased().hasPrefix(Dictation.type) == true, Dictation.looksRight(r.body) else {
            done(.json(["error": "that isn't a recording"], status: 400))
            return true
        }
        guard !hearing else {
            done(.json(["error": "the Mac is still hearing the last one"], status: 409))
            return true
        }
        hearing = true
        let began = Date(), length = Dictation.seconds(r.body)
        var answered = false
        let finish: (Result<String, Dictation.Failure>) -> Void = { [weak self] result in
            guard !answered else { return }   // the transcriber and the wait for it can both get here
            answered = true
            self?.hearing = false
            let took = String(format: "%.1f", Date().timeIntervalSince(began))
            switch result {
            case .success(let text):
                let words = text.split(whereSeparator: { $0.isWhitespace }).count
                self?.log("phone dictated \(words) word\(words == 1 ? "" : "s") (\(String(format: "%.1f", length)) s of sound, heard in \(took) s)")
                done(.json(["text": text]))
            case .failure(let failure):
                self?.log("phone dictation failed after \(took) s: \(failure.why)")
                done(.json(["error": failure.why], status: 503))
            }
        }
        hear(r.body, finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + hearPatience) {
            finish(.failure(Dictation.Failure("the Mac took too long to hear it")))
        }
        return true
    }

    /// One piece of a dictation being heard word for word: `?live=<the page's name for
    /// this dictation>&rate=<samples a second>`, `&last=1` on the piece that ends it, the
    /// sound itself as the body. The answer is the words so far; the last piece's, the
    /// words as they finally stand. Pairing and the page's header were checked by the caller.
    private func hearPiece(_ r: HTTP.Request, of id: String, _ done: @escaping (HTTP.Response) -> Void) {
        guard let hearLive = hearLive else {
            return done(.json(["error": "this Mac can't turn speech into words (it needs macOS 26)"], status: 501))
        }
        let last = r.query["last"] == "1"
        guard id.range(of: #"^[a-z0-9]{6,32}$"#, options: .regularExpression) != nil,
              let rate = Int(r.query["rate"] ?? ""), (8_000...48_000).contains(rate),
              r.headers["content-type"]?.lowercased().hasPrefix(Self.liveType) == true,
              r.body.count % 2 == 0, last || !r.body.isEmpty else {
            return done(.json(["error": "that isn't a piece of a dictation"], status: 400))
        }
        if live?.id != id { live = (id, Date(), 0) }
        live?.seconds += Double(r.body.count / 2) / Double(rate)
        let heard = live
        var answered = false
        let finish: (Result<String, Dictation.Failure>) -> Void = { [weak self] result in
            guard !answered else { return }
            answered = true
            let took = String(format: "%.1f", Date().timeIntervalSince(heard?.began ?? Date()))
            switch result {
            case .success(let text):
                if last {
                    let words = text.split(whereSeparator: { $0.isWhitespace }).count
                    self?.log("phone dictated \(words) word\(words == 1 ? "" : "s") word for word (\(String(format: "%.1f", heard?.seconds ?? 0)) s of sound, done \(took) s after it began)")
                    if self?.live?.id == id { self?.live = nil }
                }
                done(.json(["text": text]))
            case .failure(let failure):
                self?.log("phone dictation failed \(took) s in: \(failure.why)")
                if self?.live?.id == id { self?.live = nil }
                done(.json(["error": failure.why], status: 503))
            }
        }
        hearLive(id, rate, r.body, last, finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + hearPatience) {
            finish(.failure(Dictation.Failure("the Mac took too long to hear it")))
        }
    }

    func respond(to r: HTTP.Request) -> HTTP.Response {
        if r.method == "GET", r.path == "/pair" {
            guard Self.same(r.query["k"] ?? "", config.token) else {
                return .text("That link doesn't open this Mac. Get a fresh one from SpeakHUD's menu: Phone, Pair a Phone.", status: 403)
            }
            let secure = config.url?.lowercased().hasPrefix("https:") == true ? "; Secure" : ""
            return HTTP.Response(status: 303, type: "text/plain; charset=utf-8", headers: [
                ("Location", "/"),
                ("Set-Cookie", "\(Self.cookie)=\(config.token); Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax\(secure)")])
        }
        guard paired(r) else {
            return r.path.hasPrefix("/api/")
                ? .json(["error": "not paired"], status: 401)
                : .text("This phone isn't paired with the Mac. On the Mac, open SpeakHUD's menu: Phone, Pair a Phone.", status: 401)
        }
        if r.method == "GET", let (name, type) = Self.assets[r.path] {
            guard let data = asset(name) else { return .text("The page's files are missing from the app.", status: 404) }
            return HTTP.Response(type: type, body: data)
        }
        if r.method == "GET", r.path == "/api/state" {
            polled = Date()
            scan()
            return .json(state())
        }
        if r.method == "GET", r.path == "/api/file" { return media(r) }
        if r.method == "POST", r.path == "/api/picture" { return picture(r) }
        if r.method == "GET", r.path == "/api/sessions" {
            let running = runningIDs()
            return .json(["sessions": oldSessions().map { s -> [String: Any] in
                ["id": s.id, "title": s.title, "folder": (s.cwd as NSString).lastPathComponent,
                 "at": s.at.timeIntervalSince1970.rounded(), "open": running.contains(s.id) || isOpen(s)]
            }])
        }
        if r.method == "GET", r.path == "/api/projects" { return .json(projectsJSON()) }
        if r.method == "GET", r.path == "/api/screen" {
            guard let turn = desk.turn(r.query["key"] ?? ""), let origin = turn.origin,
                  let screen = Reply.screen(of: origin, via: terminal) else {
                return .json(["error": "its terminal can't be read from here"], status: 409)
            }
            desk.saw(turn.key, screen)   // its box as it stands; back at the prompt, a question is over
            return .json(["screen": screen, "state": state()])
        }
        guard r.method == "POST", r.headers["x-speakhud"] == "1", let body = r.json else {
            return .json(["error": "not found"], status: 404)
        }
        switch r.path {
        case "/api/away":
            guard let on = body["on"] as? Bool else { return .json(["error": "on must be true or false"], status: 400) }
            setAway(on)
            return .json(state())
        case "/api/heard":
            // How a reading went on the phone, for the log: numbers only, and no more
            // than these names. It is what a page's own voice did, which nothing on the
            // Mac can see.
            let names = ["parts", "words", "sized", "backwards", "gap", "scrolls", "stalls", "seconds", "speed", "voices"]
            var said = names.compactMap { name in (body[name] as? NSNumber).map { "\(name) \($0.doubleValue == $0.doubleValue.rounded() ? String($0.intValue) : String($0.doubleValue))" } }
            if let marks = body["marks"] as? Bool { said.append("marks \(marks ? "yes" : "no")") }
            if let lang = body["lang"] as? String, lang.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil {
                said.append("lang \(lang)")
            }
            // Which of the phone's voices read it (a name as the phone gives it, or "own").
            if let name = body["voice"] as? String, name.range(of: #"^[A-Za-z0-9 ()._'-]{1,40}$"#, options: .regularExpression) != nil {
                said.append("voice \(name)")
            }
            // What started it, what ended it, and which open copy of the page it was.
            for name in ["why", "end", "page"] {
                if let word = body[name] as? String, word.range(of: #"^[a-z0-9-]{1,12}$"#, options: .regularExpression) != nil {
                    said.append("\(name) \(word)")
                }
            }
            log("phone reading: " + said.joined(separator: ", "))
            return .json(["ok": true])
        case "/api/mic":
            // A dictation that never reached the Mac, for the log: the name of what went
            // wrong on the phone (its browser's own word for it), and nothing else.
            guard let why = body["why"] as? String, why.range(of: #"^[A-Za-z]{1,40}$"#, options: .regularExpression) != nil else {
                return .json(["error": "why?"], status: 400)
            }
            log("phone dictation didn't start: \(why)")
            return .json(["ok": true])
        case "/api/quick":
            guard let list = body["list"] as? [String] else { return .json(["error": "list must be a list of answers"], status: 400) }
            setQuick(list)
            return .json(state())
        case "/api/resume":
            // The folder and the id come from this Mac's own transcripts, looked up by the
            // id the page sent: the page never names a command or a path.
            guard let id = body["id"] as? String, let session = oldSessions().first(where: { $0.id == id }) else {
                return .json(["error": "that session isn't on this Mac any more"], status: 404)
            }
            guard !isOpen(session), !runningIDs().contains(session.id) else {
                return .json(["sent": false, "outcome": "it's already open"], status: 409)
            }
            let outcome = reopen(session)
            log("phone resumed \(session.title): \(outcome)")
            scanned = .distantPast   // the next look should find its new pane
            return .json(["sent": outcome == .sent, "outcome": outcome == .sent ? "opening on the Mac" : outcome.description])
        case "/api/new":
            // The folder has to be one this Mac offers: the page picks, it never names a
            // path of its own. The message is cleaned as a reply is, and never logged.
            guard let folder = body["folder"] as? String, let project = projects().first(where: { $0.folder == folder }) else {
                return .json(["error": "that folder isn't offered any more"], status: 404)
            }
            let raw = (body["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = Reply.clean(raw)
            if !raw.isEmpty, message == nil {
                return .json(["error": "that first message has nothing a terminal can take"], status: 400)
            }
            let outcome = startNew(project.folder, message)
            log("phone started a new terminal in \(project.name)\(message == nil ? "" : " with a first message"): \(outcome)")
            scanned = .distantPast   // the next look should find its new pane
            return .json(["sent": outcome == .sent, "outcome": outcome == .sent ? "opening on the Mac" : outcome.description])
        case "/api/pin":
            guard let folder = body["folder"] as? String, let on = body["on"] as? Bool else {
                return .json(["error": "which folder, and pin or unpin?"], status: 400)
            }
            if on, !projects().contains(where: { $0.folder == folder }) {
                return .json(["error": "that folder isn't offered any more"], status: 404)
            }
            defaults.set(pinned.filter { $0 != folder } + (on ? [folder] : []), forKey: Self.pinnedKey)
            return .json(projectsJSON())
        case "/api/close":
            guard let key = body["key"] as? String, let turn = desk.turn(key) else {
                return .json(["error": "that terminal isn't on the list any more"], status: 404)
            }
            guard let origin = turn.origin, Reply.canReach(origin) else {
                return .json(["error": "its terminal can't be reached from here"], status: 409)
            }
            let outcome = Reply.close(origin, via: terminal)
            log("phone closed \(turn.name): \(outcome)")
            if outcome == .sent { desk.closed(key) }
            return .json(["sent": outcome == .sent, "outcome": outcome.description, "state": state()])
        case "/api/pick":
            // A choice in the box its terminal is showing. The page says which box it had
            // drawn; `Reply.pick` reads the box again and presses only if that box is the
            // one up now, working the keys out from where its cursor is now. A box that
            // has moved on since the page drew it is never answered blind. Words, if
            // any, are the page's own answer for the choice that takes them.
            guard let key = body["key"] as? String, let row = body["row"] as? Int, let label = body["label"] as? String,
                  let drawn = TerminalBox.Drawn(json: body["box"]) else {
                return .json(["error": "which choice?"], status: 400)
            }
            guard let turn = desk.turn(key), let origin = turn.origin, Reply.canReach(origin) else {
                return .json(["error": "its terminal can't be reached from here"], status: 409)
            }
            // The row and its label are the page's two names for the choice: they have to agree.
            let outcome = drawn.rows.indices.contains(row) && drawn.rows[row] == label
                ? Reply.pick(row, of: drawn, words: body["text"] as? String, in: origin, via: terminal) : .changed
            if outcome == .changed {
                if let screen = Reply.screen(of: origin, via: terminal) { desk.saw(key, screen) }
                return .json(["sent": false, "outcome": outcome.description, "state": state()])
            }
            if outcome == .failed(Reply.takesNoWords) { return .json(["error": Reply.takesNoWords], status: 400) }
            log("phone pick \(row + 1) of \(drawn.rows.count) in \(turn.name): \(outcome)")
            return .json(["sent": outcome == .sent, "outcome": outcome.description])
        case "/api/key":
            guard let key = body["key"] as? String, let name = body["press"] as? String, Reply.keys[name] != nil else {
                return .json(["error": "no such key"], status: 400)
            }
            guard let turn = desk.turn(key) else {
                return .json(["error": "that terminal isn't on the list any more"], status: 404)
            }
            guard let origin = turn.origin, Reply.canReach(origin) else {
                return .json(["error": "its terminal can't be reached from here"], status: 409)
            }
            // What the page had drawn when the key was tapped: a box, or the hook's
            // question with the choice this number was beside, or neither. `Reply.press`
            // looks at the pane and presses only where that still stands and takes the key.
            // Neither is said by saying nothing. A box or a question that is there but
            // can't be read is refused, never taken for none: Enter tapped on a box
            // would then go into Claude's prompt.
            let tapped: Reply.Tapped
            if let box = body["box"] {
                guard let drawn = TerminalBox.Drawn(json: box) else { return .json(["error": "which box?"], status: 400) }
                tapped = .box(drawn)
            } else if body["asked"] != nil || body["option"] != nil {
                guard let asked = body["asked"] as? String, let option = body["option"] as? String else {
                    return .json(["error": "which question?"], status: 400)
                }
                tapped = .question(asked: asked, option: option)
            } else {
                tapped = .noBox
            }
            let outcome = Reply.press(name, on: tapped, in: origin, via: terminal)
            log("phone key \(name) to \(turn.name): \(outcome)")
            if outcome == .changed {
                if let screen = Reply.screen(of: origin, via: terminal) { desk.saw(key, screen) }
                return .json(["sent": false, "outcome": outcome.description, "state": state()])
            }
            return .json(["sent": outcome == .sent, "outcome": outcome.description])
        case "/api/reply":
            guard let key = body["key"] as? String, let said = body["text"] as? String else {
                return .json(["error": "nothing to send"], status: 400)
            }
            // Pictures sent ahead of this answer go with it as where they are on the Mac:
            // a terminal's Claude reads a picture from its path.
            let ids = body["pictures"] as? [String] ?? []
            let paths = ids.compactMap { pictures[$0] }.filter { FileManager.default.fileExists(atPath: $0) }
            guard paths.count == ids.count else {
                return .json(["error": "a picture didn't reach the Mac: add it again"], status: 400)
            }
            var text = said
            if !paths.isEmpty {
                let words = Reply.clean(said)
                let lead = paths.count == 1 ? "picture" : "pictures"
                text = (words.map { $0 + " The \(lead) from my phone:" } ?? "Look at \(paths.count == 1 ? "this" : "these") \(lead) from my phone:")
                    + " " + paths.joined(separator: " ")
            }
            guard Reply.clean(text) != nil else { return .json(["error": "nothing to send"], status: 400) }
            guard let turn = desk.turn(key) else {
                return .json(["error": "that terminal isn't on the list any more"], status: 404)
            }
            guard let origin = turn.origin, Reply.canReach(origin) else {
                return .json(["error": "its terminal can't be reached from here"], status: 409)
            }
            // Only the paths put on the end here count as pictures: a path or a link in
            // the words themselves is words.
            let outcome = Reply.send(text, to: origin, pictures: paths, via: terminal)
            let with = paths.isEmpty ? "" : paths.count == 1 ? "1 picture" : "\(paths.count) pictures"
            desk.answered(key, with: [Reply.clean(said), with.isEmpty ? nil : "[\(with)]"].compactMap { $0 }.joined(separator: " "), outcome)
            log("phone reply to \(turn.name) (\(said.count) chars\(with.isEmpty ? "" : ", " + with)): \(outcome)")
            // `pasted`: the words are in its prompt, unsent. Sending them again would double them.
            return .json(["sent": outcome == .sent, "pasted": outcome == .unconfirmed,
                          "outcome": outcome.description, "state": state()])
        default:
            return .json(["error": "not found"], status: 404)
        }
    }
}

/// Getting the token onto a phone, and phone.json onto the Mac.
enum PhonePair {
    /// `text` as a QR code, black on white with a quiet border, `side` points square.
    static func qr(_ text: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage, code.extent.width > 0 else { return nil }
        let scale = (side / code.extent.width).rounded(.down)
        let rep = NSCIImageRep(ciImage: code.transformed(by: CGAffineTransform(scaleX: max(scale, 1), y: max(scale, 1))))
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        rep.draw(in: NSRect(x: (side - rep.size.width) / 2, y: (side - rep.size.height) / 2,
                            width: rep.size.width, height: rep.size.height))
        image.unlockFocus()
        return image
    }

    /// `speak-hud --setup-phone [--url U] [--ntfy TOPIC_URL] [--ntfy-token T] [--port N] [--new-token]`:
    /// writes phone.json, keeping the token and whatever isn't given again. The ntfy
    /// token can come from $SPEAKHUD_NTFY_TOKEN instead, which keeps it out of `ps`.
    /// `--new-token` is for a lost phone or a leaked link: every phone has to pair again.
    static func setup(_ argv: [String], env: [String: String] = ProcessInfo.processInfo.environment,
                      path: String = PhoneConfig.path) -> (message: String, exitCode: Int32) {
        func value(_ flag: String) -> String? {
            argv.firstIndex(of: flag).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
        }
        var config = PhoneConfig.load(path) ?? PhoneConfig(token: PhoneConfig.newToken())
        let renewed = argv.contains("--new-token")
        if renewed { config.token = PhoneConfig.newToken() }
        if let raw = value("--url") {
            guard let url = PhoneConfig.web(raw) else { return ("error: --url wants an http(s) address, like https://my-mac.my-tailnet.ts.net", 2) }
            config.url = url
        }
        if let raw = value("--ntfy") {
            guard let topic = PhoneConfig.web(raw), URL(string: topic)?.path.count ?? 0 > 1 else {
                return ("error: --ntfy wants a topic's address, like https://ntfy.example.com/terminals", 2)
            }
            config.ntfy = topic
        }
        if let token = value("--ntfy-token") ?? env["SPEAKHUD_NTFY_TOKEN"], !token.isEmpty { config.ntfyToken = token }
        if let raw = value("--port") {
            guard let port = UInt16(raw), port >= 1024 else { return ("error: --port wants a number from 1024 to 65535", 2) }
            config.port = port
        }
        guard config.save(to: path) else { return ("error: couldn't write \(path)", 1) }
        var lines = ["phone page set up in \(path) (port \(config.port), this Mac only)"]
        lines.append(config.url == nil ? "no --url yet: share the port on your tailnet (tailscale serve --bg \(config.port)), then give its address with --url"
                                       : "reached at \(config.url!)")
        lines.append(config.ntfy == nil ? "no --ntfy topic: Away won't push" : "pushes go to \(config.ntfy!)")
        if renewed { lines.append("new key: every phone has to pair again") }
        lines.append("restart SpeakHUD, then pair from its menu: Phone, Pair a Phone")
        return (lines.joined(separator: "\n"), 0)
    }
}
