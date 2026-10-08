// LogKeep tests. Registered in tests/main.swift.
//
// The agent's log is cut down in place while launchd holds it open for appending, so
// the trim runs here on a real file with a second, append-only handle on it.
import Foundation

private let fm = FileManager.default

private func stamp(_ date: Date) -> String { "[" + ISO8601DateFormatter().string(from: date) + "]" }

let logKeepSuite = Suite("LogKeep") { t in
    let now = Date(timeIntervalSince1970: 1_791_000_000)
    let day: TimeInterval = 86_400
    let old1 = stamp(now.addingTimeInterval(-45 * day)) + " start TextEdit (177 chars)"
    let old2 = stamp(now.addingTimeInterval(-31 * day)) + " mic released"
    let loose = "a line with no stamp, from before"
    let new1 = stamp(now.addingTimeInterval(-29 * day)) + " agent started (pid 1)"
    let noise = "a line with no stamp, since"
    let new2 = stamp(now.addingTimeInterval(-60)) + " mic in use — holding speech"
    let cutoff = now.addingTimeInterval(-Double(LogKeep.days) * day)
    func data(_ lines: [String]) -> Data { (lines.joined(separator: "\n") + "\n").data(using: .utf8)! }

    // -- where the cut falls ------------------------------------------------
    let whole = data([old1, old2, loose, new1, noise, new2])
    let cut = LogKeep.cut(whole, before: cutoff)
    t.expectEqual(cut?.lines ?? -1, 3, "everything before the first line inside the 30 days goes, unstamped lines with it")
    t.expectEqual(cut.map { String(decoding: whole[$0.offset...], as: UTF8.self) } ?? "",
                  [new1, noise, new2].joined(separator: "\n") + "\n",
                  "what's kept starts at that line and keeps unstamped lines after it")
    t.expect(LogKeep.cut(data([new1, noise, new2]), before: cutoff) == nil, "nothing old: nothing to drop")
    t.expect(LogKeep.cut(data([loose, noise]), before: cutoff) == nil, "a log with no stamps is left alone")
    t.expect(LogKeep.cut(Data(), before: cutoff) == nil, "an empty log is left alone")
    t.expectEqual(LogKeep.cut(data([old1, old2]), before: cutoff)?.lines ?? -1, 2, "a log that is all old goes entirely")
    let edge = stamp(cutoff) + " exactly 30 days old"
    t.expectEqual(LogKeep.cut(data([old2, edge]), before: cutoff)?.lines ?? -1, 1, "a line exactly 30 days old is kept")

    // -- on a real file, held open for appending as launchd holds it --------
    let dir = fm.temporaryDirectory.appendingPathComponent("speakhud-logkeep-\(UUID().uuidString)").path
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    let path = dir + "/agent.log"
    fm.createFile(atPath: path, contents: whole)
    let fd = open(path, O_WRONLY | O_APPEND)
    defer { close(fd) }
    func append(_ line: String) { _ = (line + "\n").withCString { write(fd, $0, strlen($0)) } }

    t.expectEqual(LogKeep.trim(path, now: now), 3, "trim says how many lines went")
    append("after the trim")
    t.expectEqual(String(decoding: fm.contents(atPath: path) ?? Data(), as: UTF8.self),
                  [new1, noise, new2, "after the trim"].joined(separator: "\n") + "\n",
                  "the file is cut in place: the open handle's next line lands right after what was kept")
    t.expectEqual(LogKeep.trim(path, now: now), 0, "a second trim finds nothing to drop")
    t.expectEqual(LogKeep.trim(dir + "/missing.log", now: now), 0, "no log: nothing happens")
}
