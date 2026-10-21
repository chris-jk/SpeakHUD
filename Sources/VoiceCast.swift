import Foundation

/// A Voice per Project: each source's turns in a voice of its own, so the ear tells
/// terminals apart before the words do. A name keeps its voice; a new name gets the voice
/// heard longest ago, so the terminals going at once sound different. Kept in the shared
/// prefs, so a name sounds the same after a restart. No AVFoundation: the voices come in
/// as identifiers (`pool`), and tests drive it with made-up ones.
struct VoiceCast: Codable, Equatable {
    static let prefKey = "voicePerProject"
    static let castKey = "voiceCast"
    /// A name not heard for this long gives its voice back.
    static let forget: TimeInterval = 14 * 86_400

    struct Part: Codable, Equatable {
        var voice: String
        var heard: Date
    }
    private(set) var parts: [String: Part] = [:]

    /// The voice `name` speaks in, from `pool` (best first: the Mac's own voice leads, so
    /// the first name keeps the voice you're used to). Nil when there's nothing to choose.
    mutating func voice(for name: String, from pool: [String], now: Date) -> String? {
        guard pool.count > 1 else { return nil }
        parts = parts.filter { now.timeIntervalSince($0.value.heard) < Self.forget && pool.contains($0.value.voice) }
        if var part = parts[name] {
            part.heard = now
            parts[name] = part
            return part.voice
        }
        let last = Dictionary(parts.values.map { ($0.voice, $0.heard) }, uniquingKeysWith: max)
        // A voice nobody has, in pool order; else the one heard longest ago.
        guard let voice = pool.min(by: { (last[$0] ?? .distantPast) < (last[$1] ?? .distantPast) }) else { return nil }
        parts[name] = Part(voice: voice, heard: now)
        return voice
    }

    /// Which installed voices to cast from: those of the Mac's own voice's language that
    /// sound like a person (Apple's current voices, not the novelty ones or the old
    /// synthesizers), one per name at its best quality, the Mac's own voice first.
    static func pool(_ voices: [(id: String, name: String, language: String, quality: Int, novelty: Bool)],
                     default mine: (name: String, language: String)?) -> [String] {
        let language = mine.map { String($0.language.prefix(2)) } ?? "en"
        var best: [String: (id: String, quality: Int)] = [:]
        for v in voices where v.id.hasPrefix("com.apple.voice.") && !v.novelty && v.language.hasPrefix(language) {
            if let held = best[v.name], held.quality >= v.quality { continue }
            best[v.name] = (v.id, v.quality)
        }
        var names = best.keys.sorted()
        if let mine = mine, let at = names.firstIndex(of: mine.name) { names.insert(names.remove(at: at), at: 0) }
        return names.compactMap { best[$0]?.id }
    }

    static func load(from defaults: UserDefaults) -> VoiceCast {
        defaults.data(forKey: castKey).flatMap { try? JSONDecoder().decode(VoiceCast.self, from: $0) } ?? VoiceCast()
    }
    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.castKey) }
    }
    /// On unless switched off in the menu.
    static func enabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: prefKey) as? Bool ?? true
    }
}
